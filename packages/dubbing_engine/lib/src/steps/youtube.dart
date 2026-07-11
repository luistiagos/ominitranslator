import 'dart:io';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:path/path.dart' as p;

Future<String> downloadFromYoutube(
  String url,
  String workDir,
  String ytDlpPath,
  CancellationToken token, {
  RunToolFn? runToolOverride,
  String? cookiesFromBrowser,
  String? cookiesFile,
}) async {
  // Rede: falhas transitórias (429, quedas) são comuns — usa retry.
  final exec = runToolOverride ?? runToolWithRetry;
  // Nome fixo: torna determinístico qual arquivo foi baixado e evita
  // problemas com títulos contendo caracteres inválidos no Windows.
  final outputTemplate = p.join(workDir, 'input.%(ext)s');
  final args = <String>[
    '-f', 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best',
    '-o', outputTemplate,
    '--no-playlist',
    '--merge-output-format', 'mp4',
  ];
  // Cookies de uma sessão logada evitam os bloqueios "Sign in to confirm
  // you're not a bot" / 429 que o YouTube aplica a acessos anônimos.
  // Arquivo tem prioridade: funciona com o navegador aberto, diferente de
  // --cookies-from-browser (que pode falhar com o perfil em uso).
  if (cookiesFile != null && cookiesFile.isNotEmpty) {
    args.addAll(['--cookies', cookiesFile]);
  } else if (cookiesFromBrowser != null && cookiesFromBrowser.isNotEmpty) {
    args.addAll(['--cookies-from-browser', cookiesFromBrowser]);
  }
  args.add(url);

  final r = await exec(ytDlpPath, args,
      workingDirectory: workDir, token: token, timeout: const Duration(minutes: 60));

  if (r.exitCode != 0) {
    if (r.stderrTail.contains('Could not copy') &&
        r.stderrTail.contains('cookie')) {
      throw PipelineException(PipelineStage.download,
          'Não foi possível ler os cookies do navegador (ele está aberto e '
          'bloqueia o acesso). Feche o navegador completamente ou use um '
          'arquivo cookies.txt na tela inicial.');
    }
    throw PipelineException(PipelineStage.download, 'yt-dlp falhou: ${r.stderrTail}');
  }

  // O fallback de formato "best" pode baixar containers que não são MP4
  // (ex.: WebM); o ffmpeg do pipeline lê todos, então qualquer input.* de
  // vídeo serve.
  const videoExtensions = ['.mp4', '.webm', '.mkv', '.mov'];
  for (final ext in videoExtensions) {
    final videoFile = File(p.join(workDir, 'input$ext'));
    if (videoFile.existsSync()) return videoFile.path;
  }
  throw PipelineException(
      PipelineStage.download, 'Nenhum arquivo de vídeo foi baixado');
}
