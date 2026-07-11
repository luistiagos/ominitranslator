import 'dart:io';
import 'dart:typed_data';
import 'package:dubbing_engine/src/wav.dart';
import 'package:test/test.dart';

void main() {
  final tempDir = Directory.systemTemp.path;

  group('WAV roundtrip', () {
    test('PCM16 mono roundtrip within tolerance', () {
      final original = Float32List.fromList([0.0, 0.5, -0.5, 1.0, -1.0]);
      final path = '$tempDir\\test_roundtrip.wav';
      writeWavPcm16(path, WavData(original, 44100, 1));
      final read = readWav(path);
      expect(read.sampleRate, 44100);
      expect(read.channels, 1);
      expect(read.samples.length, original.length);
      for (int i = 0; i < original.length; i++) {
        expect((read.samples[i] - original[i]).abs(), lessThan(1 / 32768 + 0.001));
      }
    });

    test('stereo WAV read correctly', () {
      final original = Float32List.fromList([0.1, 0.2, 0.3, 0.4]);
      final path = '$tempDir\\test_stereo.wav';
      writeWavPcm16(path, WavData(original, 44100, 2));
      final read = readWav(path);
      expect(read.channels, 2);
      expect(read.samples.length, 4);
      expect(read.samples[0], closeTo(0.1, 0.001));
      expect(read.samples[1], closeTo(0.2, 0.001));
    });
  });

  group('upsample2x', () {
    test('upsamples correctly with linear interpolation', () {
      final input = Float32List.fromList([1.0, 0.0]);
      final result = upsample2x(input);
      expect(result.length, 4);
      expect(result[0], 1.0);
      expect(result[1], 0.5);
      expect(result[2], 0.0);
      expect(result[3], 0.0);
    });
  });

  group('stereoToMono', () {
    test('converts interleaved stereo to mono', () {
      final stereo = Float32List.fromList([0.2, 0.6, 0.8, 0.4]);
      final mono = stereoToMono(stereo);
      expect(mono.length, 2);
      expect(mono[0], closeTo(0.4, 0.001));
      expect(mono[1], closeTo(0.6, 0.001));
    });
  });

  group('wavDurationSeconds', () {
    test('reads duration from header without loading payload', () {
      final path = '$tempDir\\test_duration.wav';
      // sampleRate baixo simula um áudio "longo" com poucos samples reais.
      writeWavPcm16(path, WavData(Float32List(300 * 100), 100, 1));
      expect(wavDurationSeconds(path), closeTo(300.0, 0.001));
    });

    test('accounts for stereo channel count', () {
      final path = '$tempDir\\test_duration_stereo.wav';
      writeWavPcm16(path, WavData(Float32List(200 * 100 * 2), 100, 2));
      expect(wavDurationSeconds(path), closeTo(200.0, 0.001));
    });

    test('throws on missing data chunk', () {
      final path = '$tempDir\\test_duration_bad.wav';
      File(path).writeAsBytesSync(List.filled(20, 0));
      expect(() => wavDurationSeconds(path), throwsFormatException);
    });
  });
}
