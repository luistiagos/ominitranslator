import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _dummyTools = Tools(
  ffmpeg: 'ffmpeg',
  ffprobe: 'ffprobe',
  whisperCli: 'whisper-cli',
  translateLocally: 'translateLocally',
  sherpaSourceSeparation: 'sherpa-separation',
);

void main() {
  group('manifest', () {
    test('contains exactly 25 entries', () {
      expect(ModelManager.manifest.length, 25);
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
}
