import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';

typedef SeparatorFactory = Separator Function();
typedef DiarizerFactory = Diarizer Function({int? speakerCount});
typedef TranscriberFactory = Transcriber Function(Preset preset);
typedef TranslatorFactory = Translator Function();
typedef SynthesizerFactory = Synthesizer Function(
  Lang targetLang, {
  String? voiceModelId,
  int voiceSid,
});
typedef DownloaderFactory = MediaDownloader Function();

/// Traz um vídeo remoto para um path local dentro do workdir.
///
/// Existe como contrato para que a AUSÊNCIA dele seja expressável: o Android M1
/// não baixa do YouTube (regra #3 proíbe executáveis), então lá o
/// [DubbingRuntime.createDownloader] é nulo e o pipeline recusa explicitamente
/// um `youtubeUrl`, em vez de o `pipeline.dart` importar um backend concreto.
abstract interface class MediaDownloader {
  Future<String> download(
      DubbingJobConfig config, String workDir, CancellationToken token);
}

/// Tudo que o pipeline precisa do mundo exterior, num objeto só.
///
/// É o ponto de injeção ÚNICO: antes, `runDubbingJob` recebia `tools`, `models`
/// e cinco factories soltas, e ainda instanciava os backends concretos por
/// default — o que amarrava o engine a executáveis do Windows. Agora o desktop
/// e o Android montam cada um o seu runtime, e o pipeline não conhece nenhum
/// backend.
///
/// `models` mora aqui (e não como parâmetro de `runDubbingJob`) porque os
/// backends também precisam dele: duas fontes para o mesmo objeto não garantem
/// que sejam a mesma instância.
class DubbingRuntime {
  final SeparatorFactory createSeparator;

  /// Nulo quando a plataforma não faz diarização (Android M1: voz única).
  final DiarizerFactory? createDiarizer;
  final TranscriberFactory createTranscriber;
  final TranslatorFactory createTranslator;
  final SynthesizerFactory createSynthesizer;

  /// Nulo quando a plataforma não baixa vídeo remoto (Android M1).
  final DownloaderFactory? createDownloader;

  final ModelManager models;

  // --- Transitório ---------------------------------------------------------
  // `tools` e `runTool` só existem enquanto os passos de mídia (demux, fit,
  // mix, mux) recebem paths de executável. Eles somem quando o `MediaToolRunner`
  // da §5.2 entrar; no Android nenhum dos dois faz sentido.
  final Tools tools;
  final RunToolFn runTool;

  /// Vira o `DiskSpaceProbe` assíncrono da §5.4 (o `StatFs` do Android é
  /// MethodChannel, logo async).
  final int? Function(String path) freeBytes;

  const DubbingRuntime({
    required this.createSeparator,
    this.createDiarizer,
    required this.createTranscriber,
    required this.createTranslator,
    required this.createSynthesizer,
    this.createDownloader,
    required this.models,
    required this.tools,
    required this.runTool,
    required this.freeBytes,
  });
}
