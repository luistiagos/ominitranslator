import 'dart:io';
import 'dart:typed_data';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:dubbing_engine/src/wav.dart';
import 'package:path/path.dart' as p;

Future<String> buildDubTrack(
  List<DubbingSegment> segments,
  double videoDurationSec,
  String workDir,
  CancellationToken token,
) async {
  // A última fala pode ultrapassar o fim do vídeo por causa do atraso
  // acumulado do agendamento; reserva espaço para não cortá-la.
  var totalSamples = (videoDurationSec * mixSampleRate).round();
  for (final seg in segments) {
    if (seg.fittedAudio == null) continue;
    final end = (seg.placedStart.inMicroseconds / 1000000.0 * mixSampleRate).round() +
        seg.fittedAudio!.length;
    if (end > totalSamples) totalSamples = end;
  }
  final buffer = Float32List(totalSamples);
  for (final seg in segments) {
    if (seg.fittedAudio == null) continue;
    final offset = (seg.placedStart.inMicroseconds / 1000000.0 * mixSampleRate).round();
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
  return dubVoicePath;
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
