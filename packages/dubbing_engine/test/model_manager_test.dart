import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ToolResult _okResult() => ToolResult(0, '', '');

final _dummyTools = Tools(
  ffmpeg: 'ffmpeg',
  ffprobe: 'ffprobe',
  whisperCli: 'whisper-cli',
  translateLocally: 'translateLocally',
  sherpaSourceSeparation: 'sherpa-separation',
);

void main() {
  group('manifest', () {
    test('contains exactly 64 entries', () {
      expect(ModelManager.manifest.length, 64);
    });

    test('ids are unique', () {
      final ids = ModelManager.manifest.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every dub target has piperModelId, piperVoiceBank (bank[0] == default), pickableVoices and a sample sentence', () {
      for (final lang in Lang.values) {
        if (!lang.isDubTarget) continue;
        final defaultId = piperModelId[lang];
        expect(defaultId, isNotNull, reason: '${lang.code}: piperModelId');
        final bank = piperVoiceBank[lang];
        expect(bank, isNotNull, reason: '${lang.code}: piperVoiceBank');
        expect(bank!.first, defaultId, reason: '${lang.code}: bank[0] deve ser o modelo obrigatório');
        expect(pickableVoices[lang], isNotNull, reason: '${lang.code}: pickableVoices');
        expect(voiceSampleSentence[lang], isNotNull, reason: '${lang.code}: voiceSampleSentence');
      }
    });

    test('every id referenced in piperVoiceBank/pickableVoices/piperModelId exists in the manifest', () {
      final ids = ModelManager.manifest.map((e) => e.id).toSet();
      for (final id in piperModelId.values) {
        expect(ids, contains(id));
      }
      for (final bank in piperVoiceBank.values) {
        for (final id in bank) {
          expect(ids, contains(id));
        }
      }
      for (final voices in pickableVoices.values) {
        for (final v in voices) {
          expect(ids, contains(v.$1));
        }
      }
    });

    test('every piper voice entry declares its language', () {
      for (final entry in ModelManager.manifest) {
        if (entry.id.startsWith('piper-')) {
          expect(entry.lang, isNotNull, reason: entry.id);
        } else {
          expect(entry.lang, isNull, reason: entry.id);
        }
      }
    });

    test('every pickable voice has a manifest entry', () {
      final ids = ModelManager.manifest.map((e) => e.id).toSet();
      for (final voices in pickableVoices.values) {
        for (final v in voices) {
          expect(ids, contains(v.$1), reason: 'voz ${v.$3} sem modelo');
        }
      }
    });

    test('every voice bank id has a manifest entry', () {
      final ids = ModelManager.manifest.map((e) => e.id).toSet();
      for (final bank in piperVoiceBank.values) {
        for (final id in bank) {
          expect(ids, contains(id));
        }
      }
    });

    test('gender tagging model id present', () {
      final ids = ModelManager.manifest.map((e) => e.id).toSet();
      expect(ids, contains('gender-tagging'));
    });

    test('gender voice model ids present', () {
      final ids = ModelManager.manifest.map((e) => e.id).toSet();
      expect(ids, contains('piper-pt-br-dii'));
      expect(ids, contains('piper-en-hfc-female'));
      expect(ids, contains('piper-en-hfc-male'));
    });

    test('diarization and extra voice model ids present', () {
      final ids = ModelManager.manifest.map((e) => e.id).toSet();
      expect(ids, contains('diarization-segmentation'));
      expect(ids, contains('diarization-embedding'));
      expect(ids, contains('piper-pt-br-edresson'));
      expect(ids, contains('piper-en-libritts'));
      expect(ids, contains('piper-es-davefx'));
    });

    test('each entry has required fields', () {
      for (final entry in ModelManager.manifest) {
        expect(entry.id, isNotEmpty);
        expect(entry.kind, anyOf('file', 'tarbz2'));
        expect(entry.url, startsWith('https://'));
        expect(entry.sizeMb, greaterThan(0));
        expect(entry.expects, isNotEmpty);
        expect(entry.displayName, isNotEmpty);
      }
    });

    test('whisper model ids match preset mapping', () {
      final ids = ModelManager.manifest.map((e) => e.id).toSet();
      expect(ids, contains('whisper-small-q5_1'));
      expect(ids, contains('whisper-base-q5_1'));
    });

    test('piper model ids present', () {
      final ids = ModelManager.manifest.map((e) => e.id).toSet();
      expect(ids, contains('piper-en'));
      expect(ids, contains('piper-pt-br'));
      expect(ids, contains('piper-es'));
    });

    test('spleeter model id present', () {
      final ids = ModelManager.manifest.map((e) => e.id).toSet();
      expect(ids, contains('spleeter-2stems-fp16'));
    });
  });

  group('pathOf', () {
    test('returns base path when file is null', () {
      final mgr = ModelManager('C:\\models', _dummyTools);
      expect(mgr.pathOf('whisper-small-q5_1'), 'C:\\models\\whisper-small-q5_1');
    });

    test('returns full path when file is provided', () {
      final mgr = ModelManager('C:\\models', _dummyTools);
      expect(
        mgr.pathOf('whisper-small-q5_1', 'model.bin'),
        'C:\\models\\whisper-small-q5_1\\model.bin',
      );
    });
  });

  group('stateOf', () {
    late Directory tempDir;
    late ModelManager mgr;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('model_state_test_');
      mgr = ModelManager(tempDir.path, _dummyTools);
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('returns missing for non-existent model', () {
      expect(mgr.stateOf('whisper-small-q5_1'), ModelState.missing);
    });

    test('returns ready when all expected files exist with sha256', () {
      final base = p.join(tempDir.path, 'whisper-small-q5_1');
      Directory(base).createSync(recursive: true);
      File(p.join(base, 'ggml-small-q5_1.bin')).writeAsBytesSync([1, 2, 3]);
      final hash = sha256.convert([1, 2, 3]).toString();
      File(p.join(base, '.sha256')).writeAsStringSync(hash);
      expect(mgr.stateOf('whisper-small-q5_1'), ModelState.ready);
    });

    test('returns corrupted when sha256 is missing', () {
      final base = p.join(tempDir.path, 'whisper-small-q5_1');
      Directory(base).createSync(recursive: true);
      File(p.join(base, 'ggml-small-q5_1.bin')).writeAsBytesSync([1, 2, 3]);
      expect(mgr.stateOf('whisper-small-q5_1'), ModelState.corrupted);
    });

    test('returns corrupted when expected file is missing', () {
      final base = p.join(tempDir.path, 'whisper-small-q5_1');
      Directory(base).createSync(recursive: true);
      File(p.join(base, '.sha256')).writeAsStringSync('abc');
      expect(mgr.stateOf('whisper-small-q5_1'), ModelState.corrupted);
    });

    test('returns ready for spleeter with directory expects', () {
      final base = p.join(tempDir.path, 'spleeter-2stems-fp16');
      Directory(base).createSync(recursive: true);
      File(p.join(base, 'vocals.fp16.onnx')).writeAsBytesSync([1]);
      File(p.join(base, 'accompaniment.fp16.onnx')).writeAsBytesSync([2]);
      final combined = sha256.convert([1]).toString() + sha256.convert([2]).toString();
      File(p.join(base, '.sha256')).writeAsStringSync(combined);
      expect(mgr.stateOf('spleeter-2stems-fp16'), ModelState.ready);
    });

    test('returns ready for piper with espeak-ng-data directory', () {
      final base = p.join(tempDir.path, 'piper-en');
      Directory(base).createSync(recursive: true);
      File(p.join(base, 'en_US-lessac-medium.onnx')).writeAsBytesSync([1]);
      File(p.join(base, 'tokens.txt')).writeAsBytesSync([2]);
      Directory(p.join(base, 'espeak-ng-data')).createSync();
      File(p.join(base, '.sha256')).writeAsStringSync('abc');
      expect(mgr.stateOf('piper-en'), ModelState.ready);
    });
  });

  group('downloadWithRetry', () {
    test('succeeds without retry when the first attempt works', () async {
      int calls = 0;
      final result = await downloadWithRetry(() async* {
        calls++;
        yield 0.5;
        yield 1.0;
      }, retryDelay: (_) => Duration.zero).toList();
      expect(calls, 1);
      expect(result, [0.5, 1.0]);
    });

    test('retries after a failed attempt and succeeds, reusing the resume', () async {
      int calls = 0;
      final result = await downloadWithRetry(() async* {
        calls++;
        if (calls == 1) {
          throw StateError('network blip');
        }
        yield 1.0;
      }, retryDelay: (_) => Duration.zero).toList();
      expect(calls, 2);
      expect(result, [1.0]);
    });

    test('gives up and rethrows the original exception after exhausting maxAttempts', () async {
      int calls = 0;
      final stream = downloadWithRetry(() async* {
        calls++;
        throw StateError('persistent failure');
      }, maxAttempts: 3, retryDelay: (_) => Duration.zero);

      await expectLater(stream.toList(), throwsA(isA<StateError>()));
      expect(calls, 3);
    });

    test('waits according to retryDelay between attempts', () async {
      final delaysRequested = <int>[];
      int calls = 0;
      await downloadWithRetry(() async* {
        calls++;
        if (calls < 3) throw StateError('fail');
        yield 1.0;
      }, maxAttempts: 5, retryDelay: (attempt) {
        delaysRequested.add(attempt);
        return Duration.zero;
      }).toList();
      expect(delaysRequested, [1, 2]);
    });
  });

  group('delete', () {
    test('removes model directory', () async {
      final tempDir = Directory.systemTemp.createTempSync('model_delete_test_');
      final mgr = ModelManager(tempDir.path, _dummyTools);
      final base = p.join(tempDir.path, 'test-model');
      Directory(base).createSync(recursive: true);
      File(p.join(base, 'file.bin')).writeAsBytesSync([1]);
      expect(Directory(base).existsSync(), isTrue);

      await mgr.delete('test-model');
      expect(Directory(base).existsSync(), isFalse);
    });

    test('does not throw when model does not exist', () async {
      final tempDir = Directory.systemTemp.createTempSync('model_delete_missing_');
      final mgr = ModelManager(tempDir.path, _dummyTools);
      await expectLater(mgr.delete('nonexistent'), completes);
    });
  });

  group('ensureTranslationModels', () {
    test('downloads a single deduplicated id for hr/sr/bs -> en', () async {
      final tempDir = Directory.systemTemp.createTempSync('ensure_models_test_');
      try {
        final mgr = ModelManager(tempDir.path, _dummyTools);
        final downloadedIds = <String>[];
        await mgr.ensureTranslationModels(Lang.hr, Lang.en, CancellationToken(),
            runToolOverride: (String exePath, List<String> args,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              downloadedIds.add(args[args.indexOf('-d') + 1]);
              return _okResult();
            });
        expect(downloadedIds, ['hbs-eng-tiny']);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('downloads both hops of the pivot for ca -> pt', () async {
      final tempDir = Directory.systemTemp.createTempSync('ensure_models_test_');
      try {
        final mgr = ModelManager(tempDir.path, _dummyTools);
        final downloadedIds = <String>[];
        await mgr.ensureTranslationModels(Lang.ca, Lang.pt, CancellationToken(),
            runToolOverride: (String exePath, List<String> args,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              downloadedIds.add(args[args.indexOf('-d') + 1]);
              return _okResult();
            });
        expect(downloadedIds.toSet(), {'ca-en-tiny', 'en-pt-base'});
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('throws PipelineException when a download fails', () async {
      final tempDir = Directory.systemTemp.createTempSync('ensure_models_test_');
      try {
        final mgr = ModelManager(tempDir.path, _dummyTools);
        await expectLater(
          mgr.ensureTranslationModels(Lang.de, Lang.en, CancellationToken(),
              runToolOverride: (String exePath, List<String> args,
                  {String? workingDirectory,
                  Duration timeout = const Duration(minutes: 30),
                  CancellationToken? token}) async {
                return ToolResult(1, '', 'network error');
              }),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('targz extraction (streaming)', () {
    test('downloads and extracts a real .tar.gz over HTTP', () async {
      final archive = Archive()
        ..addFile(ArchiveFile('model.onnx', 4, [1, 2, 3, 4]))
        ..addFile(ArchiveFile('tokens.txt', 5, utf8.encode('hello')));
      final tarBytes = TarEncoder().encode(archive);
      final gzBytes = GZipEncoder().encode(tarBytes)!;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response.add(gzBytes);
        req.response.close();
      });

      final tempDir = Directory.systemTemp.createTempSync('targz_test_');
      try {
        final entry = ModelEntry(
          id: 'fake-targz',
          kind: 'targz',
          url: 'http://${server.address.address}:${server.port}/model.tar.gz',
          sizeMb: 1,
          expects: ['model.onnx', 'tokens.txt'],
          displayName: 'Fake targz',
        );
        final catalog = ModelCatalog(
          platform: ModelPlatform.android,
          entries: [entry],
          asrModelIds: const {},
          defaultVoiceIds: const {},
        );
        final mgr = ModelManager(tempDir.path, _dummyTools, catalog: catalog);

        final progress = await mgr.download('fake-targz').toList();
        expect(progress.last, 1.0);

        final base = p.join(tempDir.path, 'fake-targz');
        expect(File(p.join(base, 'model.onnx')).readAsBytesSync(), [1, 2, 3, 4]);
        expect(File(p.join(base, 'tokens.txt')).readAsStringSync(), 'hello');
        expect(mgr.stateOf('fake-targz'), ModelState.ready);
        // O .tar.gz baixado e o diretório de extração intermediário não
        // devem sobrar — só os arquivos do modelo e o .sha256.
        expect(File(p.join(base, 'model.tar.gz')).existsSync(), isFalse);
        expect(Directory(p.join(base, '.extract')).existsSync(), isFalse);
      } finally {
        await server.close(force: true);
        tempDir.deleteSync(recursive: true);
      }
    });

    test('flattens a single wrapping directory like upstream tts-models packages', () async {
      // Os pacotes .tar.bz2 do sherpa-onnx hoje têm um diretório de topo
      // (ex.: vits-piper-en_US-lessac-medium/model.onnx); o .tar.gz do
      // Android precisa do mesmo achatamento via _moveContentsUp.
      final archive = Archive()
        ..addFile(ArchiveFile('voice-pkg/model.onnx', 3, [9, 9, 9]))
        ..addFile(ArchiveFile('voice-pkg/tokens.txt', 1, utf8.encode('x')));
      final gzBytes = GZipEncoder().encode(TarEncoder().encode(archive))!;

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response.add(gzBytes);
        req.response.close();
      });

      final tempDir = Directory.systemTemp.createTempSync('targz_wrap_test_');
      try {
        final entry = ModelEntry(
          id: 'fake-wrapped',
          kind: 'targz',
          url: 'http://${server.address.address}:${server.port}/x.tar.gz',
          sizeMb: 1,
          expects: ['model.onnx', 'tokens.txt'],
          displayName: 'Fake wrapped',
        );
        final catalog = ModelCatalog(
          platform: ModelPlatform.android,
          entries: [entry],
          asrModelIds: const {},
          defaultVoiceIds: const {},
        );
        final mgr = ModelManager(tempDir.path, _dummyTools, catalog: catalog);
        await mgr.download('fake-wrapped').toList();

        final base = p.join(tempDir.path, 'fake-wrapped');
        expect(File(p.join(base, 'model.onnx')).existsSync(), isTrue);
        expect(Directory(p.join(base, 'voice-pkg')).existsSync(), isFalse);
      } finally {
        await server.close(force: true);
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('download com kind desconhecido', () {
    test('lança StateError em vez de emitir 1.0 sem baixar nada', () async {
      final tempDir = Directory.systemTemp.createTempSync('bad_kind_test_');
      try {
        final entry = ModelEntry(
          id: 'typo-kind',
          kind: 'tar.gz', // typo proposital — o kind correto é 'targz'
          url: 'https://example.invalid/x.tar.gz',
          sizeMb: 1,
          expects: ['x.onnx'],
          displayName: 'Typo kind',
        );
        final catalog = ModelCatalog(
          platform: ModelPlatform.android,
          entries: [entry],
          asrModelIds: const {},
          defaultVoiceIds: const {},
        );
        final mgr = ModelManager(tempDir.path, _dummyTools, catalog: catalog);
        await expectLater(
            mgr.download('typo-kind').toList(), throwsStateError);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('ModelCatalog.resolveRequiredIds', () {
    ModelCatalog catalogWith(List<ModelEntry> entries) => ModelCatalog(
          platform: ModelPlatform.android,
          entries: entries,
          asrModelIds: const {},
          defaultVoiceIds: const {},
        );

    ModelEntry entry(String id, {List<String> dependsOn = const []}) => ModelEntry(
          id: id,
          kind: 'file',
          url: 'https://example.invalid/$id',
          sizeMb: 1,
          expects: ['$id.bin'],
          displayName: id,
          dependsOn: dependsOn,
        );

    test('returns ids unchanged when nothing declares a dependency', () {
      final catalog = catalogWith([entry('a'), entry('b')]);
      expect(catalog.resolveRequiredIds(['a', 'b']), ['a', 'b']);
    });

    test('pulls in a shared dependency once, even if requested by several voices', () {
      final catalog = catalogWith([
        entry('espeak-ng-data'),
        entry('piper-en', dependsOn: ['espeak-ng-data']),
        entry('piper-pt', dependsOn: ['espeak-ng-data']),
      ]);
      expect(
        catalog.resolveRequiredIds(['piper-en', 'piper-pt']),
        ['piper-en', 'espeak-ng-data', 'piper-pt'],
      );
    });

    test('resolves transitive dependencies', () {
      final catalog = catalogWith([
        entry('c'),
        entry('b', dependsOn: ['c']),
        entry('a', dependsOn: ['b']),
      ]);
      expect(catalog.resolveRequiredIds(['a']), ['a', 'b', 'c']);
    });

    test('is safe against a dependency cycle', () {
      final catalog = catalogWith([
        entry('a', dependsOn: ['b']),
        entry('b', dependsOn: ['a']),
      ]);
      expect(catalog.resolveRequiredIds(['a']), ['a', 'b']);
    });

    test('keeps an id with no catalog entry, without expanding it', () {
      final catalog = catalogWith([entry('a')]);
      expect(catalog.resolveRequiredIds(['a', 'ghost']), ['a', 'ghost']);
    });
  });
}
