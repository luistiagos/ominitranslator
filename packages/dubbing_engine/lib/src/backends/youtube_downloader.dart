import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/runtime/dubbing_runtime.dart';
import 'package:dubbing_engine/src/steps/youtube.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';

/// Downloader do desktop: yt-dlp como subprocesso. Não existe no Android M1 —
/// lá o [DubbingRuntime.createDownloader] é nulo.
class YoutubeDownloader implements MediaDownloader {
  final Tools tools;

  /// Nulo usa o `runToolWithRetry` do próprio [downloadFromYoutube] (rede
  /// merece retry); os testes injetam um mock.
  final RunToolFn? runToolOverride;

  const YoutubeDownloader(this.tools, {this.runToolOverride});

  @override
  Future<String> download(
      DubbingJobConfig config, String workDir, CancellationToken token) {
    if (!tools.hasYtDlp) {
      throw PipelineException(PipelineStage.download,
          'yt-dlp não encontrado. Baixe yt-dlp.exe e coloque em tools/win/');
    }
    return downloadFromYoutube(
      config.youtubeUrl!,
      workDir,
      tools.ytDlp,
      token,
      runToolOverride: runToolOverride,
      cookiesFromBrowser: config.ytDlpCookiesFromBrowser,
      cookiesFile: config.ytDlpCookiesFile,
    );
  }
}
