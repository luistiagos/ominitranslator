import 'dart:io';
import 'dart:typed_data';
import 'package:dubbing_engine/src/steps/mixer.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:dubbing_engine/src/wav.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ToolResult _okResult() => ToolResult(0, '', '');
ToolResult _failResult() => ToolResult(1, '', 'error');

final _tools = Tools(
  ffmpeg: 'ffmpeg',
  ffprobe: 'ffprobe',
  whisperCli: 'whisper-cli',
  translateLocally: 'translateLocally',
  sherpaSourceSeparation: 'sherpa-separation',
);

/// Cria o `seg_<id>_fit.wav` em disco (44,1 kHz mono) e aponta o segmento nele —
/// é assim que o fitter entrega o áudio agora.
DubbingSegment _fitted(String dir, int id, int frames,
    {required int placedMs, double value = 0.0, int? endMs}) {
  final seg = DubbingSegment(id, Duration(milliseconds: placedMs),
      Duration(milliseconds: endMs ?? placedMs + 500), 'test $id');
  seg.placedStart = Duration(milliseconds: placedMs);
  final path = p.join(dir, 'seg_${id}_fit.wav');
  final samples = Float32List(frames);
  if (value != 0.0) samples.fillRange(0, frames, value);
  writeWavPcm16(path, WavData(samples, 44100, 1));
  seg.fittedAudioPath = path;
  seg.fittedSampleRate = 44100;
  seg.fittedSampleCount = frames;
  return seg;
}

void main() {
  group('buildDubTrack (writer sequencial)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('dubtrack_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('sem falas: só silêncio, com a duração do vídeo', () async {
      final track = await buildDubTrack([], 1.0, tmp.path, CancellationToken());
      final wav = readWav(track.path);
      expect(wav.samples.length, 44100);
      expect(wav.samples, everyElement(0.0));
      expect(track.truncatedTail, Duration.zero);
    });

    test('escreve silêncio na lacuna e a fala no lugar certo', () async {
      // Fala de 0,5 s começando em 0,25 s, num vídeo de 2 s.
      final seg = _fitted(tmp.path, 0, 22050, placedMs: 250, value: 0.5);
      final track = await buildDubTrack([seg], 2.0, tmp.path, CancellationToken());
      final wav = readWav(track.path);

      expect(wav.samples.length, 88200, reason: '2 s a 44,1 kHz');
      expect(wav.samples.take(11025), everyElement(0.0), reason: 'lacuna inicial');
      expect(wav.samples[11025], closeTo(0.5, 1e-3));
      expect(wav.samples[11025 + 22049], closeTo(0.5, 1e-3));
      expect(wav.samples.skip(11025 + 22050), everyElement(0.0),
          reason: 'silêncio até o fim do vídeo');
      expect(track.truncatedTail, Duration.zero);
    });

    test('falas em sequência, cada uma no seu lugar', () async {
      final a = _fitted(tmp.path, 0, 4410, placedMs: 0, value: 0.4);
      final b = _fitted(tmp.path, 1, 4410, placedMs: 500, value: -0.4);
      final track = await buildDubTrack([a, b], 1.0, tmp.path, CancellationToken());
      final wav = readWav(track.path);

      expect(wav.samples[0], closeTo(0.4, 1e-3));
      expect(wav.samples[4410], 0.0, reason: 'lacuna entre as duas');
      expect(wav.samples[22050], closeTo(-0.4, 1e-3));
      expect(wav.samples.length, 44100);
    });

    test('a faixa tem exatamente a duração do vídeo mesmo com fala estourando', () async {
      // Fala de 1 s colocada em 0,9 s, num vídeo de 1 s: passa 900 ms do fim.
      // O ffmpeg cortaria isso de qualquer forma (amix duration=first), então
      // a cauda não é escrita — é MEDIDA.
      final seg = _fitted(tmp.path, 0, 44100, placedMs: 900, value: 0.3);
      final track = await buildDubTrack([seg], 1.0, tmp.path, CancellationToken());
      final wav = readWav(track.path);

      expect(wav.samples.length, 44100);
      expect(track.truncatedTail.inMilliseconds, 900);
    });

    test('fala que termina exatamente no fim do vídeo não conta como cortada', () async {
      final seg = _fitted(tmp.path, 0, 44100, placedMs: 0, endMs: 1000);
      final track = await buildDubTrack([seg], 1.0, tmp.path, CancellationToken());
      expect(track.truncatedTail, Duration.zero);
    });

    test('REJEITA sobreposição — o buffer antigo somava em silêncio', () async {
      final a = _fitted(tmp.path, 0, 44100, placedMs: 0); // 0 a 1 s
      final b = _fitted(tmp.path, 1, 22050, placedMs: 500); // começa em 0,5 s
      await expectLater(
        buildDubTrack([a, b], 2.0, tmp.path, CancellationToken()),
        throwsA(isA<PipelineException>()
            .having((e) => e.stage, 'stage', PipelineStage.mix)
            .having((e) => e.message, 'message', contains('sobrepor'))),
      );
      // E não deixa lixo publicado.
      expect(File(p.join(tmp.path, 'dub_voice.wav')).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'dub_voice.wav.part')).existsSync(), isFalse);
    });

    test('memória não cresce com a duração: 60 s de vídeo sai correto', () async {
      // O buffer antigo alocaria um Float32List de 2.646.000 amostras aqui, e
      // ~635 MB numa hora. O writer sequencial não aloca nada proporcional.
      final seg = _fitted(tmp.path, 0, 44100, placedMs: 30000, value: 0.2);
      final track = await buildDubTrack([seg], 60.0, tmp.path, CancellationToken());
      final r = WavReader.open(track.path);
      try {
        expect(r.frameCount, 44100 * 60);
        expect(r.readFrames(44100 * 30, 1)[0], closeTo(0.2, 1e-3));
        expect(r.readFrames(0, 1)[0], 0.0);
      } finally {
        r.close();
      }
    });

    test('segmentos fora de ordem são escritos na ordem do placedStart', () async {
      final late_ = _fitted(tmp.path, 0, 4410, placedMs: 500, value: 0.6);
      final early = _fitted(tmp.path, 1, 4410, placedMs: 0, value: 0.2);
      final track =
          await buildDubTrack([late_, early], 1.0, tmp.path, CancellationToken());
      final wav = readWav(track.path);
      expect(wav.samples[0], closeTo(0.2, 1e-3));
      expect(wav.samples[22050], closeTo(0.6, 1e-3));
    });
  });

  group('buildFinalMix', () {
    test('voice-over mode succeeds', () async {
      final tempDir = Directory.systemTemp.createTempSync('mix_vo_');
      try {
        final dubbedPath = p.join(tempDir.path, 'dubbed.wav');
        File(dubbedPath).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'audio_full.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));

        final result = await buildFinalMix(true, tempDir.path, _tools, CancellationToken(),
            runToolOverride: (_, __, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async => _okResult());
        expect(result, dubbedPath);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('accompaniment mode succeeds', () async {
      final tempDir = Directory.systemTemp.createTempSync('mix_acc_');
      try {
        final dubbedPath = p.join(tempDir.path, 'dubbed.wav');
        File(dubbedPath).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'accompaniment.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));

        final result = await buildFinalMix(false, tempDir.path, _tools, CancellationToken(),
            runToolOverride: (_, __, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async => _okResult());
        expect(result, dubbedPath);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('voice-over mode throws on ffmpeg failure', () async {
      final tempDir = Directory.systemTemp.createTempSync('mix_vo_fail_');
      try {
        File(p.join(tempDir.path, 'audio_full.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));

        await expectLater(
          buildFinalMix(true, tempDir.path, _tools, CancellationToken(),
              runToolOverride: (_, __, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async => _failResult()),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('accompaniment mode throws on ffmpeg failure', () async {
      final tempDir = Directory.systemTemp.createTempSync('mix_acc_fail_');
      try {
        File(p.join(tempDir.path, 'accompaniment.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));

        await expectLater(
          buildFinalMix(false, tempDir.path, _tools, CancellationToken(),
              runToolOverride: (_, __, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async => _failResult()),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('throws when dubbed.wav is missing after ffmpeg', () async {
      final tempDir = Directory.systemTemp.createTempSync('mix_missing_');
      try {
        File(p.join(tempDir.path, 'audio_full.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(tempDir.path, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));

        await expectLater(
          buildFinalMix(true, tempDir.path, _tools, CancellationToken(),
              runToolOverride: (_, __, {String? workingDirectory, Duration timeout = const Duration(minutes: 30), CancellationToken? token}) async => _okResult()),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
