import 'dart:io';
import 'dart:typed_data';

enum Lang {
  en(code: 'en', label: 'Inglês', iso639_2: 'eng', isDubTarget: true),
  pt(code: 'pt', label: 'Português', iso639_2: 'por', isDubTarget: true),
  es(code: 'es', label: 'Espanhol', iso639_2: 'spa', isDubTarget: true),
  // Línguas-alvo adicionais (têm voz TTS piper mirrorada no sherpa-onnx).
  de(code: 'de', label: 'Alemão', iso639_2: 'deu', isDubTarget: true),
  fr(code: 'fr', label: 'Francês', iso639_2: 'fra', isDubTarget: true),
  pl(code: 'pl', label: 'Polonês', iso639_2: 'pol', isDubTarget: true),
  cs(code: 'cs', label: 'Tcheco', iso639_2: 'ces', isDubTarget: true),
  // Línguas só-origem: só há modelo de tradução X→en (sem voz TTS), então
  // podem ser dubladas DELAS, mas nunca são idioma-alvo. Búlgaro (bg) tem
  // tradução en<->bg mas NENHUMA voz piper mirrorada no release tts-models
  // do sherpa-onnx (confirmado por HEAD 404 + ausência na documentação
  // oficial) — por isso fica aqui, não junto aos alvos acima.
  bg(code: 'bg', label: 'Búlgaro', iso639_2: 'bul'),
  ca(code: 'ca', label: 'Catalão', iso639_2: 'cat'),
  el(code: 'el', label: 'Grego', iso639_2: 'ell'),
  et(code: 'et', label: 'Estoniano', iso639_2: 'est'),
  hr(code: 'hr', label: 'Croata', iso639_2: 'hrv'),
  sr(code: 'sr', label: 'Sérvio', iso639_2: 'srp'),
  bs(code: 'bs', label: 'Bósnio', iso639_2: 'bos'),
  // 'is' é palavra reservada em Dart — o identificador do enum é 'isl'.
  isl(code: 'is', label: 'Islandês', iso639_2: 'isl'),
  mk(code: 'mk', label: 'Macedônio', iso639_2: 'mkd'),
  mt(code: 'mt', label: 'Maltês', iso639_2: 'mlt'),
  // O whisper reconhece bokmål como 'no', não 'nb'.
  nb(code: 'nb', label: 'Norueguês (Bokmål)', iso639_2: 'nob', whisper: 'no'),
  nn(code: 'nn', label: 'Norueguês (Nynorsk)', iso639_2: 'nno'),
  sl(code: 'sl', label: 'Esloveno', iso639_2: 'slv'),
  sq(code: 'sq', label: 'Albanês', iso639_2: 'sqi'),
  tr(code: 'tr', label: 'Turco', iso639_2: 'tur'),
  uk(code: 'uk', label: 'Ucraniano', iso639_2: 'ukr');

  /// ISO 639-1. Igual a [name] exceto para islandês (o identificador `is`
  /// é palavra reservada em Dart, então o valor do enum é `isl`).
  final String code;

  /// Rótulo em português (BR) para a UI.
  final String label;

  /// Código ISO 639-2/B usado nas tags de idioma do MP4 (muxer).
  final String iso639_2;

  /// true = tem voz TTS e modelo de tradução en→X: pode ser ALVO de
  /// dublagem. Línguas sem voz só podem ser ORIGEM (dublar DELAS).
  final bool isDubTarget;

  final String? _whisperOverride;

  const Lang({
    required this.code,
    required this.label,
    required this.iso639_2,
    this.isDubTarget = false,
    String? whisper,
  }) : _whisperOverride = whisper;

  /// Código de idioma passado ao whisper-cli (flag -l). Igual a [code],
  /// exceto norueguês bokmål (nb), que o whisper reconhece como 'no'.
  String get whisperCode => _whisperOverride ?? code;
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
