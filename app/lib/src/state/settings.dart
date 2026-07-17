import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../platform/media_processing_service.dart'
    show appRootDir, workRootDir;

class AppSettings {
  final String workDirBase;

  /// Navegador de onde extrair cookies do YouTube (ex.: "edge", "chrome"),
  /// ou vazio para não usar. Mutuamente exclusivo com [ytDlpCookiesFile].
  final String ytDlpCookiesFromBrowser;

  /// Caminho de um cookies.txt exportado do navegador, ou vazio para não
  /// usar. Mutuamente exclusivo com [ytDlpCookiesFromBrowser].
  final String ytDlpCookiesFile;

  /// Voz fixa escolhida pelo usuário (modelId do manifest + sid), ou
  /// vazio para escolha automática por falante.
  final String voiceModelId;
  final int voiceSid;

  const AppSettings({
    required this.workDirBase,
    this.ytDlpCookiesFromBrowser = '',
    this.ytDlpCookiesFile = '',
    this.voiceModelId = '',
    this.voiceSid = 0,
  });

  static String get _settingsFile {
    final appData = Platform.environment['APPDATA'] ??
        (Platform.environment['USERPROFILE'] != null
            ? '${Platform.environment['USERPROFILE']}\\AppData\\Roaming'
            : p.join(Directory.systemTemp.path, 'omnitranslator_appdata'));
    return p.join(appData, 'omnitranslator', 'settings.json');
  }

  static String get defaultWorkDirBase {
    final tempDir = Platform.environment['TEMP'] ?? 'C:\\temp';
    return p.join(tempDir, 'omnitranslator');
  }

  static AppSettings load() {
    final file = File(_settingsFile);
    if (!file.existsSync()) {
      return AppSettings(workDirBase: defaultWorkDirBase);
    }
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final dir = json['workDirBase'] as String?;
      return AppSettings(
        workDirBase: dir == null || dir.isEmpty ? defaultWorkDirBase : dir,
        ytDlpCookiesFromBrowser: json['ytDlpCookiesFromBrowser'] as String? ?? '',
        ytDlpCookiesFile: json['ytDlpCookiesFile'] as String? ?? '',
        voiceModelId: json['voiceModelId'] as String? ?? '',
        voiceSid: json['voiceSid'] as int? ?? 0,
      );
    } catch (_) {
      return AppSettings(workDirBase: defaultWorkDirBase);
    }
  }

  /// Carrega no Android (D3.4/D-6) — `Platform.environment['APPDATA']`
  /// não existe lá; a raiz vem de `path_provider` (`appRootDir()`), a MESMA
  /// que `service_entrypoint.dart`/`media_processing_service.dart` já usam
  /// pra jobs/models, então settings/jobs/models/work ficam todos irmãos
  /// previsíveis debaixo de um único diretório privado do app. `workDirBase`
  /// default é `workRootDir()` — deliberadamente DIFERENTE de `jobsRootDir()`
  /// (ver o comentário de `workRootDir()`: `pipeline.dart` apaga o `workDir`
  /// de um job bem-sucedido, e isso não pode arriscar levar o checkpoint
  /// junto).
  static Future<AppSettings> loadAndroid() async {
    final defaultDir = await workRootDir();
    final file = File(p.join(await appRootDir(), 'settings.json'));
    if (!file.existsSync()) {
      return AppSettings(workDirBase: defaultDir);
    }
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final dir = json['workDirBase'] as String?;
      return AppSettings(
        workDirBase: dir == null || dir.isEmpty ? defaultDir : dir,
        ytDlpCookiesFromBrowser: json['ytDlpCookiesFromBrowser'] as String? ?? '',
        ytDlpCookiesFile: json['ytDlpCookiesFile'] as String? ?? '',
        voiceModelId: json['voiceModelId'] as String? ?? '',
        voiceSid: json['voiceSid'] as int? ?? 0,
      );
    } catch (_) {
      return AppSettings(workDirBase: defaultDir);
    }
  }

  /// Assíncrono (D3.4) — no Android o path de destino vem de `path_provider`,
  /// que é inerentemente assíncrono; no desktop o corpo é idêntico ao de
  /// antes, só que aguardável.
  Future<void> save() async {
    final path = Platform.isAndroid
        ? p.join(await appRootDir(), 'settings.json')
        : _settingsFile;
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode({
      'workDirBase': workDirBase,
      'ytDlpCookiesFromBrowser': ytDlpCookiesFromBrowser,
      'ytDlpCookiesFile': ytDlpCookiesFile,
      'voiceModelId': voiceModelId,
      'voiceSid': voiceSid,
    }));
  }

  AppSettings copyWith({
    String? workDirBase,
    String? ytDlpCookiesFromBrowser,
    String? ytDlpCookiesFile,
    String? voiceModelId,
    int? voiceSid,
  }) =>
      AppSettings(
        workDirBase: workDirBase ?? this.workDirBase,
        ytDlpCookiesFromBrowser: ytDlpCookiesFromBrowser ?? this.ytDlpCookiesFromBrowser,
        ytDlpCookiesFile: ytDlpCookiesFile ?? this.ytDlpCookiesFile,
        voiceModelId: voiceModelId ?? this.voiceModelId,
        voiceSid: voiceSid ?? this.voiceSid,
      );
}
