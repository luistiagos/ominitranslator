import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dubbing_engine/src/backends/whisper_transcriber.dart';
import 'package:dubbing_engine/src/wav.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ToolResult _okResult([String stdout = '']) => ToolResult(0, stdout, '');
ToolResult _failResult() => ToolResult(1, '', 'error');

final _tools = Tools(
  ffmpeg: 'ffmpeg',
  ffprobe: 'ffprobe',
  whisperCli: 'whisper-cli',
  translateLocally: 'translateLocally',
  sherpaSourceSeparation: 'sherpa-separation',
);

void main() {
  group('WhisperTranscriber', () {
    test('transcribe returns segments on success', () async {
      final tempDir = Directory.systemTemp.createTempSync('whisper_test_');
      try {
        final wavPath = p.join(tempDir.path, 'audio.wav');
        File(wavPath).writeAsBytesSync(List.filled(100, 0));
        final models = _createWhisperModel(tempDir.path);
        final transcriber = WhisperTranscriber(_tools, models, Preset.best);

        final jsonContent = jsonEncode({
          'transcription': [
            {
              'offsets': {'from': 0, 'to': 2000},
              'text': ' Hello world ',
            },
            {
              'offsets': {'from': 2500, 'to': 4000},
              'text': ' How are you? ',
            },
          ]
        });

        // Pre-create asr_in.wav since mock ffmpeg doesn't create it. WAV
        // com "fala" (senóide) cobrindo as janelas dos segmentos, para o
        // aparador de fala mantê-las intactas.
        final samples = Float32List(5 * 16000);
        void burst(double fromSec, double toSec) {
          for (int i = (fromSec * 16000).round(); i < (toSec * 16000).round(); i++) {
            samples[i] = 0.4 * math.sin(2 * math.pi * 150 * i / 16000);
          }
        }
        burst(0.0, 2.0);
        burst(2.5, 4.0);
        writeWavPcm16(p.join(tempDir.path, 'asr_in.wav'),
            WavData(samples, 16000, 1));

        final result = await transcriber.transcribe(wavPath, Lang.en, CancellationToken(),
            runToolOverride: (String exePath, List<String> args,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
          if (exePath == 'whisper-cli') {
            // Write transcript.json as whisper-cli would
            File(p.join(tempDir.path, 'transcript.json')).writeAsStringSync(jsonContent);
          }
          return _okResult();
        });

        expect(result.length, 2);
        expect(result[0].start.inMilliseconds, lessThanOrEqualTo(60));
        expect(result[0].end.inMilliseconds, closeTo(2000, 60));
        expect(result[0].text, 'Hello world');
        expect(result[1].text, 'How are you?');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('throws when ffmpeg preparation fails', () async {
      final tempDir = Directory.systemTemp.createTempSync('whisper_test_');
      try {
        final wavPath = p.join(tempDir.path, 'audio.wav');
        File(wavPath).writeAsBytesSync(List.filled(100, 0));
        final models = _createWhisperModel(tempDir.path);
        final transcriber = WhisperTranscriber(_tools, models, Preset.best);

        await expectLater(
          transcriber.transcribe(wavPath, Lang.en, CancellationToken(),
              runToolOverride: (_, __,
                  {String? workingDirectory,
                  Duration timeout = const Duration(minutes: 30),
                  CancellationToken? token}) async => _failResult()),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('throws when whisper-cli fails', () async {
      final tempDir = Directory.systemTemp.createTempSync('whisper_test_');
      try {
        final wavPath = p.join(tempDir.path, 'audio.wav');
        File(wavPath).writeAsBytesSync(List.filled(100, 0));
        final models = _createWhisperModel(tempDir.path);
        final transcriber = WhisperTranscriber(_tools, models, Preset.best);

        File(p.join(tempDir.path, 'asr_in.wav')).writeAsBytesSync(List.filled(100, 0));
        var callCount = 0;

        await expectLater(
          transcriber.transcribe(wavPath, Lang.en, CancellationToken(),
              runToolOverride: (String exePath, List<String> args,
                  {String? workingDirectory,
                  Duration timeout = const Duration(minutes: 30),
                  CancellationToken? token}) async {
                callCount++;
                if (callCount == 1) return _okResult();
                return _failResult();
              }),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('throws when transcript.json is missing', () async {
      final tempDir = Directory.systemTemp.createTempSync('whisper_test_');
      try {
        final wavPath = p.join(tempDir.path, 'audio.wav');
        File(wavPath).writeAsBytesSync(List.filled(100, 0));
        final models = _createWhisperModel(tempDir.path);
        final transcriber = WhisperTranscriber(_tools, models, Preset.best);

        File(p.join(tempDir.path, 'asr_in.wav')).writeAsBytesSync(List.filled(100, 0));

        await expectLater(
          transcriber.transcribe(wavPath, Lang.en, CancellationToken(),
              runToolOverride: (_, __,
                  {String? workingDirectory,
                  Duration timeout = const Duration(minutes: 30),
                  CancellationToken? token}) async => _okResult()),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}

ModelManager _createWhisperModel(String root) {
  final base = p.join(root, 'whisper-small-q5_1');
  Directory(base).createSync(recursive: true);
  File(p.join(base, 'ggml-small-q5_1.bin')).writeAsBytesSync([1, 2, 3]);
  File(p.join(base, '.sha256')).writeAsStringSync('hash');
  return ModelManager(root, _tools);
}
