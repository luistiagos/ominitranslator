import 'dart:io';
import 'package:dubbing_engine/src/backends/sherpa_separator.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:dubbing_engine/src/wav.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'dart:typed_data';

ToolResult _okResult() => ToolResult(0, '', '');
ToolResult _failResult() => ToolResult(1, '', 'error');

/// Escreve um WAV cuja duração reportada é [seconds], sem gerar um arquivo
/// grande de verdade (sampleRate baixo e poucos samples).
void _writeFakeInputWav(String path, double seconds) {
  writeWavPcm16(path, WavData(Float32List((seconds * 100).round()), 100, 1));
}

void main() {
  group('SherpaSeparator (áudio curto - caminho único)', () {
    test('separate fails when model is not ready', () async {
      final tempDir = Directory.systemTemp.createTempSync('sherpa_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final separator = SherpaSeparator(_tools, models);
        final inputWav = p.join(tempDir.path, 'input.wav');
        _writeFakeInputWav(inputWav, 10);
        final outcome = await separator.separate(inputWav, tempDir.path, CancellationToken());
        expect(outcome.ok, isFalse);
        expect(outcome.detail, contains('não está pronto'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('separate fails when sherpa binary is missing', () async {
      final tempDir = Directory.systemTemp.createTempSync('sherpa_test_');
      try {
        final models = _createReadyModel(tempDir.path);
        final toolsWithMissingBinary = Tools(
          ffmpeg: 'ffmpeg',
          ffprobe: 'ffprobe',
          whisperCli: 'whisper-cli',
          translateLocally: 'translateLocally',
          sherpaSourceSeparation: p.join(tempDir.path, 'nonexistent.exe'),
        );
        final separator = SherpaSeparator(toolsWithMissingBinary, models);
        final inputWav = p.join(tempDir.path, 'input.wav');
        _writeFakeInputWav(inputWav, 10);
        final outcome = await separator.separate(inputWav, tempDir.path, CancellationToken());
        expect(outcome.ok, isFalse);
        expect(outcome.detail, contains('não encontrado'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('separate fails and propagates stderr when sherpa CLI fails', () async {
      final tempDir = Directory.systemTemp.createTempSync('sherpa_test_');
      try {
        final sherpaBin = p.join(tempDir.path, 'sherpa-separation.exe');
        File(sherpaBin).writeAsBytesSync([1, 2, 3]);
        final tools = Tools(
          ffmpeg: 'ffmpeg',
          ffprobe: 'ffprobe',
          whisperCli: 'whisper-cli',
          translateLocally: 'translateLocally',
          sherpaSourceSeparation: sherpaBin,
        );
        final models = _createReadyModel(tempDir.path);
        final separator = SherpaSeparator(tools, models);
        final inputWav = p.join(tempDir.path, 'input.wav');
        _writeFakeInputWav(inputWav, 10);

        final outcome = await separator.separate(inputWav, tempDir.path, CancellationToken(),
            runToolOverride: (_, __, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async => _failResult());
        expect(outcome.ok, isFalse);
        expect(outcome.detail, contains('código 1'));
        expect(outcome.detail, contains('error'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('separate returns paths when successful', () async {
      final tempDir = Directory.systemTemp.createTempSync('sherpa_test_');
      try {
        final sherpaBin = p.join(tempDir.path, 'sherpa-separation.exe');
        File(sherpaBin).writeAsBytesSync([1, 2, 3]);
        final tools = Tools(
          ffmpeg: 'ffmpeg',
          ffprobe: 'ffprobe',
          whisperCli: 'whisper-cli',
          translateLocally: 'translateLocally',
          sherpaSourceSeparation: sherpaBin,
        );
        final models = _createReadyModel(tempDir.path);
        final separator = SherpaSeparator(tools, models);
        final inputWav = p.join(tempDir.path, 'input.wav');
        _writeFakeInputWav(inputWav, 10);

        // Pre-create output files that runTool mock should have created
        File(p.join(tempDir.path, 'vocals.wav')).writeAsBytesSync([1]);
        File(p.join(tempDir.path, 'accompaniment.wav')).writeAsBytesSync([2]);

        final outcome = await separator.separate(inputWav, tempDir.path, CancellationToken(),
            runToolOverride: (_, __, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async => _okResult());
        expect(outcome.ok, isTrue);
        expect(outcome.files!.vocalsWav, p.join(tempDir.path, 'vocals.wav'));
        expect(outcome.files!.accompanimentWav, p.join(tempDir.path, 'accompaniment.wav'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('separate fails when output files are missing after success', () async {
      final tempDir = Directory.systemTemp.createTempSync('sherpa_test_');
      try {
        final sherpaBin = p.join(tempDir.path, 'sherpa-separation.exe');
        File(sherpaBin).writeAsBytesSync([1, 2, 3]);
        final tools = Tools(
          ffmpeg: 'ffmpeg',
          ffprobe: 'ffprobe',
          whisperCli: 'whisper-cli',
          translateLocally: 'translateLocally',
          sherpaSourceSeparation: sherpaBin,
        );
        final models = _createReadyModel(tempDir.path);
        final separator = SherpaSeparator(tools, models);
        final inputWav = p.join(tempDir.path, 'input.wav');
        _writeFakeInputWav(inputWav, 10);

        // runTool returns ok, but no output files created
        final outcome = await separator.separate(inputWav, tempDir.path, CancellationToken(),
            runToolOverride: (_, __, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async => _okResult());
        expect(outcome.ok, isFalse);
        expect(outcome.detail, contains('não gerou'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('short audio triggers exactly one sherpa invocation, no ffmpeg', () async {
      final tempDir = Directory.systemTemp.createTempSync('sherpa_test_');
      try {
        final sherpaBin = p.join(tempDir.path, 'sherpa-separation.exe');
        File(sherpaBin).writeAsBytesSync([1, 2, 3]);
        final tools = Tools(
          ffmpeg: 'ffmpeg',
          ffprobe: 'ffprobe',
          whisperCli: 'whisper-cli',
          translateLocally: 'translateLocally',
          sherpaSourceSeparation: sherpaBin,
        );
        final models = _createReadyModel(tempDir.path);
        final separator = SherpaSeparator(tools, models);
        final inputWav = p.join(tempDir.path, 'input.wav');
        _writeFakeInputWav(inputWav, 20); // <= separationChunkSeconds (30)

        final calls = <String>[];
        final outcome = await separator.separate(inputWav, tempDir.path, CancellationToken(),
            runToolOverride: (exe, args, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async {
          calls.add(exe);
          if (exe == sherpaBin) {
            for (final a in args) {
              if (a.startsWith('--output-vocals-wav=')) {
                File(a.substring('--output-vocals-wav='.length)).writeAsBytesSync([1]);
              } else if (a.startsWith('--output-accompaniment-wav=')) {
                File(a.substring('--output-accompaniment-wav='.length)).writeAsBytesSync([2]);
              }
            }
          }
          return _okResult();
        });

        expect(outcome.ok, isTrue);
        expect(calls, [sherpaBin]);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('SherpaSeparator (áudio longo - chunking)', () {
    test('splits, separates each chunk and concatenates', () async {
      final tempDir = Directory.systemTemp.createTempSync('sherpa_test_');
      try {
        final sherpaBin = p.join(tempDir.path, 'sherpa-separation.exe');
        File(sherpaBin).writeAsBytesSync([1, 2, 3]);
        final tools = Tools(
          ffmpeg: 'ffmpeg',
          ffprobe: 'ffprobe',
          whisperCli: 'whisper-cli',
          translateLocally: 'translateLocally',
          sherpaSourceSeparation: sherpaBin,
        );
        final models = _createReadyModel(tempDir.path);
        final separator = SherpaSeparator(tools, models);
        final inputWav = p.join(tempDir.path, 'input.wav');
        _writeFakeInputWav(inputWav, 300); // > 120s -> 3 chunks de 120/120/60

        final sherpaCalls = <String>[];
        final ffmpegCalls = <List<String>>[];

        final outcome = await separator.separate(inputWav, tempDir.path, CancellationToken(),
            runToolOverride: (exe, args, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async {
          if (exe == 'ffmpeg') {
            ffmpegCalls.add(args);
            if (args.contains('segment')) {
              final chunkDir = workingDirectory!;
              for (int i = 0; i < 3; i++) {
                File(p.join(chunkDir, 'chunk_${'$i'.padLeft(3, '0')}.wav'))
                    .writeAsBytesSync([1, 2, 3]);
              }
            } else if (args.contains('concat')) {
              final chunkDir = workingDirectory!;
              final outputArg = args.last;
              File(outputArg).writeAsBytesSync([9]);
              // outputArg pode ser relativo ao chunkDir ou absoluto — garantir
              // que o arquivo final também exista no caminho absoluto esperado.
              if (!p.isAbsolute(outputArg)) {
                File(p.join(chunkDir, outputArg)).writeAsBytesSync([9]);
              }
            }
            return _okResult();
          } else if (exe == sherpaBin) {
            sherpaCalls.add(args.firstWhere((a) => a.startsWith('--input-wav=')));
            for (final a in args) {
              if (a.startsWith('--output-vocals-wav=')) {
                File(a.substring('--output-vocals-wav='.length)).writeAsBytesSync([1]);
              } else if (a.startsWith('--output-accompaniment-wav=')) {
                File(a.substring('--output-accompaniment-wav='.length)).writeAsBytesSync([2]);
              }
            }
            return _okResult();
          }
          return _okResult();
        });

        expect(outcome.ok, isTrue, reason: outcome.detail);
        expect(sherpaCalls.length, 3);
        expect(ffmpegCalls.length, 3); // 1 segment + 2 concat
        expect(File(p.join(tempDir.path, 'vocals.wav')).existsSync(), isTrue);
        expect(File(p.join(tempDir.path, 'accompaniment.wav')).existsSync(), isTrue);
        expect(Directory(p.join(tempDir.path, 'sep_chunks')).existsSync(), isFalse);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('sherpa failure retries with halved chunks and succeeds', () async {
      final tempDir = Directory.systemTemp.createTempSync('sherpa_test_');
      try {
        final sherpaBin = p.join(tempDir.path, 'sherpa-separation.exe');
        File(sherpaBin).writeAsBytesSync([1, 2, 3]);
        final tools = Tools(
          ffmpeg: 'ffmpeg',
          ffprobe: 'ffprobe',
          whisperCli: 'whisper-cli',
          translateLocally: 'translateLocally',
          sherpaSourceSeparation: sherpaBin,
        );
        final models = _createReadyModel(tempDir.path);
        final separator = SherpaSeparator(tools, models);
        final inputWav = p.join(tempDir.path, 'input.wav');
        _writeFakeInputWav(inputWav, 90);

        final segmentTimes = <String>[];
        String currentSegTime = '';
        final outcome = await separator.separate(inputWav, tempDir.path, CancellationToken(),
            runToolOverride: (exe, args, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async {
          if (exe == 'ffmpeg') {
            if (args.contains('segment')) {
              currentSegTime = args[args.indexOf('-segment_time') + 1];
              segmentTimes.add(currentSegTime);
              final chunkDir = workingDirectory!;
              for (int i = 0; i < 3; i++) {
                File(p.join(chunkDir, 'chunk_${'$i'.padLeft(3, '0')}.wav'))
                    .writeAsBytesSync([1, 2, 3]);
              }
            } else if (args.contains('concat')) {
              File(args.last).writeAsBytesSync([9]);
            }
            return _okResult();
          } else if (exe == sherpaBin) {
            // Primeira tentativa (chunks de 30s) "estoura memória"; a de 15s passa.
            if (currentSegTime == '30') {
              return ToolResult(-1073740791, '', 'onnxruntime BFCArena OOM error');
            }
            for (final a in args) {
              if (a.startsWith('--output-vocals-wav=')) {
                File(a.substring('--output-vocals-wav='.length)).writeAsBytesSync([1]);
              } else if (a.startsWith('--output-accompaniment-wav=')) {
                File(a.substring('--output-accompaniment-wav='.length)).writeAsBytesSync([2]);
              }
            }
            return _okResult();
          }
          return _okResult();
        });

        expect(outcome.ok, isTrue, reason: outcome.detail);
        expect(segmentTimes, ['30', '15']);
        expect(File(p.join(tempDir.path, 'vocals.wav')).existsSync(), isTrue);
        expect(File(p.join(tempDir.path, 'accompaniment.wav')).existsSync(), isTrue);
        expect(Directory(p.join(tempDir.path, 'sep_chunks')).existsSync(), isFalse);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('persistent sherpa failure stops at chunk floor with reason and cleans up', () async {
      final tempDir = Directory.systemTemp.createTempSync('sherpa_test_');
      try {
        final sherpaBin = p.join(tempDir.path, 'sherpa-separation.exe');
        File(sherpaBin).writeAsBytesSync([1, 2, 3]);
        final tools = Tools(
          ffmpeg: 'ffmpeg',
          ffprobe: 'ffprobe',
          whisperCli: 'whisper-cli',
          translateLocally: 'translateLocally',
          sherpaSourceSeparation: sherpaBin,
        );
        final models = _createReadyModel(tempDir.path);
        final separator = SherpaSeparator(tools, models);
        final inputWav = p.join(tempDir.path, 'input.wav');
        _writeFakeInputWav(inputWav, 90);

        final segmentTimes = <String>[];
        final outcome = await separator.separate(inputWav, tempDir.path, CancellationToken(),
            runToolOverride: (exe, args, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async {
          if (exe == 'ffmpeg') {
            if (args.contains('segment')) {
              segmentTimes.add(args[args.indexOf('-segment_time') + 1]);
              final chunkDir = workingDirectory!;
              for (int i = 0; i < 3; i++) {
                File(p.join(chunkDir, 'chunk_${'$i'.padLeft(3, '0')}.wav'))
                    .writeAsBytesSync([1, 2, 3]);
              }
            }
            return _okResult();
          } else if (exe == sherpaBin) {
            return ToolResult(-1073740791, '', 'onnxruntime BFCArena OOM error');
          }
          return _okResult();
        });

        expect(outcome.ok, isFalse);
        // 15 ~/ 2 = 7 < minSeparationChunkSeconds (10) -> para em 15s.
        expect(segmentTimes, ['30', '15']);
        expect(outcome.detail, contains('com chunks de 15s'));
        expect(outcome.detail, contains('BFCArena'));
        expect(Directory(p.join(tempDir.path, 'sep_chunks')).existsSync(), isFalse);
        expect(File(p.join(tempDir.path, 'vocals.wav')).existsSync(), isFalse);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('ffmpeg split failure does not retry', () async {
      final tempDir = Directory.systemTemp.createTempSync('sherpa_test_');
      try {
        final sherpaBin = p.join(tempDir.path, 'sherpa-separation.exe');
        File(sherpaBin).writeAsBytesSync([1, 2, 3]);
        final tools = Tools(
          ffmpeg: 'ffmpeg',
          ffprobe: 'ffprobe',
          whisperCli: 'whisper-cli',
          translateLocally: 'translateLocally',
          sherpaSourceSeparation: sherpaBin,
        );
        final models = _createReadyModel(tempDir.path);
        final separator = SherpaSeparator(tools, models);
        final inputWav = p.join(tempDir.path, 'input.wav');
        _writeFakeInputWav(inputWav, 90);

        int ffmpegCalls = 0;
        final outcome = await separator.separate(inputWav, tempDir.path, CancellationToken(),
            runToolOverride: (exe, args, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async {
          if (exe == 'ffmpeg') {
            ffmpegCalls++;
            return ToolResult(1, '', 'segment muxer error');
          }
          return _okResult();
        });

        expect(outcome.ok, isFalse);
        expect(ffmpegCalls, 1);
        expect(outcome.detail, contains('ffmpeg segment falhou'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}

final _tools = Tools(
  ffmpeg: 'ffmpeg',
  ffprobe: 'ffprobe',
  whisperCli: 'whisper-cli',
  translateLocally: 'translateLocally',
  sherpaSourceSeparation: 'sherpa-separation.exe',
);

ModelManager _createReadyModel(String root) {
  final base = p.join(root, 'spleeter-2stems-fp16');
  Directory(base).createSync(recursive: true);
  File(p.join(base, 'vocals.fp16.onnx')).writeAsBytesSync([1]);
  File(p.join(base, 'accompaniment.fp16.onnx')).writeAsBytesSync([2]);
  File(p.join(base, '.sha256')).writeAsStringSync('hash');
  return ModelManager(root, _tools);
}
