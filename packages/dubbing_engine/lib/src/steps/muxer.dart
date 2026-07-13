import 'dart:io';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/runtime/media_tool_runner.dart';

Future<String> buildFinalVideo(
  DubbingJobConfig config,
  String dubbedWav,
  MediaToolRunner media,
  CancellationToken token, {
  String? inputVideoOverride,
}) async {
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
  var r = await media.run(MediaTool.ffmpeg, args, workingDirectory: config.workDir, token: token);
  // Fallback com re-encode para qualquer container de entrada: "-c:v copy"
  // falha quando o codec do vídeo (ex.: VP9 de um WebM) não é aceito no MP4
  // de saída.
  if (r.exitCode != 0) {
    final retryArgs = <String>['-y', '-i', video, '-i', dubbedWav];
    retryArgs.addAll(['-map', '0:v:0', '-map', '1:a:0']);
    if (config.keepOriginalTrack) {
      retryArgs.addAll(['-map', '0:a:0']);
    }
    // libopenh264, não libx264: o ffmpeg distribuído é LGPL
    // (`--disable-libx264`), então o x264 simplesmente não existe no binário e
    // este fallback falhava sempre — justo no caminho que ele deveria salvar
    // (VP9/WebM). O openh264 não aceita `-crf`/`-preset`; a qualidade sai por
    // bitrate.
    retryArgs.addAll([
      '-c:v', 'libopenh264', '-b:v', reencodeVideoBitrate,
      '-c:a', 'aac', '-b:a', aacBitrate,
    ]);
    retryArgs.addAll(['-metadata:s:a:0', 'language=${config.targetLang.iso639_2}']);
    if (config.keepOriginalTrack) {
      retryArgs.addAll(['-metadata:s:a:1', 'language=${config.sourceLang.iso639_2}']);
    }
    retryArgs.addAll(['-disposition:a:0', 'default', outputPath]);
    r = await media.run(MediaTool.ffmpeg, retryArgs, workingDirectory: config.workDir, token: token);
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
