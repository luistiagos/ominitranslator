import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dubbing_engine/src/models.dart';

/// Apara janelas de segmentos à fala REAL, por energia.
///
/// O whisper estende os timestamps através dos silêncios (tanto no nível de
/// segmento quanto na distribuição por palavra). Como todo o agendamento da
/// dublagem ancora nessas janelas, elas precisam refletir onde a fala
/// realmente começa e termina.
const _frameMs = 20;
const _hopMs = 10;
const _marginMs = 120;
const _minSpeechMs = 250;
// As âncoras exigem fala SUSTENTADA (alguns frames seguidos): um pico
// isolado de ruído/vazamento de música não deve segurar a borda.
const _sustainFrames = 3;
// Limiar relativo ao pico do próprio segmento (robusto a volumes variados)
// com um piso absoluto (ruído de fundo/artefatos da separação).
const _relativeThreshold = 0.1;
const _absoluteThreshold = 0.01;

List<TranscriptSegment> trimSegmentsToSpeech(
    List<TranscriptSegment> segments, Float32List samples, int sampleRate) {
  return segments.map((seg) {
    final bounds = speechBounds(samples, sampleRate, seg.start, seg.end);
    if (bounds == null) return seg;
    return TranscriptSegment(bounds.$1, bounds.$2, seg.text, speaker: seg.speaker);
  }).toList();
}

/// Idem para as unidades de dublagem já mescladas — janelas longas têm fala
/// sólida para ancorar mesmo quando os timestamps por palavra do whisper
/// são imprecisos.
List<DubbingSegment> trimDubbingSegmentsToSpeech(
    List<DubbingSegment> segments, Float32List samples, int sampleRate) {
  return segments.map((seg) {
    final bounds = speechBounds(samples, sampleRate, seg.start, seg.end);
    if (bounds == null) return seg;
    final trimmed = DubbingSegment(seg.id, bounds.$1, bounds.$2, seg.sourceText,
        speaker: seg.speaker);
    trimmed.translatedText = seg.translatedText;
    return trimmed;
  }).toList();
}

/// Limites (início, fim) da fala sustentada dentro da janela, com margem de
/// [_marginMs], ou null para manter a janela original (curta demais ou sem
/// fala detectável).
(Duration, Duration)? speechBounds(
    Float32List samples, int sampleRate, Duration start, Duration end) {
  final frameLen = sampleRate * _frameMs ~/ 1000;
  final hopLen = sampleRate * _hopMs ~/ 1000;
  final segStart = start.inMicroseconds * sampleRate ~/ 1000000;
  final segEnd =
      math.min(end.inMicroseconds * sampleRate ~/ 1000000, samples.length);
  if (segEnd - segStart < frameLen) return null;

  // RMS por frame dentro da janela.
  final rms = <double>[];
  for (int pos = segStart; pos + frameLen <= segEnd; pos += hopLen) {
    double energy = 0;
    for (int i = pos; i < pos + frameLen; i++) {
      energy += samples[i] * samples[i];
    }
    rms.add(math.sqrt(energy / frameLen));
  }
  if (rms.isEmpty) return null;
  final peak = rms.reduce(math.max);
  final threshold = math.max(_absoluteThreshold, peak * _relativeThreshold);

  int first = -1, last = -1;
  int run = 0;
  for (int f = 0; f < rms.length; f++) {
    if (rms[f] >= threshold) {
      run++;
      if (run >= _sustainFrames) {
        if (first < 0) first = f - _sustainFrames + 1;
        last = f;
      }
    } else {
      run = 0;
    }
  }
  if (first < 0) return null;

  final marginSamples = sampleRate * _marginMs ~/ 1000;
  var newStart = segStart + first * hopLen - marginSamples;
  var newEnd = segStart + last * hopLen + frameLen + marginSamples;
  if (newStart < segStart) newStart = segStart;
  if (newEnd > segEnd) newEnd = segEnd;
  if (newEnd - newStart < sampleRate * _minSpeechMs ~/ 1000) return null;

  return (
    Duration(microseconds: newStart * 1000000 ~/ sampleRate),
    Duration(microseconds: newEnd * 1000000 ~/ sampleRate),
  );
}
