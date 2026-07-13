import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/runtime/disk_space_probe.dart';
import 'package:dubbing_engine/src/runtime/media_tool_runner.dart';

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

  /// ffmpeg/ffprobe (§5.2). O engine pede a FERRAMENTA, não um path: no Android
  /// o ffmpeg é biblioteca in-process, não `.exe`.
  final MediaToolRunner mediaTools;

  /// Espaço livre em disco (§5.4). Assíncrono porque o `StatFs` do Android vem
  /// por MethodChannel.
  final DiskSpaceProbe diskSpace;

  const DubbingRuntime({
    required this.createSeparator,
    this.createDiarizer,
    required this.createTranscriber,
    required this.createTranslator,
    required this.createSynthesizer,
    this.createDownloader,
    required this.models,
    required this.mediaTools,
    required this.diskSpace,
  });
}
