import 'package:dubbing_engine/src/backends/android_transcriber.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/runtime/media_tool_runner.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:test/test.dart';

final _tools = Tools(
  ffmpeg: 'ffmpeg',
  ffprobe: 'ffprobe',
  whisperCli: 'whisper-cli',
  translateLocally: 'translateLocally',
  sherpaSourceSeparation: 'sherpa-separation',
);

class _FakeRunner implements MediaToolRunner {
  final List<(MediaTool, List<String>)> calls = [];
  ToolResult Function(MediaTool tool, List<String> args)? onRun;

  @override
  Future<ToolResult> run(
    MediaTool tool,
    List<String> args, {
    String? workingDirectory,
    Duration timeout = const Duration(minutes: 30),
    CancellationToken? token,
    void Function(double progress)? onProgress,
  }) async {
    calls.add((tool, args));
    return onRun?.call(tool, args) ?? ToolResult(0, '', '');
  }
}

void main() {
  // O caminho de sucesso completo (VAD + Whisper reais via FFI) precisa dos
  // modelos ONNX e do .so do sherpa — é o smoke test no device, não unidade.
  // Aqui trava-se o que dá pra travar sem FFI: a conversão obrigatória para
  // 16kHz mono ANTES do ASR (o pipeline passa o audio_full.wav do demux, que
  // é 44,1kHz estéreo — bug B1 da revisão de 2026-07-16) e o erro claro
  // quando a conversão falha.
  group('AndroidTranscriber', () {
    test('converts the input to 16kHz mono asr_in.wav before anything else', () async {
      final models = ModelManager('/m', _tools, catalog: ModelCatalog.android());
      final runner = _FakeRunner();
      // Falha a conversão de propósito: o teste é sobre a CHAMADA de
      // conversão (args certos, antes de qualquer FFI), não sobre o ASR.
      runner.onRun = (_, __) => ToolResult(1, '', 'ffmpeg fail');
      final transcriber = AndroidTranscriber(models, Preset.fast, runner);

      await expectLater(
        () => transcriber.transcribe('/work/audio_full.wav', Lang.en, CancellationToken()),
        throwsA(isA<PipelineException>()
            .having((e) => e.stage, 'stage', PipelineStage.transcribe)),
      );

      expect(runner.calls, hasLength(1));
      final (tool, args) = runner.calls.single;
      expect(tool, MediaTool.ffmpeg);
      expect(args, containsAllInOrder(['-i', '/work/audio_full.wav']));
      expect(args, containsAllInOrder(['-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le']));
      // O output é o asr_in.wav no MESMO diretório do input — é o arquivo
      // que o pipeline reusa depois pro trim por energia.
      expect(args.last.replaceAll('\\', '/'), '/work/asr_in.wav');
    });

    test('conversion failure surfaces the ffmpeg stderr in the exception', () async {
      final models = ModelManager('/m', _tools, catalog: ModelCatalog.android());
      final runner = _FakeRunner();
      runner.onRun = (_, __) => ToolResult(1, '', 'no audio track');
      final transcriber = AndroidTranscriber(models, Preset.fast, runner);

      await expectLater(
        () => transcriber.transcribe('/work/audio_full.wav', Lang.en, CancellationToken()),
        throwsA(isA<PipelineException>()
            .having((e) => e.message, 'message', contains('no audio track'))),
      );
    });
  });
}
