import 'dart:typed_data';
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:dubbing_engine/src/wav.dart';
import 'package:path/path.dart' as p;

double clampSpeed(double speed) {
  if (speed < minTotalSpeed) return minTotalSpeed;
  if (speed > vitsSpeedMax) return vitsSpeedMax;
  return speed;
}

double clampAtempo(double factor) {
  if (factor < 1.0) return 1.0;
  if (factor > atempoMax) return atempoMax;
  return factor;
}

/// Velocidade planejada para uma fala. [clamped] indica que nem o teto de
/// velocidade resolveu — a fala vai atrasar além do orçamento.
typedef DubPlanItem = ({double speed, bool clamped});

/// Planeja o ritmo de TODAS as falas com antecipação, ancorado na JANELA
/// original de cada fala (início E fim), por "runs" de fala contínua:
///
/// - Um run é uma sequência de falas cujos silêncios entre elas são menores
///   que [pausePreserveSeconds]; silêncios maiores são pausas reais do
///   vídeo (respiração, troca de cena) e permanecem em silêncio — a
///   dublagem pode invadi-los em no máximo [pauseSpillSeconds].
/// - Cada run recebe UMA velocidade uniforme que faz o conteúdo dublado
///   terminar junto com o FIM da fala original do run (não no início da
///   próxima): tradução longa acelera (até [maxTotalSpeed]), tradução
///   curta DESACELERA (até [minTotalSpeed]) — sem buracos no meio da fala
///   do personagem nem voz varrendo as pausas.
/// - Dentro do run, nenhuma fala pode começar mais que
///   [maxDubDriftSeconds] depois do seu tempo original.
List<DubPlanItem> planDubSchedule(
  List<double> startsSec,
  List<double> endsSec,
  List<double> naturalDursSec,
  double videoDurationSec,
) {
  final n = startsSec.length;
  final items = List<DubPlanItem>.filled(n, (speed: 1.0, clamped: false));
  final minTargetSec = minTarget.inMicroseconds / 1e6;
  double cursor = 0;
  int i = 0;
  while (i < n) {
    // Run: falas contíguas separadas por silêncios < pausePreserveSeconds.
    int j = i;
    double content = naturalDursSec[i];
    while (j + 1 < n && startsSec[j + 1] - endsSec[j] < pausePreserveSeconds) {
      j++;
      content += naturalDursSec[j];
    }

    final runStart = startsSec[i] > cursor ? startsSec[i] : cursor;
    // Âncora: o fim da fala original do run. Tradução curta estica até lá;
    // tradução longa pode invadir a pausa seguinte em até
    // pauseSpillSeconds (nunca até o início do próximo run).
    var windowAvail = endsSec[j] - runStart;
    if (windowAvail < minTargetSec) windowAvail = minTargetSec;
    double speedNeeded;
    if (content <= windowAvail) {
      speedNeeded = content / windowAvail;
    } else {
      var availWithSpill = windowAvail + pauseSpillSeconds;
      if (j + 1 < n && availWithSpill > startsSec[j + 1] - runStart) {
        availWithSpill = startsSec[j + 1] - runStart;
      }
      if (availWithSpill < minTargetSec) availWithSpill = minTargetSec;
      speedNeeded = content / availWithSpill;
      // O transbordo absorve o excesso sem acelerar nem esticar.
      if (speedNeeded < 1.0) speedNeeded = 1.0;
    }
    // Deadlines internos: o atraso não cresce sem limite dentro do run.
    double cum = 0;
    for (int k = i; k <= j; k++) {
      if (k > i) {
        final deadline = startsSec[k] + maxDubDriftSeconds - runStart;
        if (deadline <= 0) {
          speedNeeded = maxTotalSpeed + 1; // impossível: será clampado
        } else {
          final needed = cum / deadline;
          if (needed > speedNeeded) speedNeeded = needed;
        }
      }
      cum += naturalDursSec[k];
    }

    var speed = speedNeeded;
    var clamped = false;
    if (speed > maxTotalSpeed) {
      speed = maxTotalSpeed;
      clamped = true;
    }
    if (speed < minTotalSpeed) speed = minTotalSpeed;
    // Desvios imperceptíveis não valem nova síntese.
    if (speed < minResynthSpeed && speed > 1 / minResynthSpeed) speed = 1.0;
    for (int k = i; k <= j; k++) {
      items[k] = (speed: speed, clamped: clamped);
    }
    cursor = runStart + content / speed;
    i = j + 1;
  }
  return items;
}

/// Materializa o áudio final de um segmento conforme a velocidade planejada
/// e o agenda a partir de [cursorSec] (nunca sobrepondo a fala anterior).
/// [naturalAudio] é a síntese a 1x já feita na fase anterior — reusada
/// quando o plano não pede aceleração. Retorna o novo cursor.
Future<double> applyPlanToSegment(
  DubbingSegment seg,
  ({Float32List samples, int sampleRate}) naturalAudio,
  double speed,
  Synthesizer synth,
  Tools tools,
  String workDir,
  CancellationToken token, {
  RunToolFn? runToolOverride,
  Set<int> childSpeakers = const {},
  double cursorSec = 0,
}) async {
  final exec = runToolOverride ?? runTool;
  var audio = naturalAudio;
  // Resintetiza quando o plano pede desvio perceptível — para mais
  // (acelerar) ou para menos (esticar tradução curta até o fim da janela).
  if (speed >= minResynthSpeed || speed <= 1 / minResynthSpeed) {
    final naturalDur = naturalAudio.samples.length / naturalAudio.sampleRate;
    final targetDur = naturalDur / speed;
    final sv = clampSpeed(speed);
    audio = synth.synthesize(seg.translatedText, speed: sv, speaker: seg.speaker);
    seg.speedUsed = sv;
    // O VITS não escala a duração exatamente por 1/speed; o resíduo (e o
    // que passar de vitsSpeedMax) é corrigido por atempo.
    var durSec = audio.samples.length / audio.sampleRate;
    final factor = clampAtempo(durSec / targetDur);
    if (factor >= 1.02) {
      final ttsWav = p.join(workDir, 'seg_${seg.id}_tts.wav');
      writeWavPcm16(ttsWav, WavData(audio.samples, audio.sampleRate, 1));
      final fitWav = p.join(workDir, 'seg_${seg.id}_fit.wav');
      final r = await exec(tools.ffmpeg, [
        '-y', '-i', ttsWav,
        '-filter:a', 'atempo=${factor.toStringAsFixed(4)}',
        fitWav,
      ], workingDirectory: workDir, token: token);
      if (r.exitCode != 0) {
        throw PipelineException(PipelineStage.fit,
            'ffmpeg atempo falhou no segmento ${seg.id}: ${r.stderrTail}');
      }
      final fitData = readWav(fitWav);
      audio = (samples: fitData.samples, sampleRate: fitData.sampleRate);
      seg.atempoUsed = factor;
    }
  }

  if (childSpeakers.contains(seg.speaker)) {
    // Voz infantil simulada: sobe o pitch e restaura a duração com atempo
    // inverso (não perturba o agendamento), já saindo a 44,1 kHz num único
    // passe de ffmpeg.
    final tmpWav = p.join(workDir, 'seg_${seg.id}_child.wav');
    writeWavPcm16(tmpWav, WavData(audio.samples, audio.sampleRate, 1));
    final shifted = p.join(workDir, 'seg_${seg.id}_childshift.wav');
    final rate = (audio.sampleRate * childVoicePitchFactor).round();
    final tempo = (1 / childVoicePitchFactor).toStringAsFixed(4);
    final r = await exec(tools.ffmpeg, [
      '-y', '-i', tmpWav,
      '-filter:a', 'asetrate=$rate,aresample=44100,atempo=$tempo',
      shifted,
    ], workingDirectory: workDir, token: token);
    if (r.exitCode != 0) {
      throw PipelineException(PipelineStage.fit,
          'ffmpeg pitch-shift falhou no segmento ${seg.id}: ${r.stderrTail}');
    }
    seg.fittedAudio = readWav(shifted).samples;
  } else if (audio.sampleRate == ttsSampleRate) {
    seg.fittedAudio = upsample2x(audio.samples);
  } else {
    final tmpWav = p.join(workDir, 'seg_${seg.id}_resample.wav');
    writeWavPcm16(tmpWav, WavData(audio.samples, audio.sampleRate, 1));
    final resampled = p.join(workDir, 'seg_${seg.id}_resampled.wav');
    final r = await exec(tools.ffmpeg, [
      '-y', '-i', tmpWav,
      '-ar', '44100', resampled,
    ], workingDirectory: workDir, token: token);
    if (r.exitCode != 0) {
      throw PipelineException(PipelineStage.fit,
          'ffmpeg resample falhou no segmento ${seg.id}: ${r.stderrTail}');
    }
    final rd = readWav(resampled);
    seg.fittedAudio = rd.samples;
  }

  final segStartSec = seg.start.inMicroseconds / 1e6;
  var placementSec = segStartSec > cursorSec ? segStartSec : cursorSec;
  // Fala contínua: uma lacuna minúscula até o início original viraria uma
  // interrupção artificial no meio da frase — cola no fim da anterior.
  if (cursorSec > 0 && placementSec - cursorSec < seamlessGapSeconds) {
    placementSec = cursorSec;
  }
  seg.placedStart = Duration(microseconds: (placementSec * 1e6).round());
  final finalDurSec = seg.fittedAudio!.length / mixSampleRate;
  return placementSec + finalDurSec;
}