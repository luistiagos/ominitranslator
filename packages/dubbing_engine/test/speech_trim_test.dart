import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/steps/speech_trim.dart';
import 'package:test/test.dart';

const _sr = 16000;

TranscriptSegment _seg(int startMs, int endMs) => TranscriptSegment(
    Duration(milliseconds: startMs), Duration(milliseconds: endMs), 'x');

/// [totalSec] de silêncio com um trecho de "fala" (senóide) em
/// [speechStartSec]..[speechEndSec].
Float32List _silenceWithBurst(
    double totalSec, double speechStartSec, double speechEndSec) {
  final samples = Float32List((totalSec * _sr).round());
  final s = (speechStartSec * _sr).round();
  final e = (speechEndSec * _sr).round();
  for (int i = s; i < e; i++) {
    samples[i] = 0.4 * math.sin(2 * math.pi * 150 * i / _sr);
  }
  return samples;
}

void main() {
  group('trimSegmentsToSpeech', () {
    test('apara janela inflada pelo whisper à fala real', () {
      // Janela 0-8s, mas a fala real é 0.6-2.8s (resto silêncio).
      final samples = _silenceWithBurst(8.0, 0.6, 2.8);
      final trimmed = trimSegmentsToSpeech([_seg(0, 8000)], samples, _sr);
      final t = trimmed.single;
      // Início/fim reais ± margem de 120ms.
      expect(t.start.inMilliseconds, closeTo(600 - 120, 60));
      expect(t.end.inMilliseconds, closeTo(2800 + 120, 60));
    });

    test('janela justa fica praticamente intacta', () {
      final samples = _silenceWithBurst(3.0, 0.05, 2.95);
      final trimmed = trimSegmentsToSpeech([_seg(0, 3000)], samples, _sr);
      final t = trimmed.single;
      expect(t.start.inMilliseconds, lessThanOrEqualTo(60));
      expect(t.end.inMilliseconds, greaterThanOrEqualTo(2940));
    });

    test('segmento sem fala detectável mantém a janela original', () {
      final samples = Float32List(3 * _sr); // silêncio puro
      final trimmed = trimSegmentsToSpeech([_seg(500, 2500)], samples, _sr);
      expect(trimmed.single.start.inMilliseconds, 500);
      expect(trimmed.single.end.inMilliseconds, 2500);
    });

    test('preserva o speaker do segmento', () {
      final samples = _silenceWithBurst(4.0, 1.0, 2.0);
      final seg = TranscriptSegment(
          Duration.zero, const Duration(seconds: 4), 'x', speaker: 3);
      final trimmed = trimSegmentsToSpeech([seg], samples, _sr);
      expect(trimmed.single.speaker, 3);
    });
  });
}
