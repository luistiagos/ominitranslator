import 'dart:io';
import 'dart:typed_data';
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/runtime/media_tool_runner.dart';
import 'package:dubbing_engine/src/steps/fitter.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:dubbing_engine/src/wav.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Sintetizador fake com duração natural fixa; acelerar reduz a duração
/// proporcionalmente, como no VITS real.
class _FixedSynth implements Synthesizer {
  final double naturalDurSec;
  final List<double> speeds = [];
  _FixedSynth(this.naturalDurSec);
  @override
  ({Float32List samples, int sampleRate}) synthesize(String text,
      {double speed = 1.0, int speaker = 0}) {
    speeds.add(speed);
    return (
      samples: Float32List((naturalDurSec / speed * 22050).round()),
      sampleRate: 22050,
    );
  }

  @override
  void configureSpeakerVoices(Map<int, SpeakerProfile> speakerProfiles) {}
  @override
  void dispose() {}
}

final _tools = Tools(
  ffmpeg: 'ffmpeg',
  ffprobe: 'ffprobe',
  whisperCli: 'whisper-cli',
  translateLocally: 'translateLocally',
  sherpaSourceSeparation: 'sherpa-separation',
);

MediaToolRunner _media([RunToolFn? fn]) =>
    DesktopMediaToolRunner(_tools, runToolOverride: fn);

DubbingSegment _seg(int id, double startSec, double endSec) {
  final s = DubbingSegment(
    id,
    Duration(microseconds: (startSec * 1e6).round()),
    Duration(microseconds: (endSec * 1e6).round()),
    'texto',
  );
  s.translatedText = 'texto traduzido';
  return s;
}

/// Grava a síntese a 1x em disco e aponta o segmento nela — é o que a fase 1
/// do pipeline faz agora (o áudio não fica mais em RAM).
void _giveNatural(DubbingSegment seg, double durSec, String dir) {
  final n = (durSec * 22050).round();
  final path = p.join(dir, 'seg_${seg.id}_natural.wav');
  writeWavPcm16(path, WavData(Float32List(n), 22050, 1));
  seg.naturalAudioPath = path;
  seg.naturalSampleRate = 22050;
  seg.naturalSampleCount = n;
}

void main() {
  group('clampSpeed/clampAtempo', () {
    test('clamps to valid ranges', () {
      expect(clampSpeed(1.2), 1.2);
      expect(clampSpeed(2.0), 1.35);
      expect(clampSpeed(0.8), minTotalSpeed);
      expect(clampAtempo(1.1), 1.1);
      expect(clampAtempo(2.0), 1.25);
      expect(clampAtempo(0.5), 1.0);
    });
  });

  group('planDubSchedule', () {
    test('tradução com a mesma duração da fala toca ao natural', () {
      final plan = planDubSchedule([0, 5, 10], [2, 7, 12], [2, 2, 2], 30);
      expect(plan.map((p) => p.speed), everyElement(1.0));
      expect(plan.map((p) => p.clamped), everyElement(isFalse));
    });

    test('tradução curta é ESTICADA até o fim da janela original', () {
      // 2s de fala dublada numa janela de 3s → não termina cedo: estica
      // (limitado a minTotalSpeed).
      final plan = planDubSchedule([0], [3.0], [2.0], 30);
      expect(plan.single.speed, minTotalSpeed);
    });

    test('run denso recebe velocidade UNIFORME ancorada no fim da fala', () {
      // Silêncios de 0.2s (< pausa real): um run só. 9s de conteúdo numa
      // janela que termina em 5.8s (+0.8 de transbordo) → ~1.36x uniforme.
      final plan = planDubSchedule([0, 2, 4], [1.8, 3.8, 5.8], [3, 3, 3], 30);
      expect(plan[0].speed, closeTo(9 / 6.6, 0.001));
      expect(plan[1].speed, plan[0].speed);
      expect(plan[2].speed, plan[0].speed);
      expect(plan[0].clamped, isFalse);
    });

    test(
        'pausa real é preservada: transbordo limitado e próximo run no horário',
        () {
      // Fala longa (5s de dublagem numa janela de 2s) seguida de pausa de
      // 2s: comprime no teto e o run seguinte começa no tempo original.
      final plan = planDubSchedule([0, 4], [2, 6], [5, 2], 30);
      expect(plan[0].clamped, isTrue);
      expect(plan[0].speed, maxTotalSpeed);
      expect(plan[1].speed, 1.0);
      expect(plan[1].clamped, isFalse);
    });

    test('excesso pequeno é absorvido pelo transbordo sem acelerar', () {
      // 3.2s de conteúdo numa janela de 3.1s: o transbordo de 0.8s absorve
      // sem mudar a velocidade.
      final plan = planDubSchedule([0], [3.1], [3.2], 30);
      expect(plan.single.speed, 1.0);
    });

    test('alongamentos imperceptíveis (>0.95) viram 1.0', () {
      final plan = planDubSchedule([0], [3.1], [3.0], 30);
      expect(plan.single.speed, 1.0);
    });

    test('região impossível é clampada no teto (todas as falas)', () {
      final plan = planDubSchedule(
          [0, 1, 2, 30], [0.9, 1.9, 2.9, 32], [20, 20, 20, 2], 40);
      expect(plan.map((p) => p.clamped), everyElement(isTrue));
      expect(plan.map((p) => p.speed), everyElement(maxTotalSpeed));
    });

    test('última fala acelera acima do teto normal para caber no fim do vídeo',
        () {
      // 12s de dublagem numa janela que termina junto com o vídeo (10s). O
      // transbordo levaria a fala a 10.8s — 800ms além do fim, que o ffmpeg
      // cortaria. O fim do vídeo é prazo duro: acelera para 1.2x e cabe.
      final plan = planDubSchedule([0], [10.0], [12.0], 10.0);
      expect(plan.single.speed, closeTo(1.2, 0.001));
      expect(plan.single.clamped, isFalse);
    });

    test('o teto de emergência não vale quando o vídeo tem folga', () {
      // Mesmo excesso, mas o vídeo continua por mais 20s: o gargalo é a janela
      // da fala, não o fim do vídeo — vale o teto normal, e a fala transborda.
      final plan = planDubSchedule([0], [2.0], [5.0], 30.0);
      expect(plan.single.speed, maxTotalSpeed);
      expect(plan.single.clamped, isTrue);
    });

    test('excesso grande no fim do vídeo para no teto de emergência', () {
      // 20s de dublagem para 10s de vídeo: nem 1.65x resolve. Clampa e o
      // resíduo vira cauda cortada, contada por buildDubTrack.
      final plan = planDubSchedule([0], [10.0], [20.0], 10.0);
      expect(plan.single.speed, tailSpeedMax);
      expect(plan.single.clamped, isTrue);
    });
  });

  group('applyPlanToSegment', () {
    late Directory tempDir;
    setUp(() => tempDir = Directory.systemTemp.createTempSync('fitter_test_'));
    tearDown(() => tempDir.deleteSync(recursive: true));

    test('velocidade 1.0 reusa o áudio natural do disco (sem nova síntese)', () async {
      final synth = _FixedSynth(1.5);
      final seg = _seg(0, 0, 2.0);
      _giveNatural(seg, 1.5, tempDir.path);
      final cursor = await applyPlanToSegment(
          seg, 1.0, synth, _media(), tempDir.path, CancellationToken());
      expect(synth.speeds, isEmpty);
      expect(seg.placedStart, Duration.zero);
      expect(seg.speedUsed, 1.0);
      expect(cursor, closeTo(1.5, 0.01));
    });

    test('o fitted vai para o disco a 44,1 kHz mono, e o natural é apagado', () async {
      final synth = _FixedSynth(1.5);
      final seg = _seg(0, 0, 2.0);
      _giveNatural(seg, 1.5, tempDir.path);
      final naturalPath = seg.naturalAudioPath!;

      await applyPlanToSegment(
          seg, 1.0, synth, _media(), tempDir.path, CancellationToken());

      expect(seg.fittedAudioPath, isNotNull);
      expect(File(seg.fittedAudioPath!).existsSync(), isTrue);
      expect(seg.fittedSampleRate, 44100);
      expect(seg.fittedSampleCount, closeTo(1.5 * 44100, 2));
      final r = WavReader.open(seg.fittedAudioPath!);
      try {
        expect(r.sampleRate, 44100);
        expect(r.channels, 1);
      } finally {
        r.close();
      }
      // Já cumpriu seu papel: não fica ocupando disco no celular.
      expect(File(naturalPath).existsSync(), isFalse);
      expect(seg.naturalAudioPath, isNull);
    });

    test('velocidade dentro do range do VITS não usa ffmpeg', () async {
      final synth = _FixedSynth(3.0);
      final seg = _seg(0, 0, 2.0);
      _giveNatural(seg, 3.0, tempDir.path);
      await applyPlanToSegment(
          seg, 1.2, synth, _media(), tempDir.path, CancellationToken());
      expect(synth.speeds, [1.2]);
      expect(seg.speedUsed, 1.2);
      expect(seg.atempoUsed, 1.0);
    });

    test('acima do VITS o resíduo vai para o atempo', () async {
      final synth = _FixedSynth(3.0);
      final seg = _seg(0, 0, 2.0);
      ffmpegMock(exePath, args,
          {workingDirectory,
          timeout = const Duration(minutes: 30),
          token}) async {
        final fIdx = args.indexOf('-filter:a');
        expect(args[fIdx + 1], contains('atempo'));
        // Grava o WAV com a duração alvo (3.0/1.5 = 2.0s).
        writeWavPcm16(
            args.last, WavData(Float32List((2.0 * 22050).round()), 22050, 1));
        return ToolResult(0, '', '');
      }

      _giveNatural(seg, 3.0, tempDir.path);
      await applyPlanToSegment(
          seg, 1.5, synth, _media(ffmpegMock), tempDir.path, CancellationToken());
      expect(seg.speedUsed, 1.35);
      expect(seg.atempoUsed, closeTo(1.5 / 1.35, 0.01));
    });

    test('velocidade < 1 resintetiza mais lento (estica sem ffmpeg)', () async {
      final synth = _FixedSynth(2.0);
      final seg = _seg(0, 0, 3.0);
      _giveNatural(seg, 2.0, tempDir.path);
      final cursor = await applyPlanToSegment(
          seg, 0.85, synth, _media(), tempDir.path, CancellationToken());
      expect(synth.speeds, [0.85]);
      expect(seg.speedUsed, 0.85);
      expect(seg.atempoUsed, 1.0);
      // 2.0s esticados por 0.85 ≈ 2.35s.
      expect(cursor, closeTo(2.0 / 0.85, 0.02));
    });

    test('lacuna minúscula em fala contínua é colada (sem interrupção)',
        () async {
      final synth = _FixedSynth(1.0);
      // Original: fala anterior terminou (cursor 2.0), próxima começa em
      // 2.2 — 0.2s de lacuna viraria um buraco artificial: cola em 2.0.
      final seg = _seg(1, 2.2, 3.2);
      _giveNatural(seg, 1.0, tempDir.path);
      await applyPlanToSegment(
          seg, 1.0, synth, _media(), tempDir.path, CancellationToken(),
          cursorSec: 2.0);
      expect(seg.placedStart.inMilliseconds, 2000);
    });

    test('pausa real entre falas é mantida (não cola)', () async {
      final synth = _FixedSynth(1.0);
      final seg = _seg(1, 4.0, 5.0);
      _giveNatural(seg, 1.0, tempDir.path);
      await applyPlanToSegment(
          seg, 1.0, synth, _media(), tempDir.path, CancellationToken(),
          cursorSec: 2.0);
      expect(seg.placedStart.inMilliseconds, 4000);
    });

    test('cursor empurra a fala sem sobreposição', () async {
      final synth = _FixedSynth(1.0);
      final seg = _seg(1, 2.0, 3.0);
      _giveNatural(seg, 1.0, tempDir.path);
      final cursor = await applyPlanToSegment(
          seg, 1.0, synth, _media(), tempDir.path, CancellationToken(),
          cursorSec: 3.5);
      expect(seg.placedStart.inMilliseconds, 3500);
      expect(cursor, closeTo(4.5, 0.01));
    });
  });
}
