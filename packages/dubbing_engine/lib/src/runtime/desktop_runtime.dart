import 'package:dubbing_engine/src/backends/piper_synthesizer.dart';
import 'package:dubbing_engine/src/backends/sherpa_diarizer.dart';
import 'package:dubbing_engine/src/backends/sherpa_separator.dart';
import 'package:dubbing_engine/src/backends/translatelocally_translator.dart';
import 'package:dubbing_engine/src/backends/whisper_transcriber.dart';
import 'package:dubbing_engine/src/backends/youtube_downloader.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/runtime/dubbing_runtime.dart';
import 'package:dubbing_engine/src/tools/disk_space.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';

/// Monta o runtime do Windows: executáveis em `tools/win` + sherpa via FFI.
///
/// É o único lugar do engine que conhece os backends concretos do desktop. O
/// Android terá o seu `androidRuntime()` equivalente, e o `pipeline.dart` não
/// precisa saber de nenhum dos dois.
DubbingRuntime desktopRuntime({
  required Tools tools,
  required ModelManager models,
  RunToolFn? runToolOverride,
  int? Function(String path)? freeBytesOverride,
}) {
  final exec = runToolOverride ?? runTool;
  return DubbingRuntime(
    models: models,
    tools: tools,
    runTool: exec,
    freeBytes: freeBytesOverride ?? freeBytesForPath,
    createSeparator: () => SherpaSeparator(tools, models),
    createDiarizer: ({int? speakerCount}) =>
        SherpaDiarizer(models, numClusters: speakerCount),
    createTranscriber: (preset) => WhisperTranscriber(tools, models, preset),
    createTranslator: () => TranslateLocallyTranslator(tools, models),
    createSynthesizer: (targetLang, {voiceModelId, voiceSid = 0}) =>
        PiperSynthesizer(targetLang, models,
            voiceOverride:
                voiceModelId != null ? (voiceModelId, voiceSid) : null),
    createDownloader: () =>
        YoutubeDownloader(tools, runToolOverride: runToolOverride),
  );
}
