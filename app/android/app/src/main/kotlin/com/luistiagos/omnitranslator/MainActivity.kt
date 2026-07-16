package com.luistiagos.omnitranslator

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// Ponte MethodChannel para as duas capacidades que o engine (Dart puro, sem
/// `package:flutter`) não pode implementar sozinho no Android: espaço livre
/// via `StatFs` (§5.4) e entrada/saída de arquivo via SAF (§13.3 — regra #8
/// do engine é "só paths locais", então o SAF fica inteiramente na borda
/// Kotlin/Dart; o engine nunca vê uma content:// URI).
///
/// `FlutterActivity` estende `Activity` puro (não `ComponentActivity`), então
/// os contratos modernos (`registerForActivityResult`) não estão disponíveis
/// — o padrão clássico `startActivityForResult`/`onActivityResult` é o que
/// a base real oferece.
class MainActivity : FlutterActivity() {
    private var pendingPickResult: MethodChannel.Result? = null

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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "omnitranslator/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getFreeBytes" -> {
                        val path = call.argument<String>("path")!!
                        result.success(freeBytesOf(path))
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

    /// Espaço livre no volume do path, ou null se o `StatFs` falhar (path
    /// inexistente, sem permissão etc.) — o mesmo contrato do
    /// [WindowsDiskSpaceProbe] no lado Dart: null é "não dá para saber", não
    /// erro.
    private fun freeBytesOf(path: String): Long? {
        return try {
            var f = File(path)
            // StatFs exige um path que já existe; sobe até achar um ancestral.
            while (!f.exists()) {
                f = f.parentFile ?: return null
            }
            StatFs(f.absolutePath).availableBytes
        } catch (e: Exception) {
            null
        }
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
