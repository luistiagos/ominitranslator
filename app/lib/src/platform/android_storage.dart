import 'package:flutter/services.dart';
import 'package:dubbing_engine/dubbing_engine.dart';

/// Ponte para o `MainActivity.kt` (StatFs + SAF) — §5.4/§13.3. O engine é
/// Dart puro e não conhece `MethodChannel`; esta é a única casa onde
/// `omnitranslator/storage` aparece do lado Dart.
const _channel = MethodChannel('omnitranslator/storage');

/// [DiskSpaceProbe] real do Android, ligado ao `StatFs` via [_channel].
AndroidDiskSpaceProbe createAndroidDiskSpaceProbe() {
  return AndroidDiskSpaceProbe((path) async {
    return await _channel.invokeMethod<int>('getFreeBytes', {'path': path});
  });
}

/// Abre o seletor de documentos (`ACTION_OPEN_DOCUMENT`) para importar um
/// vídeo. Devolve a `content://` URI escolhida, ou null se o usuário
/// cancelou.
Future<String?> pickImportDocument() async {
  final r = await _channel.invokeMapMethod<String, dynamic>('pickImportDocument');
  return r?['uri'] as String?;
}

/// Abre o seletor de destino (`ACTION_CREATE_DOCUMENT`) para exportar o
/// resultado. Devolve a `content://` URI escolhida, ou null se cancelado.
Future<String?> pickExportLocation({
  required String suggestedName,
  String mimeType = 'video/mp4',
}) async {
  final r = await _channel.invokeMapMethod<String, dynamic>('pickExportLocation', {
    'suggestedName': suggestedName,
    'mimeType': mimeType,
  });
  return r?['uri'] as String?;
}

/// Copia o conteúdo de uma `content://` URI (import) para um path local —
/// é assim que uma entrada escolhida por SAF entra no workdir do engine (o
/// engine só conhece paths locais).
Future<int> copyUriToLocalFile(String uri, String destPath) async {
  final r = await _channel.invokeMapMethod<String, dynamic>('copyUriToFile', {
    'uri': uri,
    'destPath': destPath,
  });
  return (r?['bytesCopied'] as num?)?.toInt() ?? 0;
}

/// Copia um arquivo local (a saída final do engine) para uma `content://`
/// URI escolhida por export SAF.
Future<int> copyLocalFileToUri(String srcPath, String uri) async {
  final r = await _channel.invokeMapMethod<String, dynamic>('copyFileToUri', {
    'srcPath': srcPath,
    'uri': uri,
  });
  return (r?['bytesCopied'] as num?)?.toInt() ?? 0;
}
