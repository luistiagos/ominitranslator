import 'dart:io';
import 'dart:typed_data';

enum Lang { en, pt, es }

extension LangCodes on Lang {
  String get whisperCode => name;
  String get iso639_2 => switch (this) {
    Lang.en => 'eng',
    Lang.pt => 'por',
    Lang.es => 'spa',
  };
}

enum Preset { fast, best }

/// Sexo estimado de um falante (pelo pitch) ou de uma voz TTS (curadoria).
enum VoiceGender { male, female, unknown }

/// Faixa etária estimada de um falante pelo pitch. Apenas criança vs.
/// adulto: idoso não é distinguível por pitch e não há voz TTS idosa.
enum AgeBand { child, adult, unknown }

class TranscriptSegment {
  final Duration start;
  final Duration end;
  final String text;

  /// Índice do falante atribuído por diarização (0 = falante principal).
  final int speaker;
  TranscriptSegment(this.start, this.end, this.text, {this.speaker = 0});
}

class DubbingSegment {
  final int id;
  final Duration start;
  final Duration end;
  final String sourceText;
  String translatedText = '';
  Float32List? fittedAudio;
  double speedUsed = 1.0;
  double atempoUsed = 1.0;
  Duration overflow = Duration.zero;
  int speaker = 0;

  /// Instante em que a fala dublada realmente entra na trilha. Igual a
  /// [start] quando não há atraso acumulado; nunca sobrepõe a fala anterior.
  Duration placedStart;
  DubbingSegment(this.id, this.start, this.end, this.sourceText, {this.speaker = 0})
      : placedStart = start;
}

class DubbingJobConfig {
  final String inputVideo;
  final Lang sourceLang;
  final Lang targetLang;
  final Preset preset;
  final bool keepOriginalTrack;
  final bool generateSrt;
  final String workDir;
  final String outputPath;
  final String? youtubeUrl;

  /// Nome do navegador (ex.: "chrome", "edge", "firefox") de onde o yt-dlp
  /// deve extrair cookies de sessão, para vídeos que exigem login/anti-bot.
  /// Mutuamente exclusivo com [ytDlpCookiesFile].
  final String? ytDlpCookiesFromBrowser;

  /// Caminho para um arquivo cookies.txt exportado do navegador, como
  /// alternativa a [ytDlpCookiesFromBrowser] (não exige fechar o navegador).
  final String? ytDlpCookiesFile;

  /// Número de falantes do vídeo, quando o usuário o conhece. O próprio
  /// sherpa-onnx recomenda fortemente informá-lo: o clustering vira
  /// determinístico. null = detecção automática por threshold.
  final int? speakerCount;

  /// Voz fixa escolhida pelo usuário (id do modelo no manifest + sid).
  /// Quando definida, toda a dublagem usa essa voz e a detecção de
  /// falantes é ignorada. null = escolha automática por falante.
  final String? voiceModelId;
  final int voiceSid;
  const DubbingJobConfig({
    required this.inputVideo,
    required this.sourceLang,
    required this.targetLang,
    required this.preset,
    this.keepOriginalTrack = true,
    this.generateSrt = true,
    required this.workDir,
    required this.outputPath,
    this.youtubeUrl,
    this.ytDlpCookiesFromBrowser,
    this.ytDlpCookiesFile,
    this.speakerCount,
    this.voiceModelId,
    this.voiceSid = 0,
  });
}

enum PipelineStage { prepare, download, demux, separate, diarize, transcribe, segment, translate, synthesize, fit, mix, mux }

class PipelineEvent {
  final PipelineStage stage;
  final double progress;
  final String message;
  final bool isWarning;
  const PipelineEvent(this.stage, this.progress, this.message,
      {this.isWarning = false});
}

class PipelineException implements Exception {
  final PipelineStage stage;
  final String message;
  final Object? cause;
  PipelineException(this.stage, this.message, [this.cause]);

  @override
  String toString() => 'Erro na etapa ${stage.name}: $message';
}

class CancellationToken {
  bool _cancelled = false;
  final List<Process> _processes = [];
  bool get isCancelled => _cancelled;
  void cancel() {
    _cancelled = true;
    for (final p in _processes) {
      p.kill();
    }
  }
  void addProcess(Process p) {
    _processes.add(p);
  }
}

class DubbingResult {
  final String outputVideo;
  final String? srtSource;
  final String? srtTarget;

  /// Cópia do vídeo original baixado do YouTube, salva na mesma pasta do
  /// vídeo dublado (null para vídeos locais).
  final String? originalVideo;
  final bool voiceOverMode;
  final int segmentsWithOverflow;
  final Duration elapsed;
  const DubbingResult({
    required this.outputVideo,
    this.srtSource,
    this.srtTarget,
    this.originalVideo,
    required this.voiceOverMode,
    required this.segmentsWithOverflow,
    required this.elapsed,
  });
}
