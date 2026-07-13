import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/wav.dart';

/// Apara janelas de segmentos à fala REAL, por energia.
///
/// O whisper estende os timestamps através dos silêncios (tanto no nível de
/// segmento quanto na distribuição por palavra). Como todo o agendamento da
/// dublagem ancora nessas janelas, elas precisam refletir onde a fala
/// realmente começa e termina.
const _frameMs = 20;
const _hopMs = 10;
// Margens assimétricas: começar ANTES da fala original é perceptível
// (boca fechada e voz falando); terminar um pouco depois é natural.
const _startMarginMs = 40;
const _endMarginMs = 120;
const _minSpeechMs = 250;
// As âncoras exigem fala SUSTENTADA (alguns frames seguidos): um pico
// isolado de ruído/vazamento de música não deve segurar a borda.
const _sustainFrames = 3;
// Limiar relativo ao pico do próprio segmento (robusto a volumes variados)
// com um piso absoluto (ruído de fundo/artefatos da separação).
const _relativeThreshold = 0.12;
const _absoluteThreshold = 0.012;

List<TranscriptSegment> trimSegmentsToSpeech(
    List<TranscriptSegment> segments, Float32List samples, int sampleRate) {
  return segments.map((seg) {
    final bounds = speechBounds(samples, sampleRate, seg.start, seg.end);
    if (bounds == null) {
      // Sem fala detectável: janela "fantasma" do whisper (timestamps
      // largados no silêncio). Encolhe ao início para não inflar as
      // lacunas usadas na mesclagem — o texto é preservado e será falado
      // junto com os vizinhos.
      final windowUs = seg.end.inMicroseconds - seg.start.inMicroseconds;
      final keepUs = windowUs < 300000 ? windowUs : 300000;
      return TranscriptSegment(
        seg.start,
        Duration(microseconds: seg.start.inMicroseconds + keepUs),
        seg.text,
        speaker: seg.speaker,
      );
    }
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
/// [_startMarginMs]/[_endMarginMs], ou null para manter a janela (curta ou sem
/// fala detectável).
(Duration, Duration)? speechBounds(
    Float32List samples, int sampleRate, Duration start, Duration end) {
  final segStart = start.inMicroseconds * sampleRate ~/ 1000000;
  final segEnd =
      math.min(end.inMicroseconds * sampleRate ~/ 1000000, samples.length);
  final range = _speechRange(samples, sampleRate, segStart, segEnd);
  if (range == null) return null;
  return (
    Duration(microseconds: range.$1 * 1000000 ~/ sampleRate),
    Duration(microseconds: range.$2 * 1000000 ~/ sampleRate),
  );
}

/// Núcleo: analisa `buf[from..to)` e devolve os índices ABSOLUTOS (no mesmo
/// buffer) da fala sustentada, já com as margens aplicadas.
(int, int)? _speechRange(
    Float32List buf, int sampleRate, int from, int to) {
  final frameLen = sampleRate * _frameMs ~/ 1000;
  final hopLen = sampleRate * _hopMs ~/ 1000;
  if (from < 0) from = 0;
  if (to > buf.length) to = buf.length;
  if (to - from < frameLen) return null;

  // RMS por frame dentro da janela.
  final rms = <double>[];
  for (int pos = from; pos + frameLen <= to; pos += hopLen) {
    double energy = 0;
    for (int i = pos; i < pos + frameLen; i++) {
      energy += buf[i] * buf[i];
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

  var newStart = from + first * hopLen - sampleRate * _startMarginMs ~/ 1000;
  var newEnd = from + last * hopLen + frameLen + sampleRate * _endMarginMs ~/ 1000;
  if (newStart < from) newStart = from;
  if (newEnd > to) newEnd = to;
  if (newEnd - newStart < sampleRate * _minSpeechMs ~/ 1000) return null;

  return (newStart, newEnd);
}

/// Como [speechBounds], mas lendo do WAV só a janela do segmento.
///
/// O `asr_in.wav` de um vídeo de uma hora vira ~230 MB de `Float32List` se lido
/// inteiro — e ele era lido inteiro DUAS vezes por job (aqui e no transcriber).
/// Cada segmento só precisa da sua própria janela.
(Duration, Duration)? speechBoundsFromReader(
    WavReader reader, Duration start, Duration end) {
  final sr = reader.sampleRate;
  final segStart = start.inMicroseconds * sr ~/ 1000000;
  final segEnd = math.min(end.inMicroseconds * sr ~/ 1000000, reader.frameCount);
  if (segEnd <= segStart) return null;

  final window = reader.readFrames(segStart, segEnd - segStart);
  final range = _speechRange(window, sr, 0, window.length);
  if (range == null) return null;
  // Índices vêm relativos à janela: reancora no tempo absoluto do arquivo.
  return (
    Duration(microseconds: (segStart + range.$1) * 1000000 ~/ sr),
    Duration(microseconds: (segStart + range.$2) * 1000000 ~/ sr),
  );
}

/// [trimSegmentsToSpeech] lendo o WAV por janela, sem carregá-lo inteiro.
List<TranscriptSegment> trimSegmentsToSpeechFromFile(
    List<TranscriptSegment> segments, String wavPath) {
  final reader = WavReader.open(wavPath);
  try {
    return segments.map((seg) {
      final bounds = speechBoundsFromReader(reader, seg.start, seg.end);
      if (bounds == null) {
        final windowUs = seg.end.inMicroseconds - seg.start.inMicroseconds;
        final keepUs = windowUs < 300000 ? windowUs : 300000;
        return TranscriptSegment(
          seg.start,
          Duration(microseconds: seg.start.inMicroseconds + keepUs),
          seg.text,
          speaker: seg.speaker,
        );
      }
      return TranscriptSegment(bounds.$1, bounds.$2, seg.text,
          speaker: seg.speaker);
    }).toList();
  } finally {
    reader.close();
  }
}

/// [trimDubbingSegmentsToSpeech] lendo o WAV por janela.
List<DubbingSegment> trimDubbingSegmentsToSpeechFromFile(
    List<DubbingSegment> segments, String wavPath) {
  final reader = WavReader.open(wavPath);
  try {
    return segments.map((seg) {
      final bounds = speechBoundsFromReader(reader, seg.start, seg.end);
      if (bounds == null) return seg;
      final trimmed = DubbingSegment(
          seg.id, bounds.$1, bounds.$2, seg.sourceText,
          speaker: seg.speaker);
      trimmed.translatedText = seg.translatedText;
      return trimmed;
    }).toList();
  } finally {
    reader.close();
  }
}
