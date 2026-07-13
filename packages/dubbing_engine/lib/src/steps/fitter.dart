import 'dart:io';
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

    // Deadline do fim do vídeo: o mix final tem a duração do áudio original,
    // então tudo que passar daqui o ffmpeg corta. Vale acelerar acima do teto
    // normal para não perder o fim da última fala.
    var ceiling = maxTotalSpeed;
    final tailAvail = videoDurationSec - runStart;
    if (tailAvail > 0 && content / speedNeeded > tailAvail) {
      final needed = content / tailAvail;
      if (needed > speedNeeded) {
        speedNeeded = needed;
        ceiling = tailSpeedMax;
      }
    }

    var speed = speedNeeded;
    var clamped = false;
    if (speed > ceiling) {
      speed = ceiling;
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

/// Sintetiza a fala a 1x e a guarda EM DISCO (`seg_<id>_natural.wav`),
/// registrando só a duração no segmento.
///
/// Antes o pipeline acumulava o áudio de TODAS as falas num `List<Float32List>`
/// antes de planejar — a memória crescia com a duração do vídeo. O
/// `planDubSchedule` só precisa das durações, então o áudio pode ir para o
/// disco assim que sai do TTS.
void synthesizeNatural(
  DubbingSegment seg,
  Synthesizer synth,
  String workDir,
) {
  final audio = synth.synthesize(seg.translatedText, speaker: seg.speaker);
  final path = p.join(workDir, 'seg_${seg.id}_natural.wav');
  writeWavPcm16(path, WavData(audio.samples, audio.sampleRate, 1));
  seg.naturalAudioPath = path;
  seg.naturalSampleRate = audio.sampleRate;
  seg.naturalSampleCount = audio.samples.length;
}

/// Materializa o áudio final de um segmento conforme a velocidade planejada e o
/// agenda a partir de [cursorSec] (nunca sobrepondo a fala anterior).
///
/// Lê a síntese a 1x de `seg.naturalAudioPath` (quando o plano não pede
/// aceleração) e termina sempre gravando `seg_<id>_fit.wav` — PCM16 mono
/// 44,1 kHz. Nenhum áudio fica retido no segmento. Retorna o novo cursor.
Future<double> applyPlanToSegment(
  DubbingSegment seg,
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
  final naturalPath = seg.naturalAudioPath;
  if (naturalPath == null) {
    throw PipelineException(PipelineStage.fit,
        'Segmento ${seg.id} não tem áudio natural sintetizado');
  }

  ({Float32List samples, int sampleRate}) audio;
  // Resintetiza quando o plano pede desvio perceptível — para mais (acelerar)
  // ou para menos (esticar tradução curta até o fim da janela).
  if (speed >= minResynthSpeed || speed <= 1 / minResynthSpeed) {
    final naturalDur = seg.naturalDurationSec!;
    final targetDur = naturalDur / speed;
    final sv = clampSpeed(speed);
    audio = synth.synthesize(seg.translatedText, speed: sv, speaker: seg.speaker);
    seg.speedUsed = sv;
    // O VITS não escala a duração exatamente por 1/speed; o resíduo (e o que
    // passar de vitsSpeedMax) é corrigido por atempo.
    final durSec = audio.samples.length / audio.sampleRate;
    final factor = clampAtempo(durSec / targetDur);
    if (factor >= 1.02) {
      final ttsWav = p.join(workDir, 'seg_${seg.id}_tts.wav');
      writeWavPcm16(ttsWav, WavData(audio.samples, audio.sampleRate, 1));
      final atempoWav = p.join(workDir, 'seg_${seg.id}_atempo.wav');
      final r = await exec(tools.ffmpeg, [
        '-y', '-i', ttsWav,
        '-filter:a', 'atempo=${factor.toStringAsFixed(4)}',
        atempoWav,
      ], workingDirectory: workDir, token: token);
      if (r.exitCode != 0) {
        throw PipelineException(PipelineStage.fit,
            'ffmpeg atempo falhou no segmento ${seg.id}: ${r.stderrTail}');
      }
      final fitData = readWav(atempoWav);
      audio = (samples: fitData.samples, sampleRate: fitData.sampleRate);
      seg.atempoUsed = factor;
      _deleteQuietly(ttsWav);
      _deleteQuietly(atempoWav);
    }
  } else {
    // Plano manda tocar ao natural: reusa o que já está no disco.
    final natural = readWav(naturalPath);
    audio = (samples: natural.samples, sampleRate: natural.sampleRate);
  }

  final fitWav = p.join(workDir, 'seg_${seg.id}_fit.wav');
  if (childSpeakers.contains(seg.speaker)) {
    // Voz infantil simulada: sobe o pitch e restaura a duração com atempo
    // inverso (não perturba o agendamento), já saindo a 44,1 kHz num único
    // passe de ffmpeg.
    final tmpWav = p.join(workDir, 'seg_${seg.id}_child.wav');
    writeWavPcm16(tmpWav, WavData(audio.samples, audio.sampleRate, 1));
    final rate = (audio.sampleRate * childVoicePitchFactor).round();
    final tempo = (1 / childVoicePitchFactor).toStringAsFixed(4);
    final r = await exec(tools.ffmpeg, [
      '-y', '-i', tmpWav,
      '-filter:a', 'asetrate=$rate,aresample=44100,atempo=$tempo',
      fitWav,
    ], workingDirectory: workDir, token: token);
    if (r.exitCode != 0) {
      throw PipelineException(PipelineStage.fit,
          'ffmpeg pitch-shift falhou no segmento ${seg.id}: ${r.stderrTail}');
    }
    _deleteQuietly(tmpWav);
  } else if (audio.sampleRate == ttsSampleRate) {
    // 22050 -> 44100 é exatamente 2x: interpola em Dart, sem chamar ffmpeg.
    final writer = WavPcm16Writer.create(fitWav, sampleRate: mixSampleRate);
    try {
      writer.writeFrames(upsample2x(audio.samples));
    } finally {
      writer.finish();
    }
  } else {
    final tmpWav = p.join(workDir, 'seg_${seg.id}_resample.wav');
    writeWavPcm16(tmpWav, WavData(audio.samples, audio.sampleRate, 1));
    final r = await exec(tools.ffmpeg, [
      '-y', '-i', tmpWav,
      '-ar', '44100', fitWav,
    ], workingDirectory: workDir, token: token);
    if (r.exitCode != 0) {
      throw PipelineException(PipelineStage.fit,
          'ffmpeg resample falhou no segmento ${seg.id}: ${r.stderrTail}');
    }
    _deleteQuietly(tmpWav);
  }

  // Valida a saída antes de confiar nela (regra #9) e registra os metadados.
  final fitReader = WavReader.open(fitWav);
  final int fittedFrames;
  try {
    if (fitReader.sampleRate != mixSampleRate || fitReader.channels != 1) {
      throw PipelineException(
          PipelineStage.fit,
          'Segmento ${seg.id}: fitted deveria ser mono ${mixSampleRate}Hz, '
          'veio ${fitReader.channels}ch ${fitReader.sampleRate}Hz');
    }
    fittedFrames = fitReader.frameCount;
  } finally {
    fitReader.close();
  }
  seg.fittedAudioPath = fitWav;
  seg.fittedSampleRate = mixSampleRate;
  seg.fittedSampleCount = fittedFrames;

  // O natural já cumpriu seu papel (planejamento + eventual reuso).
  _deleteQuietly(naturalPath);
  seg.naturalAudioPath = null;

  final segStartSec = seg.start.inMicroseconds / 1e6;
  var placementSec = segStartSec > cursorSec ? segStartSec : cursorSec;
  // Fala contínua: uma lacuna minúscula até o início original viraria uma
  // interrupção artificial no meio da frase — cola no fim da anterior.
  if (cursorSec > 0 && placementSec - cursorSec < seamlessGapSeconds) {
    placementSec = cursorSec;
  }
  seg.placedStart = Duration(microseconds: (placementSec * 1e6).round());
  final finalDurSec = fittedFrames / mixSampleRate;
  final dubEndSec = placementSec + finalDurSec;
  // Quanto a fala dublada passou do fim da janela original. Alimenta o
  // relatório de sincronia e a contagem de estouros no resultado.
  final segEndSec = seg.end.inMicroseconds / 1e6;
  seg.overflow = dubEndSec > segEndSec
      ? Duration(microseconds: ((dubEndSec - segEndSec) * 1e6).round())
      : Duration.zero;
  return dubEndSec;
}

void _deleteQuietly(String path) {
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}