import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';

/// As únicas ferramentas de mídia que o engine invoca.
///
/// É um enum, e não um path: o núcleo pede "rode o ffmpeg com estes
/// argumentos", não "execute este arquivo". Quem resolve isso para um `.exe`
/// (desktop) ou para uma sessão FFmpegKit (Android) é o runner.
enum MediaTool { ffmpeg, ffprobe }

/// Executa ffmpeg/ffprobe, seja qual for a plataforma.
///
/// Antes, os passos de mídia recebiam um `Tools` (com paths de `.exe`) e uma
/// `RunToolFn` que chamava `Process.start`. No Android não existe `Process`:
/// o ffmpeg é uma biblioteca in-process. Este contrato é o que permite o
/// `FFmpegKitNextRunner` entrar sem que `demux`, `fitter`, `mixer` ou `muxer`
/// mudem uma linha.
abstract interface class MediaToolRunner {
  Future<ToolResult> run(
    MediaTool tool,
    List<String> args, {
    String? workingDirectory,
    Duration timeout,
    CancellationToken? token,

    /// Progresso 0..1 quando a duração total é conhecida. O desktop ignora;
    /// o FFmpegKit converte as `statistics` da sessão.
    void Function(double progress)? onProgress,
  });
}

/// Desktop: resolve o [MediaTool] para o path em [Tools] e chama o runner de
/// subprocesso de sempre.
class DesktopMediaToolRunner implements MediaToolRunner {
  final Tools tools;
  final RunToolFn _exec;

  DesktopMediaToolRunner(this.tools, {RunToolFn? runToolOverride})
      : _exec = runToolOverride ?? runTool;

  String _pathOf(MediaTool tool) => switch (tool) {
        MediaTool.ffmpeg => tools.ffmpeg,
        MediaTool.ffprobe => tools.ffprobe,
      };

  @override
  Future<ToolResult> run(
    MediaTool tool,
    List<String> args, {
    String? workingDirectory,
    Duration timeout = toolTimeout,
    CancellationToken? token,
    void Function(double progress)? onProgress,
  }) {
    // onProgress não é usado no desktop: o progresso do job vem dos eventos do
    // pipeline, não do parsing do stderr do ffmpeg.
    return _exec(
      _pathOf(tool),
      args,
      workingDirectory: workingDirectory,
      timeout: timeout,
      token: token,
    );
  }
}
