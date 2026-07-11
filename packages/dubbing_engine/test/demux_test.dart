import 'dart:io';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/steps/demux.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ToolResult _okResult(String stdout) => ToolResult(0, stdout, '');
ToolResult _failResult([int code = 1]) => ToolResult(code, '', 'ffmpeg error');

void main() {
  late Directory tempDir;
  late DubbingJobConfig config;
  late Tools tools;
  late CancellationToken token;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('demux_test_');
    config = DubbingJobConfig(
      inputVideo: p.join(tempDir.path, 'input.mp4'),
      sourceLang: Lang.en,
      targetLang: Lang.pt,
      preset: Preset.best,
      workDir: tempDir.path,
      outputPath: p.join(tempDir.path, 'output.mp4'),
    );
    File(config.inputVideo).writeAsBytesSync(List.filled(100, 0));
    token = CancellationToken();
    tools = Tools(
      ffmpeg: 'ffmpeg',
      ffprobe: 'ffprobe',
      whisperCli: 'whisper-cli',
      translateLocally: 'translateLocally',
      sherpaSourceSeparation: 'sherpa-separation',
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('runDemux', () {
    test('succeeds and returns video duration', () async {
      final audioOut = p.join(tempDir.path, 'audio_full.wav');
      File(audioOut).writeAsBytesSync(List.filled(100, 0));

      final result = await runDemux(config, tools, token, runToolOverride: (
        String exePath,
        List<String> args, {
        String? workingDirectory,
        Duration timeout = const Duration(minutes: 30),
        CancellationToken? token,
      }) async {
        if (exePath == 'ffprobe') {
          return _okResult('123.456\n');
        }
        return _okResult('');
      });

      expect(result, closeTo(123.456, 0.001));
    });

    test('throws when ffprobe fails', () async {
      await expectLater(
        runDemux(config, tools, token, runToolOverride: (
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          return _failResult(1);
        }),
        throwsA(isA<PipelineException>().having(
          (e) => e.stage,
          'stage',
          PipelineStage.demux,
        )),
      );
    });

    test('throws when ffmpeg fails', () async {
      await expectLater(
        runDemux(config, tools, token, runToolOverride: (
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          if (exePath == 'ffprobe') return _okResult('10.0\n');
          return _failResult(1);
        }),
        throwsA(isA<PipelineException>().having(
          (e) => e.stage,
          'stage',
          PipelineStage.demux,
        )),
      );
    });

    test('throws when audio output is empty (<=44 bytes)', () async {
      final audioOut = p.join(tempDir.path, 'audio_full.wav');
      File(audioOut).writeAsBytesSync(List.filled(44, 0));

      await expectLater(
        runDemux(config, tools, token, runToolOverride: (
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          if (exePath == 'ffprobe') return _okResult('10.0\n');
          return _okResult('');
        }),
        throwsA(isA<PipelineException>().having(
          (e) => e.stage,
          'stage',
          PipelineStage.demux,
        )),
      );
    });

    test('throws when audio output does not exist', () async {
      await expectLater(
        runDemux(config, tools, token, runToolOverride: (
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          if (exePath == 'ffprobe') return _okResult('10.0\n');
          return _okResult('');
        }),
        throwsA(isA<PipelineException>()),
      );
    });
  });
}
