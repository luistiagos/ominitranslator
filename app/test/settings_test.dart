import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:omnitranslator_app/src/state/settings.dart';

/// Mesmo fake usado em media_processing_service_test.dart (D3.3) —
/// `AppSettings.loadAndroid()`/`.save()` são testáveis no host porque
/// dependem só do `PathProviderPlatform.instance` pluggable, não de
/// `Platform.isAndroid` em si (`save()` é que decide o path por
/// `Platform.isAndroid`, mas os métodos Android-específicos sempre usam a
/// raiz mockada).
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.supportPath);
  final String supportPath;
  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('settings_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('AppSettings.loadAndroid() (D3.4/D-6)', () {
    test('sem settings.json: default workDirBase é workRootDir()', () async {
      final settings = await AppSettings.loadAndroid();
      expect(settings.workDirBase, p.join(tmp.path, 'work'));
      expect(settings.ytDlpCookiesFromBrowser, '');
      expect(settings.voiceModelId, '');
      expect(settings.voiceSid, 0);
    });

    test('settings.json corrompido cai pro default sem lançar', () async {
      File(p.join(tmp.path, 'settings.json')).writeAsStringSync('{ não é json');
      final settings = await AppSettings.loadAndroid();
      expect(settings.workDirBase, p.join(tmp.path, 'work'));
    });

    test('workDirBase vazio no JSON cai pro default, não fica vazio', () async {
      File(p.join(tmp.path, 'settings.json'))
          .writeAsStringSync('{"workDirBase": ""}');
      final settings = await AppSettings.loadAndroid();
      expect(settings.workDirBase, p.join(tmp.path, 'work'));
    });
  });

  group('AppSettings.loadAndroid() ida e volta com o JSON que save() grava',
      () {
    // save() decide o DESTINO por Platform.isAndroid, que não é mockável
    // neste host Windows (§ "Verificação" do plano D3.4) — o round-trip
    // real save()->loadAndroid() só é verificável no device. O que dá pra
    // testar aqui, e cobre o que realmente importa (o parsing), é que
    // loadAndroid() lê corretamente um settings.json com EXATAMENTE o
    // formato que save() produz (mesmos nomes de campo, ver settings.dart).
    test('lê de volta todos os campos gravados no formato de save()', () async {
      final file = File(p.join(tmp.path, 'settings.json'));
      file.writeAsStringSync('''
{
  "workDirBase": "/custom/work",
  "ytDlpCookiesFromBrowser": "chrome",
  "ytDlpCookiesFile": "",
  "voiceModelId": "piper-android-pt-br",
  "voiceSid": 2
}
''');
      final loaded = await AppSettings.loadAndroid();
      expect(loaded.workDirBase, '/custom/work');
      expect(loaded.ytDlpCookiesFromBrowser, 'chrome');
      expect(loaded.voiceModelId, 'piper-android-pt-br');
      expect(loaded.voiceSid, 2);
    });
  });
}
