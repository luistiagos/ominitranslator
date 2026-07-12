import 'dart:io';
import 'dart:typed_data';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:dubbing_engine/src/wav.dart';
import 'package:path/path.dart' as p;

/// Monta a faixa de voz dublada com EXATAMENTE a duração do vídeo.
///
/// O mix final usa `amix=duration=first`, e o primeiro input é o áudio original
/// — cuja duração é a do vídeo. Logo, o que passar do fim do vídeo é descartado
/// pelo ffmpeg de qualquer jeito. Estender o buffer aqui só criaria a ilusão de
/// que a cauda foi preservada. O agendamento (`planDubSchedule`) já acelera o
/// último run para caber; o resíduo que ainda assim sobrar é devolvido em
/// [truncatedTail] para ser medido e reportado, nunca cortado em silêncio.
Future<({String path, Duration truncatedTail})> buildDubTrack(
  List<DubbingSegment> segments,
  double videoDurationSec,
  String workDir,
  CancellationToken token,
) async {
  final totalSamples = (videoDurationSec * mixSampleRate).round();
  var overrunSamples = 0;
  final buffer = Float32List(totalSamples);
  for (final seg in segments) {
    if (seg.fittedAudio == null) continue;
    final offset = (seg.placedStart.inMicroseconds / 1000000.0 * mixSampleRate).round();
    final end = offset + seg.fittedAudio!.length;
    if (end - totalSamples > overrunSamples) overrunSamples = end - totalSamples;
    for (int j = 0; j < seg.fittedAudio!.length; j++) {
      final idx = offset + j;
      if (idx < buffer.length) {
        buffer[idx] += seg.fittedAudio![j];
      }
    }
  }
  for (int i = 0; i < buffer.length; i++) {
    if (buffer[i] > 1.0) buffer[i] = 1.0;
    if (buffer[i] < -1.0) buffer[i] = -1.0;
  }
  final dubVoicePath = p.join(workDir, 'dub_voice.wav');
  writeWavPcm16(dubVoicePath, WavData(buffer, mixSampleRate, 1));
  return (
    path: dubVoicePath,
    truncatedTail: Duration(
        microseconds: (overrunSamples / mixSampleRate * 1e6).round()),
  );
}

Future<String> buildFinalMix(
  bool voiceOverMode,
  String workDir,
  Tools tools,
  CancellationToken token, {
  RunToolFn? runToolOverride,
}) async {
  final exec = runToolOverride ?? runTool;
  final dubbedPath = p.join(workDir, 'dubbed.wav');
  if (voiceOverMode) {
    final r = await exec(tools.ffmpeg, [
      '-y',
      '-i', p.join(workDir, 'audio_full.wav'),
      '-i', p.join(workDir, 'dub_voice.wav'),
      '-filter_complex',
      '[0:a][1:a]sidechaincompress=threshold=0.02:ratio=12:attack=20:release=400[bg];'
      '[bg][1:a]amix=inputs=2:duration=first:normalize=0,'
      'loudnorm=I=-16:TP=-1.5:LRA=11[out]',
      '-map', '[out]',
      '-ac', '2',
      '-ar', '44100',
      '-c:a', 'pcm_s16le',
      dubbedPath,
    ], workingDirectory: workDir, token: token);
    if (r.exitCode != 0) {
      throw PipelineException(PipelineStage.mix, 'Mixagem com ducking falhou');
    }
  } else {
    final r = await exec(tools.ffmpeg, [
      '-y',
      '-i', p.join(workDir, 'accompaniment.wav'),
      '-i', p.join(workDir, 'dub_voice.wav'),
      '-filter_complex',
      '[0:a][1:a]amix=inputs=2:duration=first:normalize=0,'
      'loudnorm=I=-16:TP=-1.5:LRA=11[out]',
      '-map', '[out]',
      '-ac', '2',
      '-ar', '44100',
      '-c:a', 'pcm_s16le',
      dubbedPath,
    ], workingDirectory: workDir, token: token);
    if (r.exitCode != 0) {
      throw PipelineException(PipelineStage.mix, 'Mixagem falhou');
    }
  }
  if (!File(dubbedPath).existsSync()) {
    throw PipelineException(PipelineStage.mix, 'dubbed.wav não foi gerado');
  }
  return dubbedPath;
}
