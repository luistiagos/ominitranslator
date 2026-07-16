package com.luistiagos.omnitranslator

import android.os.StatFs
import java.io.File

/// Extraído de MainActivity.kt (D3.3, revisão de 2026-07-16): tanto a
/// Activity (`omnitranslator/storage`) quanto o `MediaProcessingService`
/// precisam de `getFreeBytes` — o serviço porque `runDubbingJob`'s estágio
/// `prepare` chama `runtime.diskSpace.freeBytes()` de dentro do PRÓPRIO
/// isolate/engine headless, que tem seu `binaryMessenger` separado do da
/// Activity (dois `FlutterEngine`s no mesmo processo). Mesmo processo/
/// contexto nos dois casos, então não há razão pra duplicar a lógica.
object DiskSpace {
    /// Espaço livre no volume do path, ou null se o `StatFs` falhar (path
    /// inexistente, sem permissão etc.) — o mesmo contrato do
    /// [WindowsDiskSpaceProbe] no lado Dart: null é "não dá para saber", não
    /// erro.
    fun freeBytesOf(path: String): Long? {
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
}
