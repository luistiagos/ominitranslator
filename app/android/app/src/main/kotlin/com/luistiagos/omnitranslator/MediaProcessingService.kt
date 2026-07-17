package com.luistiagos.omnitranslator

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Binder
import android.os.Build
import android.os.IBinder
import androidx.annotation.RequiresApi
import com.arthenica.ffmpegkit.FFmpegKit
import com.arthenica.ffmpegkit.FFmpegKitConfig
import com.arthenica.ffmpegkit.FFprobeKit
import com.arthenica.ffmpegkit.Session
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/// Foreground service do tipo `mediaProcessing` (§14, D3.3/AT-4). Dono de um
/// `FlutterEngine` HEADLESS separado do da `MainActivity` — o job roda aqui
/// dentro, sobrevive a Activity morrer/rotacionar/ser trocada de app (§14.6),
/// e só termina com `stopForeground`+`stopSelf` em sucesso, falha ou
/// cancelamento.
///
/// Escopo do MVP (revisão de 2026-07-16, decisão do usuário): este serviço
/// GRAVA checkpoints (via o isolate do job, que chama `JobCheckpointStore`
/// diretamente — ver `service_entrypoint.dart`) mas não pula estágios já
/// concluídos ao retomar. `listRecoverableJobs()` (lado Dart, sem canal —
/// funciona mesmo com o serviço morto) mostra um job após morte forçada do
/// processo, mas "retomar" hoje significa rodar o pipeline do zero de novo.
class MediaProcessingService : Service() {
    companion object {
        private const val NOTIFICATION_CHANNEL_ID = "media_processing"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_CANCEL = "com.luistiagos.omnitranslator.action.CANCEL_JOB"
    }

    inner class LocalBinder : Binder() {
        fun getService(): MediaProcessingService = this@MediaProcessingService
    }
    private val binder = LocalBinder()

    private var flutterEngine: FlutterEngine? = null
    private var workerChannel: MethodChannel? = null
    private var activityEventSink: EventChannel.EventSink? = null

    private var currentJobId: String? = null
    private var currentDisplayName: String = ""
    private var currentStage: String = ""
    private var currentPercent: Int = 0

    /// Handshake com o isolate Dart (auditoria de 2026-07-16): o `serviceMain`
    /// avisa `workerReady` DEPOIS de registrar seu handler. Sem isso, um
    /// `runJob` enviado antes de o Dart terminar de bootar dependia do
    /// ChannelBuffers do Flutter (capacidade 1, comportamento não
    /// documentado como contrato) pra não se perder — funciona pra
    /// exatamente 1 mensagem, quebra silenciosamente pra 2 (ex.: runJob +
    /// cancelJob em sequência rápida). Com o handshake é determinístico.
    private var workerReady = false
    private var pendingStart: Triple<String, String, Map<String, Any?>>? = null

    /// Último `Statistics.time` (ms de mídia processada) reportado pelo
    /// FFmpegKit — alimenta o `statTimeMs` do `ffmpegPoll`, que o
    /// `FFmpegKitNextRunner` converte em progresso quando o comando declara
    /// `-t` explícito.
    @Volatile private var lastStatTimeMs: Double = -1.0

    fun hasActiveJob(): Boolean = currentJobId != null

    /// Chamado pela Activity ao (re)conectar via `ServiceConnection` e ao
    /// desconectar (`null`) — nunca deixar um sink morto recebendo `.success`,
    /// que é exatamente o que aconteceria se a Activity for removida da
    /// memória enquanto o serviço segue vivo (§14.6) sem isto.
    fun attachEventSink(sink: EventChannel.EventSink?) {
        activityEventSink = sink
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Processamento de vídeo",
            NotificationManager.IMPORTANCE_LOW
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            currentJobId?.let { cancelJob(it) }
            return START_NOT_STICKY
        }
        // §14.5: startForeground é o PRIMEIRO passo, antes de qualquer
        // bootstrap do engine headless (que não é instantâneo) -- não pode
        // arriscar estourar a janela que o SO exige pra promover o serviço.
        startForegroundWithPlaceholder()
        ensureHeadlessEngine()
        // Sem auto-restart do SO: a recuperação depois de morte forçada do
        // processo é iniciada pelo usuário via listRecoverableJobs() (MVP,
        // ver comentário da classe), não por um restart automático que
        // reabriria um job sem UI nenhuma observando.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        flutterEngine?.destroy()
        flutterEngine = null
        workerChannel = null
        super.onDestroy()
    }

    /// A sobrecarga (startId, fgsType) de `Service.onTimeout` só existe a
    /// partir da API 35 (a de 1 argumento é da 34) — nunca é chamada pelo SO
    /// abaixo disso, então declarar sem guard de versão é seguro (padrão
    /// Android comum pra overrides de API alta com minSdk menor).
    @RequiresApi(Build.VERSION_CODES.VANILLA_ICE_CREAM)
    override fun onTimeout(startId: Int, fgsType: Int) {
        currentJobId?.let { cancelJob(it) }
    }

    fun startJob(jobId: String, displayName: String, config: Map<String, Any?>) {
        currentJobId = jobId
        currentDisplayName = displayName
        currentStage = "iniciando"
        currentPercent = 0
        updateNotification()
        if (workerReady) {
            workerChannel?.invokeMethod("runJob", mapOf("jobId" to jobId, "config" to config))
        } else {
            pendingStart = Triple(jobId, displayName, config)
        }
    }

    fun cancelJob(jobId: String) {
        if (!workerReady && pendingStart?.first == jobId) {
            // Cancelado antes de o Dart bootar: o job nunca começou e nenhum
            // checkpoint foi criado — descartar e encerrar é suficiente (não
            // há evento terminal a emitir porque não há estado a reportar).
            pendingStart = null
            currentJobId = null
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        workerChannel?.invokeMethod("cancelJob", mapOf("jobId" to jobId))
    }

    /// Bootstrap do FlutterEngine headless (D3.3) -- nada parecido existia no
    /// repo antes disso. Padrão padrão do Flutter pra execução headless:
    /// `FlutterLoader` inicializado manualmente (a Activity normalmente faz
    /// isso via `FlutterActivity`, mas aqui não há Activity nenhuma) e
    /// `executeDartEntrypoint` apontando pro símbolo `serviceMain`
    /// (`service_entrypoint.dart`, `@pragma('vm:entry-point')`, alcançável a
    /// partir de `main.dart`).
    private fun ensureHeadlessEngine() {
        if (flutterEngine != null) return
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(applicationContext)
        }
        loader.ensureInitializationComplete(applicationContext, null)

        // O construtor do FlutterEngine já registra os plugins do
        // GeneratedPluginRegistrant sozinho (automaticallyRegisterPlugins
        // default) — chamar registerWith de novo só gera warning de plugin
        // duplicado (visto no logcat do smoke on-device de 2026-07-17).
        val engine = FlutterEngine(applicationContext)

        // TODOS os handlers Kotlin registrados ANTES do executeDartEntrypoint:
        // o lado nativo não tem ChannelBuffers — um invokeMethod do Dart
        // (ex.: o `workerReady` do handshake) que chegasse antes do
        // setMethodCallHandler seria respondido com "not implemented" e
        // perdido (auditoria de 2026-07-16).
        val messenger = engine.dartExecutor.binaryMessenger
        workerChannel = MethodChannel(messenger, "omnitranslator/service_worker").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "workerReady" -> {
                        workerReady = true
                        pendingStart?.let { (jobId, _, config) ->
                            ch.invokeMethod("runJob", mapOf("jobId" to jobId, "config" to config))
                        }
                        pendingStart = null
                        result.success(null)
                    }
                    "jobStateChanged", "jobProgress", "jobWarning", "jobCompleted", "jobFailed" -> {
                        @Suppress("UNCHECKED_CAST")
                        val payload = ((call.arguments as? Map<String, Any?>) ?: emptyMap())
                            .toMutableMap()
                        payload["kind"] = call.method
                        activityEventSink?.success(payload)
                        onWorkerEvent(call.method, payload)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // §14.2: getFreeBytes precisa existir TAMBÉM no engine headless -- o
        // estágio `prepare` do pipeline (`runtime.diskSpace.freeBytes()`)
        // roda de DENTRO do isolate do job, que fala com ESTE
        // binaryMessenger, não o da Activity (dois FlutterEngines
        // independentes no mesmo processo).
        MethodChannel(messenger, "omnitranslator/storage").setMethodCallHandler { call, result ->
            when (call.method) {
                "getFreeBytes" -> {
                    val path = call.argument<String>("path")!!
                    result.success(DiskSpace.freeBytesOf(path))
                }
                else -> result.notImplemented()
            }
        }
        registerFFmpegChannel(messenger)

        // Construtor de TRÊS argumentos, com a library URI explícita: o de
        // dois procura o símbolo na biblioteca RAIZ (main.dart) e falha com
        // "Could not resolve main entrypoint function" — serviceMain vive em
        // src/service_entrypoint.dart (achado do smoke on-device de
        // 2026-07-17; o import no main.dart mantém a biblioteca no snapshot,
        // mas não resolve o símbolo por si).
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "package:omnitranslator_app/src/service_entrypoint.dart",
                "serviceMain"
            )
        )
        flutterEngine = engine
    }

    /// `omnitranslator/ffmpeg` -- movido de `MainActivity`/do smoke test pra
    /// cá (D-6 do plano D3.3): este é o handler REAL agora, não mais um
    /// splice temporário. API confirmada compilando contra o AAR de verdade
    /// (F4, revisão de 2026-07-16): `Session`/`FFprobeSession` expõem
    /// FUNÇÕES Kotlin explícitas (`getSessionId()`, `getReturnCode()`,
    /// `getOutput()`), não properties -- só `ReturnCode.value` e
    /// `Statistics.time` são properties de verdade. Os callbacks
    /// (`FFmpegSessionCompleteCallback` etc.) não são `fun interface`, então
    /// lambda solta não compila -- precisa de `object : Interface { ... }`.
    private fun registerFFmpegChannel(messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, "omnitranslator/ffmpeg").setMethodCallHandler { call, result ->
            when (call.method) {
                "ffmpegStart" -> {
                    @Suppress("UNCHECKED_CAST")
                    val args = (call.argument<List<String>>("args") as List<String>).toTypedArray()
                    lastStatTimeMs = -1.0
                    val session: Session = FFmpegKit.executeWithArgumentsAsync(
                        args,
                        object : com.arthenica.ffmpegkit.FFmpegSessionCompleteCallback {
                            override fun apply(session: com.arthenica.ffmpegkit.FFmpegSession) {}
                        },
                        object : com.arthenica.ffmpegkit.LogCallback {
                            override fun apply(log: com.arthenica.ffmpegkit.Log) {}
                        },
                        object : com.arthenica.ffmpegkit.StatisticsCallback {
                            // Statistics.time É property Kotlin de verdade
                            // (var time: Double) -- confirmado via javap no
                            // AAR real, diferente dos membros de Session.
                            override fun apply(statistics: com.arthenica.ffmpegkit.Statistics) {
                                lastStatTimeMs = statistics.time
                            }
                        }
                    )
                    result.success(mapOf("sessionId" to session.getSessionId()))
                }
                "ffmpegPoll" -> {
                    val id = (call.argument<Number>("sessionId"))!!.toLong()
                    val s: Session? = FFmpegKitConfig.getSession(id)
                    // logsTail alimenta o stderrTail do FFmpegKitNextRunner --
                    // é o ÚNICO diagnóstico que sobra quando o ffmpeg falha no
                    // device (a auditoria pegou uma regressão que devolvia ""
                    // fixo, cegando qualquer erro de ffmpeg em produção).
                    result.success(
                        mapOf(
                            "returnCode" to s?.getReturnCode()?.value,
                            "logsTail" to (s?.getAllLogsAsString()?.takeLast(4000) ?: ""),
                            "statTimeMs" to lastStatTimeMs,
                        )
                    )
                }
                "ffmpegCancel" -> {
                    val id = (call.argument<Number>("sessionId"))!!.toLong()
                    FFmpegKit.cancel(id)
                    result.success(null)
                }
                "ffprobe" -> {
                    @Suppress("UNCHECKED_CAST")
                    val args = (call.argument<List<String>>("args") as List<String>).toTypedArray()
                    val s: Session = FFprobeKit.executeWithArguments(args)
                    result.success(
                        mapOf(
                            "returnCode" to s.getReturnCode()?.value,
                            "output" to (s.getOutput() ?: "")
                        )
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Traduz um evento vindo do isolate do job em atualização de notificação
    /// e, em terminal (`jobCompleted`/`jobFailed` -- este último também cobre
    /// cancelamento, distinguível pelo `state` do checkpoint), encerra o
    /// serviço (§14.5: `stopForeground`+`stopSelf` incondicionais).
    private fun onWorkerEvent(kind: String, payload: Map<String, Any?>) {
        // Preferir a mensagem humana do PipelineEvent ("Transcrevendo...")
        // ao nome do estado do checkpoint — que, corrigido pela auditoria,
        // é o estágio CONCLUÍDO anterior ("demuxed" durante a transcrição),
        // verdadeiro pra máquina mas confuso como texto de notificação.
        currentStage = (payload["message"] as? String)?.takeIf { it.isNotBlank() }
            ?: (payload["state"] as? String) ?: currentStage
        val progress = (payload["progress"] as? Number)?.toDouble() ?: 0.0
        currentPercent = (progress * 100).toInt().coerceIn(0, 100)
        when (kind) {
            "jobCompleted", "jobFailed" -> {
                currentJobId = null
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            else -> updateNotification()
        }
    }

    /// Tipo de FGS por versão (auditoria de 2026-07-16, decisão do usuário):
    /// `mediaProcessing` (0x2000) só existe na API 35 — o Android 14 (API 34)
    /// VALIDA o tipo contra a lista conhecida e lança exceção pra um tipo
    /// desconhecido (9–13 só não validam por acaso). Com minSdk=28, devices
    /// 29–34 usam `dataSync` (o tipo que o próprio Android documenta como o
    /// usado pra isso antes do 15); o manifesto declara os dois e a permissão
    /// FOREGROUND_SERVICE_DATA_SYNC (inócua fora da API 34+).
    private fun startForegroundWithPlaceholder() {
        val notification = buildNotification("Iniciando...", 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateNotification() {
        val notification = buildNotification("$currentStage — $currentPercent%", currentPercent)
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
    }

    /// Só APIs de framework (`Notification.Builder`, não `NotificationCompat`)
    /// -- minSdk já é 28, então não há motivo pra puxar uma dependência
    /// AndroidX Core só pra isto quando o framework já cobre tudo que o
    /// §14.5 pede.
    private fun buildNotification(text: String, percent: Int): Notification {
        val cancelIntent = Intent(this, MediaProcessingService::class.java).apply {
            action = ACTION_CANCEL
        }
        val cancelPending = PendingIntent.getService(
            this, 0, cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val openIntent = Intent(this, MainActivity::class.java).apply {
            putExtra("jobId", currentJobId)
            // Exigência documentada de PendingIntent.getActivity: a Activity
            // é iniciada FORA do contexto de outra Activity (é o sistema de
            // notificações quem dispara), então NEW_TASK é obrigatório —
            // sem ele o toque na notificação pode simplesmente não abrir
            // nada (auditoria de 2026-07-16).
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val openPending = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val cancelAction = Notification.Action.Builder(
            Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
            "Cancelar",
            cancelPending
        ).build()
        return Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(currentDisplayName.ifEmpty { "Processamento de vídeo" })
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(openPending)
            .addAction(cancelAction)
            .setProgress(100, percent, false)
            .build()
    }
}
