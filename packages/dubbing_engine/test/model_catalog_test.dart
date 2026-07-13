import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:test/test.dart';

final _tools = Tools(
  ffmpeg: 'ffmpeg',
  ffprobe: 'ffprobe',
  whisperCli: 'whisper-cli',
  translateLocally: 'translateLocally',
  sherpaSourceSeparation: 'sherpa-separation',
);

void main() {
  group('ModelCatalog.windows', () {
    test('carrega o manifest do desktop', () {
      final c = ModelCatalog.windows();
      expect(c.platform, ModelPlatform.windows);
      expect(c.entries.length, 64);
      expect(c.separatorModelId, spleeterModelId);
    });

    test('mapeia ASR por preset e voz padrão por idioma', () {
      final c = ModelCatalog.windows();
      expect(c.asrModelIds[Preset.fast], 'whisper-base-q5_1');
      expect(c.asrModelIds[Preset.best], 'whisper-small-q5_1');
      expect(c.defaultVoiceIds[Lang.pt], 'piper-pt-br');
    });

    test('entryOf acha pelo id e devolve null para desconhecido', () {
      final c = ModelCatalog.windows();
      expect(c.entryOf('piper-pt-br')?.lang, Lang.pt);
      expect(c.entryOf('nao-existe'), isNull);
    });

    test('todo id de ASR e de voz padrão tem entrada no catálogo', () {
      final c = ModelCatalog.windows();
      for (final id in c.asrModelIds.values) {
        expect(c.entryOf(id), isNotNull, reason: 'ASR $id sem entrada');
      }
      for (final id in c.defaultVoiceIds.values) {
        expect(c.entryOf(id), isNotNull, reason: 'voz $id sem entrada');
      }
      expect(c.entryOf(c.separatorModelId!), isNotNull);
    });
  });

  group('ModelManager.catalog', () {
    test('usa o catálogo do Windows por padrão', () {
      final m = ModelManager('/tmp/models', _tools);
      expect(m.catalog.platform, ModelPlatform.windows);
      expect(m.catalog.entries.length, 64);
    });

    test('aceita um catálogo injetado — é como o Android entra', () {
      // Sem separador: o Android M1 é voice-over puro, então o `prepare` não
      // pode exigir o modelo de separação.
      final android = ModelCatalog(
        platform: ModelPlatform.android,
        entries: const [
          ModelEntry(
            id: 'whisper-android-tiny',
            kind: 'targz',
            url: 'https://example.invalid/tiny.tar.gz',
            sizeMb: 40,
            expects: ['tiny.onnx'],
            displayName: 'ASR — rápido',
          ),
        ],
        asrModelIds: const {Preset.fast: 'whisper-android-tiny'},
        defaultVoiceIds: const {Lang.pt: 'piper-pt-br'},
      );
      final m = ModelManager('/tmp/models', _tools, catalog: android);
      expect(m.catalog.platform, ModelPlatform.android);
      expect(m.catalog.separatorModelId, isNull);
      expect(m.catalog.entryOf('whisper-android-tiny'), isNotNull);
      // O manifest estático continua sendo o do desktop (compatibilidade).
      expect(ModelManager.manifest.length, 64);
    });
  });
}
