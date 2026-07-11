// Valida o agendamento da dublagem contra um vídeo real, sem ouvir:
// roda transcrição → tradução → síntese → plano e imprime o alinhamento
// de cada fala dublada contra a janela original correspondente.
// Run (CWD = raiz do repo): diag_dub.exe <video> <workDir>

import 'dart:io';
import 'dart:typed_data';
import 'package:dubbing_engine/dubbing_engine.dart';
import 'package:dubbing_engine/src/backends/sherpa_separator.dart';
import 'package:dubbing_engine/src/backends/translatelocally_translator.dart';
import 'package:dubbing_engine/src/backends/whisper_transcriber.dart';
import 'package:dubbing_engine/src/steps/fitter.dart';
import 'package:dubbing_engine/src/steps/segmenter.dart';
import 'package:dubbing_engine/src/steps/speech_trim.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> argv) async {
  final video = argv[0];
  final workDir = argv[1];
  Directory(workDir).createSync(recursive: true);
  final appData = Platform.environment['APPDATA']!;
  final models =
      ModelManager('$appData\\omnitranslator\\models', Tools.locate());
  final tools = Tools.locate();
  final token = CancellationToken();

  // Extrai o áudio e mede a duração como o pipeline faz.
  final audioFull = p.join(workDir, 'audio_full.wav');
  await runTool(tools.ffmpeg, [
    '-y', '-i', video, '-vn', '-ac', '2', '-ar', '44100', '-c:a', 'pcm_s16le',
    audioFull,
  ]);
  final probe = await runTool(tools.ffprobe, [
    '-v', 'error', '-show_entries', 'format=duration',
    '-of', 'default=noprint_wrappers=1:nokey=1', video,
  ]);
  final videoDuration = double.parse(probe.stdout.trim());

  // Como no pipeline real: transcreve os VOCALS separados (sem música o
  // aparador de fala enxerga as janelas reais).
  print('Separando voz da trilha...');
  final sep = await SherpaSeparator(tools, models).separate(audioFull, workDir, token);
  final audioForAsr = sep.ok ? sep.files!.vocalsWav : audioFull;
  print(sep.ok ? 'Vocals separados.' : 'Separação falhou: ${sep.failureReason}');

  print('Transcrevendo...');
  final raw = await WhisperTranscriber(tools, models, Preset.best)
      .transcribe(audioForAsr, Lang.en, token);
  var segments = buildDubbingSegments(raw);
  final asr = readWav(p.join(workDir, 'asr_in.wav'));
  segments = trimDubbingSegmentsToSpeech(segments, asr.samples, asr.sampleRate);
  print('${segments.length} segmentos');

  print('Traduzindo...');
  final translated = await TranslateLocallyTranslator(tools, models).translate(
      [for (final s in segments) s.sourceText], Lang.en, Lang.pt, token);
  for (int i = 0; i < segments.length; i++) {
    segments[i].translatedText =
        translated[i].isNotEmpty ? translated[i] : segments[i].sourceText;
  }

  print('Sintetizando (faber)...');
  final synth =
      PiperSynthesizer(Lang.pt, models, voiceOverride: ('piper-pt-br', 0));
  try {
    final naturals = <({Float32List samples, int sampleRate})>[];
    for (final seg in segments) {
      naturals.add(synth.synthesize(seg.translatedText));
    }
    final plan = planDubSchedule(
      [for (final s in segments) s.start.inMicroseconds / 1e6],
      [for (final s in segments) s.end.inMicroseconds / 1e6],
      [for (final a in naturals) a.samples.length / a.sampleRate],
      videoDuration,
    );
    double cursor = 0;
    print('\n seg | original      | dub           | vel   | Δini  | Δfim  | obs');
    for (int i = 0; i < segments.length; i++) {
      cursor = await applyPlanToSegment(segments[i], naturals[i],
          plan[i].speed, synth, tools, workDir, token,
          cursorSec: cursor);
      final seg = segments[i];
      final oS = seg.start.inMilliseconds / 1000;
      final oE = seg.end.inMilliseconds / 1000;
      final dS = seg.placedStart.inMilliseconds / 1000;
      final dE = dS + seg.fittedAudio!.length / mixSampleRate;
      final flags = <String>[];
      if (plan[i].clamped) flags.add('CLAMP');
      if (dE > oE + pauseSpillSeconds + 0.15) flags.add('INVADE-PAUSA');
      if (dE < oE - 1.0) flags.add('TERMINA-CEDO');
      if (dS - oS > maxDubDriftSeconds + 0.1) flags.add('ATRASADA');
      print(' ${i.toString().padLeft(3)} | '
          '${oS.toStringAsFixed(1).padLeft(5)}-${oE.toStringAsFixed(1).padRight(6)}| '
          '${dS.toStringAsFixed(1).padLeft(5)}-${dE.toStringAsFixed(1).padRight(6)}| '
          '${plan[i].speed.toStringAsFixed(2)}  | '
          '${(dS - oS).toStringAsFixed(1).padLeft(4)}  | '
          '${(dE - oE).toStringAsFixed(1).padLeft(4)}  | ${flags.join(",")}');
    }
    // Pausas reais do original vs. voz dublada dentro delas.
    print('\nPausas reais (>= ${pausePreserveSeconds}s) e invasão da dublagem:');
    for (int i = 0; i + 1 < segments.length; i++) {
      final gapStart = segments[i].end.inMilliseconds / 1000;
      final gapEnd = segments[i + 1].start.inMilliseconds / 1000;
      if (gapEnd - gapStart < pausePreserveSeconds) continue;
      final dubEnd = segments[i].placedStart.inMilliseconds / 1000 +
          segments[i].fittedAudio!.length / mixSampleRate;
      final invasion = (dubEnd - gapStart).clamp(0.0, gapEnd - gapStart);
      print('  ${gapStart.toStringAsFixed(1)}-${gapEnd.toStringAsFixed(1)}s '
          '(${(gapEnd - gapStart).toStringAsFixed(1)}s): '
          'invasão ${invasion.toStringAsFixed(2)}s'
          '${invasion > pauseSpillSeconds + 0.15 ? "  <-- ESTOURO" : ""}');
    }
  } finally {
    synth.dispose();
  }
}
