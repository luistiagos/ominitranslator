import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

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

  void save() {
    final file = File(_settingsFile);
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
