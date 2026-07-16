import 'dart:typed_data';
import 'package:dubbing_engine/src/models.dart';

/// Por que a separação de voz não foi feita. A UI deriva o texto do usuário
/// deste código; o [SeparationOutcome.detail] é diagnóstico e nunca vai para a
/// tela. `notSupportedOnPlatform` é o caso do Android M1 — comportamento
/// esperado, não erro.
enum SeparationFailureReason {
  notSupportedOnPlatform,
  modelNotReady,
  cancelled,
  toolFailed,
  unsupportedAudio,
}

/// Resultado da separação de voz: sucesso com os arquivos gerados, ou falha
/// com um [reason] tipado (para a UI) e um [detail] livre (só diagnóstico).
class SeparationOutcome {
  final ({String vocalsWav, String accompanimentWav})? files;
  final SeparationFailureReason? reason;
  final String? detail;
  const SeparationOutcome.success(
      ({String vocalsWav, String accompanimentWav}) this.files)
      : reason = null,
        detail = null;
  const SeparationOutcome.failure(SeparationFailureReason this.reason,
      {this.detail})
      : files = null;
  bool get ok => files != null;

  /// O modo voice-over do Android M1 é esperado; qualquer outra falha é técnica.
  bool get isExpected => reason == SeparationFailureReason.notSupportedOnPlatform;
}

abstract class Separator {
  Future<SeparationOutcome> separate(
      String inputWav, String workDir, CancellationToken token);
}

abstract class Transcriber {
  Future<List<TranscriptSegment>> transcribe(
      String wav16kMono, Lang sourceLang, CancellationToken token);
}

/// Trecho contínuo de fala de um único falante, em segundos.
class SpeakerTurn {
  final double start;
  final double end;
  final int speaker;
  const SpeakerTurn(this.start, this.end, this.speaker);
  double get duration => end - start;
}

/// Sexo e faixa etária estimados de um falante (pelo pitch).
class SpeakerProfile {
  final VoiceGender gender;
  final AgeBand age;
  const SpeakerProfile(this.gender, this.age);

  static const unknown = SpeakerProfile(VoiceGender.unknown, AgeBand.unknown);

  @override
  bool operator ==(Object other) =>
      other is SpeakerProfile && other.gender == gender && other.age == age;

  @override
  int get hashCode => Object.hash(gender, age);

  @override
  String toString() => 'SpeakerProfile(${gender.name}, ${age.name})';
}

/// Resultado da diarização: turnos de fala e perfil estimado por falante
/// (chaves = ids brutos de cluster, os mesmos de [turns]).
class DiarizationResult {
  final List<SpeakerTurn> turns;
  final Map<int, SpeakerProfile> profiles;
  const DiarizationResult(this.turns, this.profiles);
}

abstract class Diarizer {
  /// Detecta "quem fala quando" (e o sexo de cada falante) em
  /// [wav16kMonoPath] (WAV 16 kHz mono).
  Future<DiarizationResult> diarize(String wav16kMonoPath, CancellationToken token);
}

abstract class Translator {
  Future<List<String>> translate(
      List<String> sentences, Lang from, Lang to, CancellationToken token);

  /// Libera recursos do backend ao fim do job. No-op no desktop (subprocesso
  /// sem estado retido); obrigatório no Android, onde o slimt mantém handles
  /// nativos (~17 MB por par de idiomas) que sobreviveriam ao job num
  /// serviço de longa vida. O pipeline chama em `try/finally`, como já faz
  /// com [Synthesizer.dispose].
  void dispose() {}
}

abstract class Synthesizer {
  /// Sintetiza [text]. [speaker] é o índice do falante da dublagem; cada
  /// implementação mapeia falantes para as vozes de que dispõe.
  ({Float32List samples, int sampleRate}) synthesize(String text,
      {double speed = 1.0, int speaker = 0});

  /// Informa o perfil estimado (sexo/idade) de cada falante, com índices
  /// renumerados, para a escolha das vozes. Implementações sem vozes por
  /// perfil podem ignorar.
  void configureSpeakerVoices(Map<int, SpeakerProfile> speakerProfiles) {}

  void dispose();
}
