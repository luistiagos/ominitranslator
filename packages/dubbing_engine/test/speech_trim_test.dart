import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/steps/speech_trim.dart';
import 'package:dubbing_engine/src/wav.dart';
import 'package:path/path.dart' as p;
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
      // Margens assimétricas: 40ms antes (antecipação é perceptível),
      // 120ms depois.
      expect(t.start.inMilliseconds, closeTo(600 - 40, 60));
      expect(t.end.inMilliseconds, closeTo(2800 + 120, 60));
    });

    test('janela justa fica praticamente intacta', () {
      final samples = _silenceWithBurst(3.0, 0.05, 2.95);
      final trimmed = trimSegmentsToSpeech([_seg(0, 3000)], samples, _sr);
      final t = trimmed.single;
      expect(t.start.inMilliseconds, lessThanOrEqualTo(60));
      expect(t.end.inMilliseconds, greaterThanOrEqualTo(2940));
    });

    test('palavra "fantasma" (sem fala) encolhe ao início da janela', () {
      // Timestamps largados no silêncio não podem inflar as lacunas da
      // mesclagem: a janela encolhe para ~300ms no início.
      final samples = Float32List(3 * _sr); // silêncio puro
      final trimmed = trimSegmentsToSpeech([_seg(500, 2500)], samples, _sr);
      expect(trimmed.single.start.inMilliseconds, 500);
      expect(trimmed.single.end.inMilliseconds, 800);
    });

    test('unidade mesclada sem fala detectável mantém a janela', () {
      final samples = Float32List(3 * _sr);
      final seg = DubbingSegment(0, const Duration(milliseconds: 500),
          const Duration(milliseconds: 2500), 'x');
      final trimmed = trimDubbingSegmentsToSpeech([seg], samples, _sr);
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

  group('leitura por janela (sem carregar o WAV inteiro)', () {
    late Directory tmp;
    late String wavPath;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('trim_win_');
      wavPath = p.join(tmp.path, 'asr_in.wav');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('dá exatamente o mesmo resultado que ler o arquivo inteiro', () {
      // Três falas em pontos diferentes de 20 s.
      final samples = Float32List(20 * _sr);
      void burst(double fromSec, double toSec) {
        final s = (fromSec * _sr).round();
        final e = (toSec * _sr).round();
        for (int i = s; i < e; i++) {
          samples[i] = 0.4 * math.sin(2 * math.pi * 150 * i / _sr);
        }
      }

      burst(1.0, 3.0);
      burst(7.5, 9.0);
      burst(15.2, 18.4);
      writeWavPcm16(wavPath, WavData(samples, _sr, 1));

      final segs = [_seg(0, 5000), _seg(6000, 11000), _seg(14000, 20000)];
      final inMemory = trimSegmentsToSpeech(segs, samples, _sr);
      final windowed = trimSegmentsToSpeechFromFile(segs, wavPath);

      expect(windowed.length, inMemory.length);
      for (int i = 0; i < inMemory.length; i++) {
        // Tolerância de 1 ms: o WAV é PCM16, o buffer em memória é float.
        expect(windowed[i].start.inMilliseconds,
            closeTo(inMemory[i].start.inMilliseconds, 1),
            reason: 'início do segmento $i');
        expect(windowed[i].end.inMilliseconds,
            closeTo(inMemory[i].end.inMilliseconds, 1),
            reason: 'fim do segmento $i');
      }
    });

    test('unidades de dublagem: mesmo resultado por janela', () {
      final samples = _silenceWithBurst(8.0, 2.0, 5.0);
      writeWavPcm16(wavPath, WavData(samples, _sr, 1));

      DubbingSegment mk() =>
          DubbingSegment(0, Duration.zero, const Duration(seconds: 8), 'x')
            ..translatedText = 'traduzido';

      final inMemory = trimDubbingSegmentsToSpeech([mk()], samples, _sr).single;
      final windowed = trimDubbingSegmentsToSpeechFromFile([mk()], wavPath).single;

      expect(windowed.start.inMilliseconds,
          closeTo(inMemory.start.inMilliseconds, 1));
      expect(windowed.end.inMilliseconds, closeTo(inMemory.end.inMilliseconds, 1));
      expect(windowed.translatedText, 'traduzido');
    });

    test('segmento fantasma (silêncio) encolhe igual', () {
      writeWavPcm16(wavPath, WavData(Float32List(3 * _sr), _sr, 1));
      final trimmed = trimSegmentsToSpeechFromFile([_seg(500, 2500)], wavPath);
      expect(trimmed.single.start.inMilliseconds, 500);
      expect(trimmed.single.end.inMilliseconds, 800);
    });

    test('janela além do fim do arquivo não estoura', () {
      writeWavPcm16(wavPath, WavData(_silenceWithBurst(2.0, 0.5, 1.5), _sr, 1));
      final trimmed = trimSegmentsToSpeechFromFile([_seg(1000, 9000)], wavPath);
      expect(trimmed, hasLength(1));
      expect(trimmed.single.end.inMilliseconds, lessThanOrEqualTo(2000));
    });
  });
}
