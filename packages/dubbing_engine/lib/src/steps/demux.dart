import 'dart:io';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/runtime/media_tool_runner.dart';
import 'package:path/path.dart' as p;

Future<double> runDemux(
  DubbingJobConfig config,
  MediaToolRunner media,
  CancellationToken token, {
  String? inputVideoOverride,
}) async {
  final video = inputVideoOverride ?? config.inputVideo;
  final videoDuration = await _getDuration(video, media, token);
  final audioOut = p.join(config.workDir, 'audio_full.wav');
  final r2 = await media.run(MediaTool.ffmpeg, [
    '-y', '-i', video,
    '-vn', '-ac', '2', '-ar', '44100', '-c:a', 'pcm_s16le',
    audioOut,
  ], workingDirectory: config.workDir, token: token);
  if (r2.exitCode != 0) {
    throw PipelineException(PipelineStage.demux,
        'Falha ao extrair o áudio do vídeo (o arquivo pode não ter faixa de áudio). '
        'Detalhes: ${r2.stderrTail}');
  }
  if (!File(audioOut).existsSync() || File(audioOut).lengthSync() <= 44) {
    throw PipelineException(PipelineStage.demux, 'Arquivo de áudio extraído está vazio ou inválido');
  }
  return videoDuration;
}

Future<double> _getDuration(
  String inputVideo,
  MediaToolRunner media,
  CancellationToken token,
) async {
  final r = await media.run(MediaTool.ffprobe, [
    '-v', 'error',
    '-show_entries', 'format=duration',
    '-of', 'default=noprint_wrappers=1:nokey=1',
    inputVideo,
  ], token: token);
  if (r.exitCode != 0) {
    throw PipelineException(PipelineStage.demux, 'ffprobe não conseguiu ler a duração do vídeo');
  }
  final trimmed = r.stdout.trim();
  final duration = double.tryParse(trimmed);
  if (duration == null) {
    throw PipelineException(PipelineStage.demux,
        'ffprobe retornou duração inválida ("$trimmed") para o vídeo');
  }
  return duration;
}
