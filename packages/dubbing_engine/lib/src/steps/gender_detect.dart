import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';

/// Detecção de sexo do falante pela frequência fundamental (F0) da voz,
/// via autocorrelação — sem modelos de IA. Vozes masculinas ficam
/// tipicamente em 85–155 Hz e femininas em 165–255 Hz.

const _frameMs = 40;
const _hopMs = 20;
const _minF0Hz = 60.0;
const _maxF0Hz = 350.0;
const _minRms = 0.01;
const _minAutocorrPeak = 0.5;
const _minVoicedFrames = 10;
const _maxSecondsPerSpeaker = 15.0;

/// F0 de um frame de áudio, ou null se o frame não parecer voz sonora
/// (energia baixa ou periodicidade fraca).
double? estimateFrameF0(Float32List frame, int sampleRate) {
  final n = frame.length;
  double energy = 0;
  double mean = 0;
  for (final s in frame) {
    mean += s;
  }
  mean /= n;
  final centered = Float32List(n);
  for (int i = 0; i < n; i++) {
    centered[i] = frame[i] - mean;
    energy += centered[i] * centered[i];
  }
  final rms = math.sqrt(energy / n);
  if (rms < _minRms || energy == 0) return null;

  final minLag = (sampleRate / _maxF0Hz).floor();
  final maxLag = (sampleRate / _minF0Hz).ceil();
  if (maxLag >= n) return null;

  final values = List<double>.filled(maxLag + 1, 0);
  double bestValue = 0;
  for (int lag = minLag; lag <= maxLag; lag++) {
    double sum = 0;
    for (int i = 0; i + lag < n; i++) {
      sum += centered[i] * centered[i + lag];
    }
    final normalized = sum / energy;
    values[lag] = normalized;
    if (normalized > bestValue) {
      bestValue = normalized;
    }
  }
  if (bestValue < _minAutocorrPeak) return null;
  // A autocorrelação tem picos em TODOS os múltiplos do período; o máximo
  // global pode cair num múltiplo (2T, 3T) e dividir o F0 por 2/3 — erro
  // de oitava que troca o sexo detectado. O período fundamental é o MENOR
  // lag com pico comparável ao máximo: acha o primeiro lag no patamar do
  // pico e sobe até o máximo local (o patamar começa no "ombro" do pico).
  for (int lag = minLag; lag <= maxLag; lag++) {
    if (values[lag] >= 0.9 * bestValue) {
      int peak = lag;
      while (peak + 1 <= maxLag && values[peak + 1] > values[peak]) {
        peak++;
      }
      return sampleRate / peak;
    }
  }
  return null;
}

VoiceGender classifyF0(double? medianF0) {
  if (medianF0 == null) return VoiceGender.unknown;
  if (medianF0 < genderMaleMaxHz) return VoiceGender.male;
  if (medianF0 > genderFemaleMinHz) return VoiceGender.female;
  return VoiceGender.unknown;
}

AgeBand classifyAge(double? medianF0) {
  if (medianF0 == null) return AgeBand.unknown;
  if (medianF0 > ageChildMinHz) return AgeBand.child;
  return AgeBand.adult;
}

/// Nomes das classes AudioSet usadas na classificação por audio tagging.
const tagMaleSpeech = 'Male speech, man speaking';
const tagFemaleSpeech = 'Female speech, woman speaking';
const tagChildSpeech = 'Child speech, kid speaking';

/// Decide o perfil do falante a partir das pontuações somadas do audio
/// tagging. A classe vencedora entre masculino/feminino/criança define o
/// perfil; se nenhuma atingir [genderTaggingMinScore], usa [fallback]
/// (classificação por pitch).
SpeakerProfile profileFromTagScores(
  Map<String, double> scores, {
  SpeakerProfile fallback = SpeakerProfile.unknown,
}) {
  final male = scores[tagMaleSpeech] ?? 0;
  final female = scores[tagFemaleSpeech] ?? 0;
  final child = scores[tagChildSpeech] ?? 0;
  final top = [male, female, child].reduce(math.max);
  if (top < genderTaggingMinScore) return fallback;
  if (child == top) return const SpeakerProfile(VoiceGender.unknown, AgeBand.child);
  if (male == top) return const SpeakerProfile(VoiceGender.male, AgeBand.adult);
  return const SpeakerProfile(VoiceGender.female, AgeBand.adult);
}

/// Perfil (sexo + faixa etária) estimado de cada falante a partir dos seus
/// turnos de fala. As chaves do resultado são os ids brutos de cluster de
/// [turns]. Para crianças o sexo fica `unknown` — a distinção M/F por pitch
/// não faz sentido em vozes infantis.
Map<int, SpeakerProfile> detectSpeakerProfiles(
    Float32List samples, int sampleRate, List<SpeakerTurn> turns) {
  final bySpeaker = <int, List<SpeakerTurn>>{};
  for (final turn in turns) {
    bySpeaker.putIfAbsent(turn.speaker, () => []).add(turn);
  }
  final result = <int, SpeakerProfile>{};
  for (final entry in bySpeaker.entries) {
    final medianF0 = _medianF0ForTurns(samples, sampleRate, entry.value);
    final age = classifyAge(medianF0);
    final gender =
        age == AgeBand.child ? VoiceGender.unknown : classifyF0(medianF0);
    result[entry.key] = SpeakerProfile(gender, age);
  }
  return result;
}

double? _medianF0ForTurns(
    Float32List samples, int sampleRate, List<SpeakerTurn> turns) {
  final frameLen = sampleRate * _frameMs ~/ 1000;
  final hopLen = sampleRate * _hopMs ~/ 1000;
  final f0s = <double>[];
  double analyzedSeconds = 0;
  for (final turn in turns) {
    if (analyzedSeconds >= _maxSecondsPerSpeaker) break;
    final start = (turn.start * sampleRate).round();
    final end = math.min((turn.end * sampleRate).round(), samples.length);
    for (int pos = start; pos + frameLen <= end; pos += hopLen) {
      final f0 = estimateFrameF0(
          Float32List.sublistView(samples, pos, pos + frameLen), sampleRate);
      if (f0 != null) f0s.add(f0);
    }
    analyzedSeconds += turn.duration;
  }
  if (f0s.length < _minVoicedFrames) return null;
  f0s.sort();
  return f0s[f0s.length ~/ 2];
}
