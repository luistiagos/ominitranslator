package com.luistiagos.at3bench.at3_bench

import com.arthenica.ffmpegkit.FFmpegKit
import com.arthenica.ffmpegkit.FFmpegKitConfig
import com.arthenica.ffmpegkit.FFprobeKit
import com.arthenica.ffmpegkit.ReturnCode
import com.arthenica.ffmpegkit.Session
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Ponte mínima do AT-3: prova os primitivos que o FFmpegKitNextRunner da D3
// vai precisar — sessão async, statistics->progresso, cancelamento, mapeamento
// de return code. Assinaturas verificadas via javap contra o AAR v8.1.0.
class MainActivity : FlutterActivity() {

    // Último "time" (ms de mídia processada) reportado pela sessão em execução.
    // Statistics.getTime() é double no v8; o Dart lê isto por polling.
    @Volatile private var lastStatTimeMs: Double = -1.0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "at3/ffmpeg")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "ffmpegStart" -> {
                        @Suppress("UNCHECKED_CAST")
                        val args = (call.argument<List<String>>("args") as List<String>).toTypedArray()
                        lastStatTimeMs = -1.0
                        // ffmpeg-kit v8.1.0 é Kotlin e declara os acessores como
                        // FUNÇÕES estilo-Java (getSessionId(), getState()...), não
                        // como propriedades Kotlin — então .sessionId não resolve;
                        // chamar os getters explicitamente.
                        val session: Session = FFmpegKit.executeWithArgumentsAsync(
                            args,
                            { /* complete callback: nada; o Dart faz poll do estado */ },
                            { /* log callback: ignorado; logs vêm do getAllLogsAsString no poll */ },
                            { stat -> lastStatTimeMs = stat.time }, // Statistics.time é property Kotlin
                        )
                        result.success(mapOf("sessionId" to session.getSessionId()))
                    }
                    "ffmpegPoll" -> {
                        val id = (call.argument<Number>("sessionId"))!!.toLong()
                        val s: Session? = FFmpegKitConfig.getSession(id)
                        val rc = s?.getReturnCode()
                        result.success(
                            mapOf(
                                "state" to s?.getState()?.name,
                                "returnCode" to rc?.value, // ReturnCode.value é property Kotlin
                                "isSuccess" to (rc != null && ReturnCode.isSuccess(rc)),
                                "isCancel" to (rc != null && ReturnCode.isCancel(rc)),
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
                                "output" to (s.getOutput() ?: ""),
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
