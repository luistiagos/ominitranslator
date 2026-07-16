import 'package:dubbing_engine/src/backends/android_synthesizer.dart';
import 'package:dubbing_engine/src/backends/android_transcriber.dart';
import 'package:dubbing_engine/src/backends/android_translator.dart';
import 'package:dubbing_engine/src/backends/ffmpeg_kit_next_runner.dart';
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/runtime/disk_space_probe.dart';
import 'package:dubbing_engine/src/runtime/dubbing_runtime.dart';

/// Android M1 é voice-over puro (sem separação de voz/música). `createSeparator`
/// é obrigatório em [DubbingRuntime] (não nullable — ao contrário de
/// `createDiarizer`/`createDownloader`), então precisa de uma implementação
/// real cujo `separate()` devolva `notSupportedOnPlatform`: o pipeline
/// (`pipeline.dart`) chama `runtime.createSeparator()` incondicionalmente e
/// distingue esse motivo específico para emitir um evento informativo, não
/// um warning técnico (§5.9).
class _NoSeparator implements Separator {
  const _NoSeparator();
  @override
  Future<SeparationOutcome> separate(String inputWav, String workDir, CancellationToken token) async {
    return const SeparationOutcome.failure(SeparationFailureReason.notSupportedOnPlatform);
  }
}

/// Monta o runtime do Android: backends in-process via FFI (sherpa/slimt) +
/// FFmpegKitNext via MethodChannel.
///
/// É o único lugar do engine que conhece os backends concretos do Android —
/// espelha `desktop_runtime.dart`. `createSeparator`/`createDiarizer`/
/// `createDownloader` são nulos: Android M1 é voice-over puro, voz única,
/// sem YouTube (regras do marco, §5.1/§5.9 da spec — `SeparationOutcome.
/// notSupportedOnPlatform` já é evento informativo, não warning; sem
/// `createDownloader`, o pipeline recusa `youtubeUrl` explicitamente em vez
/// de importar um backend concreto).
DubbingRuntime androidRuntime({
  required ModelManager models,
  required DiskSpaceProbe diskSpace,
  required FFmpegStartFn ffmpegStart,
  required FFmpegPollFn ffmpegPoll,
  required FFmpegCancelFn ffmpegCancel,
  required FfprobeFn ffprobe,
}) {
  return DubbingRuntime(
    models: models,
    diskSpace: diskSpace,
    mediaTools: FFmpegKitNextRunner(
      start: ffmpegStart,
      poll: ffmpegPoll,
      cancel: ffmpegCancel,
      ffprobe: ffprobe,
    ),
    createSeparator: () => const _NoSeparator(),
    createDiarizer: null,
    createTranscriber: (preset) => AndroidTranscriber(models, preset),
    createTranslator: () => AndroidTranslator(models),
    createSynthesizer: (targetLang, {voiceModelId, voiceSid = 0}) =>
        AndroidSynthesizer(targetLang, models, voiceModelId: voiceModelId, voiceSid: voiceSid),
    createDownloader: null,
  );
}
