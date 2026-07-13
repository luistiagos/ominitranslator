import 'dart:io';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/runtime/media_tool_runner.dart';
import 'package:dubbing_engine/src/steps/muxer.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ToolResult _okResult([String stdout = '']) => ToolResult(0, stdout, '');
ToolResult _failResult([int code = 1]) => ToolResult(code, '', 'error');

void main() {
  late Directory tempDir;
  late DubbingJobConfig config;
  late Tools tools;
  late CancellationToken token;
  late String dubbedWav;

  MediaToolRunner media(RunToolFn fn) =>
      DesktopMediaToolRunner(tools, runToolOverride: fn);

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('muxer_test_');
    config = DubbingJobConfig(
      inputVideo: p.join(tempDir.path, 'input.mp4'),
      sourceLang: Lang.en,
      targetLang: Lang.pt,
      preset: Preset.best,
      keepOriginalTrack: true,
      generateSrt: false,
      workDir: tempDir.path,
      outputPath: p.join(tempDir.path, 'output.mp4'),
    );
    File(config.inputVideo).writeAsBytesSync(List.filled(100, 0));
    dubbedWav = p.join(tempDir.path, 'dubbed.wav');
    File(dubbedWav).writeAsBytesSync(List.filled(100, 0));
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

  group('buildFinalVideo', () {
    test('succeeds with copy codec and returns output path', () async {
      File(config.outputPath).writeAsBytesSync(List.filled(100, 0));
      final result = await buildFinalVideo(
        config,
        dubbedWav,
        media((
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          return _okResult();
        }),
        token,
      );

      expect(result, config.outputPath);
    });

    test('succeeds with keepOriginalTrack=false and returns output path',
        () async {
      config = DubbingJobConfig(
        inputVideo: p.join(tempDir.path, 'input.mp4'),
        sourceLang: Lang.en,
        targetLang: Lang.pt,
        preset: Preset.best,
        keepOriginalTrack: false,
        generateSrt: false,
        workDir: tempDir.path,
        outputPath: p.join(tempDir.path, 'output.mp4'),
      );
      File(config.outputPath).writeAsBytesSync(List.filled(100, 0));

      final result = await buildFinalVideo(
        config,
        dubbedWav,
        media((
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          return _okResult();
        }),
        token,
      );

      expect(result, config.outputPath);
    });

    test('retries with libopenh264 on failure for .mp4 and succeeds', () async {
      File(config.outputPath).writeAsBytesSync(List.filled(100, 0));
      var callCount = 0;

      final result = await buildFinalVideo(
        config,
        dubbedWav,
        media((
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          callCount++;
          if (callCount == 1) return _failResult(1);
          // O ffmpeg distribuído é LGPL (`--disable-libx264`): pedir x264 aqui
          // fazia o fallback falhar sempre, justo no caso que ele existe para
          // salvar (VP9/WebM). Este teste antes exigia libx264 e passava, porque
          // o ffmpeg é mockado e ninguém rodava o comando de verdade.
          expect(args.contains('libopenh264'), isTrue,
              reason: 'retry should re-encode with the LGPL H.264 encoder');
          expect(args.contains('libx264'), isFalse,
              reason: 'libx264 is not compiled into the shipped ffmpeg');
          return _okResult();
        }),
        token,
      );

      expect(callCount, 2);
      expect(result, config.outputPath);
    });

    test('retry for .mp4 throws when both attempts fail', () async {
      await expectLater(
        buildFinalVideo(
          config,
          dubbedWav,
          media((
            String exePath,
            List<String> args, {
            String? workingDirectory,
            Duration timeout = const Duration(minutes: 30),
            CancellationToken? token,
          }) async {
            return _failResult(1);
          }),
          token,
        ),
        throwsA(isA<PipelineException>().having(
          (e) => e.stage,
          'stage',
          PipelineStage.mux,
        )),
      );
    });

    test('retries with libopenh264 for non-mp4 inputs too (e.g. WebM/VP9)',
        () async {
      config = DubbingJobConfig(
        inputVideo: p.join(tempDir.path, 'input.webm'),
        sourceLang: Lang.en,
        targetLang: Lang.pt,
        preset: Preset.best,
        workDir: tempDir.path,
        outputPath: p.join(tempDir.path, 'output.mp4'),
      );
      File(config.inputVideo).writeAsBytesSync(List.filled(100, 0));
      File(config.outputPath).writeAsBytesSync(List.filled(100, 0));

      var callCount = 0;
      final result = await buildFinalVideo(
        config,
        dubbedWav,
        media((
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          callCount++;
          // "-c:v copy" de VP9 num container MP4 falha; o re-encode salva.
          if (callCount == 1) return _failResult(1);
          expect(args.contains('libopenh264'), isTrue);
          expect(args.contains('libx264'), isFalse);
          return _okResult();
        }),
        token,
      );

      expect(callCount, 2);
      expect(result, config.outputPath);
    });

    test('throws when output file does not exist after success', () async {
      config = DubbingJobConfig(
        inputVideo: p.join(tempDir.path, 'input.mp4'),
        sourceLang: Lang.en,
        targetLang: Lang.pt,
        preset: Preset.best,
        workDir: tempDir.path,
        outputPath: p.join(tempDir.path, 'nonexistent.mp4'),
      );

      await expectLater(
        buildFinalVideo(
          config,
          dubbedWav,
          media((
            String exePath,
            List<String> args, {
            String? workingDirectory,
            Duration timeout = const Duration(minutes: 30),
            CancellationToken? token,
          }) async {
            return _okResult();
          }),
          token,
        ),
        throwsA(isA<PipelineException>().having(
          (e) => e.stage,
          'stage',
          PipelineStage.mux,
        )),
      );
    });
  });
}
