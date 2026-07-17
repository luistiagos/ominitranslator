package com.luistiagos.omnitranslator

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.Uri
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Ponte MethodChannel para as capacidades que o engine (Dart puro, sem
/// `package:flutter`) não pode implementar sozinho no Android: espaço livre
/// via `StatFs` (§5.4), entrada/saída de arquivo via SAF (§13.3 — regra #8
/// do engine é "só paths locais", então o SAF fica inteiramente na borda
/// Kotlin/Dart; o engine nunca vê uma content:// URI) e o ciclo de vida do
/// `MediaProcessingService` (§14.2/§14.3, D3.3) — `startJob`/`cancelJob`
/// falam com o serviço vivo; `getJob`/`listRecoverableJobs`/`exportJob`
/// (§14.3) NÃO passam por canal nenhum: leem/escrevem `job.json` direto do
/// lado Dart (`media_processing_service.dart`), pra funcionar mesmo com o
/// serviço morto.
///
/// `FlutterActivity` estende `Activity` puro (não `ComponentActivity`), então
/// os contratos modernos (`registerForActivityResult`) não estão disponíveis
/// — o padrão clássico `startActivityForResult`/`onActivityResult` é o que
/// a base real oferece.
class MainActivity : FlutterActivity() {
    private var pendingPickResult: MethodChannel.Result? = null

    private var mediaService: MediaProcessingService? = null
    private var serviceBound = false
    private var activeEventSink: EventChannel.EventSink? = null

    /// `bindService` é assíncrono — se `startJob` chegar antes de
    /// `onServiceConnected` rodar, o pedido fica aqui e é despachado assim
    /// que a conexão completar (determinístico; nada de delay arbitrário).
    private var pendingStart: Triple<String, String, Map<String, Any?>>? = null

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            mediaService = (binder as MediaProcessingService.LocalBinder).getService()
            mediaService?.attachEventSink(activeEventSink)
            pendingStart?.let { (jobId, displayName, config) ->
                mediaService?.startJob(jobId, displayName, config)
                pendingStart = null
            }
        }
        override fun onServiceDisconnected(name: ComponentName?) {
            mediaService = null
        }
    }

    /// Conecta ao `MediaProcessingService` (instanciando-o se preciso — o
    /// engine headless pesado NÃO nasce aqui, só no onStartCommand). Chamado
    /// por `startJob` e pelo onListen do EventChannel (reconexão a um job já
    /// em andamento quando a Activity reabre, §14.6).
    private fun bindMediaService() {
        if (serviceBound) return
        bindService(
            Intent(this, MediaProcessingService::class.java),
            serviceConnection,
            Context.BIND_AUTO_CREATE
        )
        serviceBound = true
    }

    companion object {
        private const val REQUEST_OPEN_DOCUMENT = 4001
        private const val REQUEST_CREATE_DOCUMENT = 4002
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_OPEN_DOCUMENT || requestCode == REQUEST_CREATE_DOCUMENT) {
            val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
            pendingPickResult?.success(uri?.let { mapOf("uri" to it.toString()) })
            pendingPickResult = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        if (serviceBound) {
            mediaService?.attachEventSink(null)
            unbindService(serviceConnection)
            serviceBound = false
            mediaService = null
        }
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "omnitranslator/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getFreeBytes" -> {
                        val path = call.argument<String>("path")!!
                        result.success(DiskSpace.freeBytesOf(path))
                    }
                    "pickImportDocument" -> {
                        // §15.1/AT-5: importar por SAF em vez de path de arquivo
                        // cru — o Android não garante acesso a paths fora do SAF
                        // desde o scoped storage.
                        if (pendingPickResult != null) {
                            // Um segundo pick antes do primeiro resolver
                            // sobrescreveria pendingPickResult e o Future Dart
                            // original nunca completaria.
                            result.error("pick_in_progress", "Já existe um seletor aberto.", null)
                            return@setMethodCallHandler
                        }
                        pendingPickResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "video/*"
                        }
                        startActivityForResult(intent, REQUEST_OPEN_DOCUMENT)
                    }
                    "pickExportLocation" -> {
                        if (pendingPickResult != null) {
                            result.error("pick_in_progress", "Já existe um seletor aberto.", null)
                            return@setMethodCallHandler
                        }
                        val suggestedName = call.argument<String>("suggestedName") ?: "dubbed.mp4"
                        val mimeType = call.argument<String>("mimeType") ?: "video/mp4"
                        pendingPickResult = result
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = mimeType
                            putExtra(Intent.EXTRA_TITLE, suggestedName)
                        }
                        startActivityForResult(intent, REQUEST_CREATE_DOCUMENT)
                    }
                    "copyUriToFile" -> {
                        val uri = Uri.parse(call.argument<String>("uri")!!)
                        val destPath = call.argument<String>("destPath")!!
                        runCopyOffMainThread(result) { copyUriToFile(uri, destPath) }
                    }
                    "copyFileToUri" -> {
                        val srcPath = call.argument<String>("srcPath")!!
                        val uri = Uri.parse(call.argument<String>("uri")!!)
                        runCopyOffMainThread(result) { copyFileToUri(srcPath, uri) }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "omnitranslator/service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startJob" -> {
                        if (mediaService?.hasActiveJob() == true || pendingStart != null) {
                            // Mesmo idioma de erro do "pick_in_progress" acima —
                            // um segundo job pisaria no primeiro dentro do
                            // mesmo serviço (só roda um job por vez). O check
                            // de pendingStart cobre a janela em que o bind
                            // ainda não completou: sem ele, dois startJob
                            // rápidos sobrescreveriam o primeiro em silêncio
                            // DEPOIS de já ter respondido sucesso ao Dart.
                            result.error("job_in_progress", "Já existe uma dublagem em andamento.", null)
                            return@setMethodCallHandler
                        }
                        val jobId = call.argument<String>("jobId")!!
                        val displayName = call.argument<String>("displayName") ?: jobId
                        @Suppress("UNCHECKED_CAST")
                        val config = call.argument<Map<String, Any?>>("config")!!
                        // §14.5: startForegroundService PRIMEIRO — é o que dispara
                        // onStartCommand -> startForeground dentro da janela que o
                        // SO exige, antes mesmo do bind terminar. minSdk=28 já
                        // cobre a API 26 do método puro (sem precisar de
                        // ContextCompat).
                        startForegroundService(Intent(this, MediaProcessingService::class.java))
                        if (mediaService != null) {
                            mediaService!!.startJob(jobId, displayName, config)
                        } else {
                            pendingStart = Triple(jobId, displayName, config)
                            bindMediaService()
                        }
                        result.success(null)
                    }
                    "cancelJob" -> {
                        val jobId = call.argument<String>("jobId")!!
                        mediaService?.cancelJob(jobId)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "omnitranslator/service/events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    activeEventSink = events
                    mediaService?.attachEventSink(events)
                    // Religa a um serviço que JÁ esteja rodando (job iniciado
                    // por uma instância anterior da Activity — §14.6, "UI é
                    // reaberta e reconecta"): sem isto, a Activity recriada
                    // nunca voltava a receber eventos ao vivo (auditoria de
                    // 2026-07-16). BIND_AUTO_CREATE de propósito, não flags=0:
                    // um binding sem AUTO_CREATE não mantém o serviço vivo
                    // após o stopSelf() do fim do job, e um Binder LOCAL
                    // (mesmo processo) nunca dispara onServiceDisconnected em
                    // destruição graciosa — mediaService viraria referência
                    // morta e o próximo startJob falharia em silêncio. O
                    // custo do AUTO_CREATE é só instanciar o objeto Service
                    // (canal de notificação); o engine headless pesado só
                    // nasce no onStartCommand, que continua vindo apenas de
                    // startJob.
                    bindMediaService()
                }
                override fun onCancel(arguments: Any?) {
                    activeEventSink = null
                    mediaService?.attachEventSink(null)
                }
            })
    }

    /// Copia em thread própria: handlers de MethodChannel rodam no MAIN
    /// thread, e copiar um vídeo de centenas de MB nele dispara ANR (limite
    /// ~5s). O resultado volta postado no main looper, como o Flutter exige
    /// para `MethodChannel.Result`.
    private fun runCopyOffMainThread(result: MethodChannel.Result, copy: () -> Long) {
        val mainHandler = Handler(Looper.getMainLooper())
        Thread {
            try {
                val bytes = copy()
                mainHandler.post { result.success(mapOf("bytesCopied" to bytes)) }
            } catch (e: Exception) {
                mainHandler.post { result.error("copy_failed", e.message, null) }
            }
        }.start()
    }

    private fun copyUriToFile(uri: Uri, destPath: String): Long {
        val dest = File(destPath)
        dest.parentFile?.mkdirs()
        contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "openInputStream devolveu null para $uri" }
            dest.outputStream().use { output -> return input.copyTo(output) }
        }
    }

    private fun copyFileToUri(srcPath: String, uri: Uri): Long {
        val src = File(srcPath)
        contentResolver.openOutputStream(uri).use { output ->
            requireNotNull(output) { "openOutputStream devolveu null para $uri" }
            src.inputStream().use { input -> return input.copyTo(output) }
        }
    }
}
