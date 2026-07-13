import 'dart:io';
import 'dart:typed_data';

import 'package:dubbing_engine/src/wav.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Float32List _ramp(int n) {
  final s = Float32List(n);
  for (int i = 0; i < n; i++) {
    s[i] = (i % 200) / 200.0 - 0.5; // determinístico, dentro de [-1,1]
  }
  return s;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('wav_stream_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('WavReader', () {
    test('lê header sem carregar o payload', () {
      final path = p.join(tmp.path, 'a.wav');
      writeWavPcm16(path, WavData(_ramp(4410), 44100, 1));
      final r = WavReader.open(path);
      try {
        expect(r.sampleRate, 44100);
        expect(r.channels, 1);
        expect(r.bitsPerSample, 16);
        expect(r.frameCount, 4410);
        expect(r.durationSeconds, closeTo(0.1, 1e-9));
      } finally {
        r.close();
      }
    });

    test('readFrames devolve exatamente a janela pedida', () {
      final path = p.join(tmp.path, 'b.wav');
      final all = _ramp(1000);
      writeWavPcm16(path, WavData(all, 16000, 1));
      final r = WavReader.open(path);
      try {
        final window = r.readFrames(100, 50);
        expect(window.length, 50);
        for (int i = 0; i < 50; i++) {
          expect(window[i], closeTo(all[100 + i], 1 / 32768));
        }
      } finally {
        r.close();
      }
    });

    test('janela além do fim é recortada, não estoura', () {
      final path = p.join(tmp.path, 'c.wav');
      writeWavPcm16(path, WavData(_ramp(100), 16000, 1));
      final r = WavReader.open(path);
      try {
        expect(r.readFrames(90, 50).length, 10);
        expect(r.readFrames(100, 10).length, 0);
        expect(r.readFrames(999, 10).length, 0);
      } finally {
        r.close();
      }
    });

    test('a janela lida bate com o readWav inteiro', () {
      final path = p.join(tmp.path, 'd.wav');
      writeWavPcm16(path, WavData(_ramp(5000), 22050, 1));
      final full = readWav(path);
      final r = WavReader.open(path);
      try {
        final win = r.readFrames(0, r.frameCount);
        expect(win.length, full.samples.length);
        for (int i = 0; i < win.length; i += 137) {
          expect(win[i], closeTo(full.samples[i], 1e-9));
        }
      } finally {
        r.close();
      }
    });

    test('estéreo: frameCount conta quadros, não amostras', () {
      final path = p.join(tmp.path, 'e.wav');
      writeWavPcm16(path, WavData(_ramp(2000), 44100, 2));
      final r = WavReader.open(path);
      try {
        expect(r.channels, 2);
        expect(r.frameCount, 1000);
        expect(r.readFrames(0, 10).length, 20); // 10 quadros x 2 canais
      } finally {
        r.close();
      }
    });

    test('usar depois de fechado lança', () {
      final path = p.join(tmp.path, 'f.wav');
      writeWavPcm16(path, WavData(_ramp(100), 16000, 1));
      final r = WavReader.open(path)..close();
      expect(() => r.readFrames(0, 10), throwsStateError);
    });
  });

  group('WavPcm16Writer', () {
    test('escreve sequencialmente e o resultado relê igual', () {
      final path = p.join(tmp.path, 'w.wav');
      final samples = _ramp(3000);
      final w = WavPcm16Writer.create(path, sampleRate: 44100);
      w.writeFrames(samples);
      w.finish();

      final back = readWav(path);
      expect(back.sampleRate, 44100);
      expect(back.channels, 1);
      expect(back.samples.length, 3000);
      for (int i = 0; i < 3000; i += 97) {
        expect(back.samples[i], closeTo(samples[i], 1 / 32768));
      }
    });

    test('writeSilence produz zeros e conta os quadros', () {
      final path = p.join(tmp.path, 's.wav');
      final w = WavPcm16Writer.create(path, sampleRate: 8000);
      w.writeSilence(100);
      w.writeFrames(Float32List.fromList([1.0, -1.0]));
      w.writeSilence(50);
      expect(w.framesWritten, 152);
      w.finish();

      final back = readWav(path);
      expect(back.samples.length, 152);
      expect(back.samples.take(100), everyElement(0.0));
      expect(back.samples[100], closeTo(1.0, 1e-3));
      expect(back.samples[101], closeTo(-1.0, 1e-3));
      expect(back.samples.skip(102), everyElement(0.0));
    });

    test('silêncio grande não aloca a lacuna inteira e sai correto', () {
      final path = p.join(tmp.path, 'big.wav');
      final w = WavPcm16Writer.create(path, sampleRate: 44100);
      w.writeSilence(44100 * 5); // 5 s
      w.finish();
      final r = WavReader.open(path);
      try {
        expect(r.frameCount, 44100 * 5);
      } finally {
        r.close();
      }
    });

    test('writeRawFrames copia PCM16 sem passar por float', () {
      final src = p.join(tmp.path, 'src.wav');
      final dst = p.join(tmp.path, 'dst.wav');
      final samples = _ramp(500);
      writeWavPcm16(src, WavData(samples, 44100, 1));

      final r = WavReader.open(src);
      final w = WavPcm16Writer.create(dst, sampleRate: 44100);
      try {
        w.writeRawFrames(r.readRawFrames(0, r.frameCount));
      } finally {
        r.close();
        w.finish();
      }

      // Cópia byte a byte do payload: idêntica, sem erro de arredondamento.
      final a = readWav(src).samples;
      final b = readWav(dst).samples;
      expect(b.length, a.length);
      for (int i = 0; i < a.length; i++) {
        expect(b[i], a[i], reason: 'amostra $i');
      }
    });

    test('só publica o arquivo no finish (o .part não vaza)', () {
      final path = p.join(tmp.path, 'atomic.wav');
      final w = WavPcm16Writer.create(path, sampleRate: 16000);
      w.writeSilence(10);
      expect(File(path).existsSync(), isFalse, reason: 'ainda não publicado');
      expect(File('$path.part').existsSync(), isTrue);
      w.finish();
      expect(File(path).existsSync(), isTrue);
      expect(File('$path.part').existsSync(), isFalse);
    });

    test('abort não deixa nem o arquivo nem o .part', () {
      final path = p.join(tmp.path, 'aborted.wav');
      final w = WavPcm16Writer.create(path, sampleRate: 16000);
      w.writeSilence(10);
      w.abort();
      expect(File(path).existsSync(), isFalse);
      expect(File('$path.part').existsSync(), isFalse);
    });
  });
}
