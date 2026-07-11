import 'dart:io';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';

Future<String> buildFinalVideo(
  DubbingJobConfig config,
  String dubbedWav,
  Tools tools,
  CancellationToken token, {
  RunToolFn? runToolOverride,
  String? inputVideoOverride,
}) async {
  final exec = runToolOverride ?? runTool;
  final video = inputVideoOverride ?? config.inputVideo;
  final outputPath = config.outputPath;
  final args = <String>['-y', '-i', video, '-i', dubbedWav];
  args.addAll(['-map', '0:v:0', '-map', '1:a:0']);
  if (config.keepOriginalTrack) {
    args.addAll(['-map', '0:a:0']);
  }
  args.addAll(['-c:v', 'copy', '-c:a', 'aac', '-b:a', aacBitrate]);
  args.addAll(['-metadata:s:a:0', 'language=${config.targetLang.iso639_2}']);
  if (config.keepOriginalTrack) {
    args.addAll(['-metadata:s:a:1', 'language=${config.sourceLang.iso639_2}']);
  }
  args.addAll(['-disposition:a:0', 'default', outputPath]);
  var r = await exec(tools.ffmpeg, args, workingDirectory: config.workDir, token: token);
  // Fallback com re-encode para qualquer container de entrada: "-c:v copy"
  // falha quando o codec do vídeo (ex.: VP9 de um WebM) não é aceito no MP4
  // de saída.
  if (r.exitCode != 0) {
    final retryArgs = <String>['-y', '-i', video, '-i', dubbedWav];
    retryArgs.addAll(['-map', '0:v:0', '-map', '1:a:0']);
    if (config.keepOriginalTrack) {
      retryArgs.addAll(['-map', '0:a:0']);
    }
    retryArgs.addAll([
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
      '-c:a', 'aac', '-b:a', aacBitrate,
    ]);
    retryArgs.addAll(['-metadata:s:a:0', 'language=${config.targetLang.iso639_2}']);
    if (config.keepOriginalTrack) {
      retryArgs.addAll(['-metadata:s:a:1', 'language=${config.sourceLang.iso639_2}']);
    }
    retryArgs.addAll(['-disposition:a:0', 'default', outputPath]);
    r = await exec(tools.ffmpeg, retryArgs, workingDirectory: config.workDir, token: token);
    if (r.exitCode != 0) {
      throw PipelineException(PipelineStage.mux,
          'Falha ao gerar vídeo final: ${r.stderrTail}');
    }
  }
  if (!File(outputPath).existsSync()) {
    throw PipelineException(PipelineStage.mux, 'Arquivo de saída não foi gerado');
  }
  return outputPath;
}
