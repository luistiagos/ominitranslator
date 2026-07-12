import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/retry.dart';

typedef RunToolFn = Future<ToolResult> Function(
  String exePath,
  List<String> args, {
  String? workingDirectory,
  Duration timeout,
  CancellationToken? token,
});

class ToolResult {
  final int exitCode;
  final String stdout;
  final String stderrTail;
  final bool timedOut;
  ToolResult(this.exitCode, this.stdout, this.stderrTail, {this.timedOut = false});
}

/// Executa [exePath] uma única vez. Falhas de ferramentas locais (ffmpeg,
/// whisper, sherpa...) são quase sempre determinísticas — arquivo inválido,
/// vídeo sem áudio, modelo corrompido — então retentar só atrasaria o
/// reporte do erro. Para operações de rede, use [runToolWithRetry].
Future<ToolResult> runTool(
  String exePath,
  List<String> args, {
  String? workingDirectory,
  Duration timeout = const Duration(minutes: 30),
  CancellationToken? token,
}) {
  return _runToolOnce(exePath, args,
      workingDirectory: workingDirectory, timeout: timeout, token: token);
}

/// Executa [exePath] com retry automático em caso de falha (código de saída
/// != 0): a execução original mais até [maxAttempts] - 1 novas tentativas,
/// com atraso exponencial entre elas. Destinado a ferramentas que dependem
/// de rede (yt-dlp, translateLocally -d), onde falhas transitórias como
/// rate limit/quedas de conexão são comuns. Não repete depois de um
/// cancelamento do usuário, nem depois de um timeout (evitaria multiplicar
/// uma espera já longa por até 6x).
Future<ToolResult> runToolWithRetry(
  String exePath,
  List<String> args, {
  String? workingDirectory,
  Duration timeout = const Duration(minutes: 30),
  CancellationToken? token,
  int maxAttempts = defaultMaxAttempts,
  Duration Function(int attempt) retryDelay = defaultRetryDelay,
}) async {
  int attempts = 0;
  final result = await retryAsync<ToolResult>(
    () {
      attempts++;
      return _runToolOnce(exePath, args,
          workingDirectory: workingDirectory, timeout: timeout, token: token);
    },
    isSuccess: (r) => r.exitCode == 0,
    isFatal: (r) => r.timedOut,
    isCancelled: () => token?.isCancelled ?? false,
    maxAttempts: maxAttempts,
    retryDelay: retryDelay,
  );
  if (result.exitCode != 0 && attempts > 1) {
    return ToolResult(
      result.exitCode,
      result.stdout,
      'Falhou após $attempts tentativas.\n${result.stderrTail}',
      timedOut: result.timedOut,
    );
  }
  return result;
}

/// Como [RunToolFn], mas envia [stdinBytes] pela entrada padrão do processo
/// e decodifica a saída padrão como UTF-8. Usado pelo translateLocally: seu
/// I/O por stdin/stdout é UTF-8 — diferente do I/O por arquivo (-i/-o), que
/// usa o encoding local do sistema (cp1252 no Windows) e corrompe acentos,
/// cirílico, grego etc. — verificado empiricamente.
typedef RunToolStdinFn = Future<ToolResult> Function(
  String exePath,
  List<String> args,
  List<int> stdinBytes, {
  String? workingDirectory,
  Duration timeout,
  CancellationToken? token,
});

Future<ToolResult> runToolWithStdin(
  String exePath,
  List<String> args,
  List<int> stdinBytes, {
  String? workingDirectory,
  Duration timeout = const Duration(minutes: 30),
  CancellationToken? token,
}) async {
  // Token já cancelado: não vale a pena nem iniciar o subprocesso (o
  // addCancellable abaixo o mataria imediatamente, e a escrita de stdin num
  // processo morto lançaria).
  if (token != null && token.isCancelled) {
    return ToolResult(-1, '', 'Cancelado pelo usuário antes de iniciar');
  }
  final process = await Process.start(exePath, args,
      workingDirectory: workingDirectory, runInShell: false);
  final cancelReg = token?.addCancellable(() => process.kill());
  final stdoutBuf = StringBuffer();
  final stderrBuf = StringBuffer();
  final stdoutStream = process.stdout
      .transform(utf8.decoder)
      .handleError((_) => '');
  final stderrStream = process.stderr
      .transform(systemEncoding.decoder)
      .handleError((_) => '');
  final stdoutFuture = stdoutStream.forEach((s) => stdoutBuf.write(s));
  final stderrFuture = stderrStream.forEach((s) => stderrBuf.write(s));
  // O processo pode ser morto a qualquer momento (cancelamento concorrente);
  // escrever no stdin de um processo morto lança — o exitCode adiante já
  // reporta a falha, então o erro de escrita em si é irrelevante.
  try {
    process.stdin.add(stdinBytes);
    await process.stdin.close();
  } catch (_) {}
  Timer? timeoutTimer;
  Timer? pollTimer;
  bool timedOut = false;
  if (timeout != Duration.zero) {
    timeoutTimer = Timer(timeout, () {
      timedOut = true;
      process.kill();
    });
  }
  if (token != null) {
    pollTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (token.isCancelled) {
        process.kill();
      }
    });
  }
  try {
    final exitCode = await process.exitCode;
    await Future.wait([stdoutFuture, stderrFuture]);
    final stderrFull = stderrBuf.toString();
    final lines = stderrFull.split('\n');
    var tail = lines.length > 50 ? lines.sublist(lines.length - 50).join('\n') : stderrFull;
    if (timedOut) {
      tail = 'Processo excedeu o tempo limite de ${timeout.inMinutes} min e foi encerrado.\n$tail';
    }
    return ToolResult(exitCode, stdoutBuf.toString(), tail, timedOut: timedOut);
  } finally {
    timeoutTimer?.cancel();
    pollTimer?.cancel();
    cancelReg?.dispose();
  }
}

Future<ToolResult> _runToolOnce(
  String exePath,
  List<String> args, {
  String? workingDirectory,
  Duration timeout = const Duration(minutes: 30),
  CancellationToken? token,
}) async {
  if (token != null && token.isCancelled) {
    return ToolResult(-1, '', 'Cancelado pelo usuário antes de iniciar');
  }
  final process = await Process.start(exePath, args,
      workingDirectory: workingDirectory,
      runInShell: false);
  final stdoutBuf = StringBuffer();
  final stderrBuf = StringBuffer();
  final cancelReg = token?.addCancellable(() => process.kill());
  final stdoutStream = process.stdout
      .transform(systemEncoding.decoder)
      .handleError((_) => '');
  final stderrStream = process.stderr
      .transform(systemEncoding.decoder)
      .handleError((_) => '');
  final stdoutFuture = stdoutStream.forEach((s) => stdoutBuf.write(s));
  final stderrFuture = stderrStream.forEach((s) => stderrBuf.write(s));
  Timer? timeoutTimer;
  Timer? pollTimer;
  bool timedOut = false;
  if (timeout != Duration.zero) {
    timeoutTimer = Timer(timeout, () {
      timedOut = true;
      process.kill();
    });
  }
  if (token != null) {
    pollTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (token.isCancelled) {
        process.kill();
      }
    });
  }
  try {
    final exitCode = await process.exitCode;
    await Future.wait([stdoutFuture, stderrFuture]);
    final stderrFull = stderrBuf.toString();
    final lines = stderrFull.split('\n');
    var tail = lines.length > 50 ? lines.sublist(lines.length - 50).join('\n') : stderrFull;
    if (timedOut) {
      tail = 'Processo excedeu o tempo limite de ${timeout.inMinutes} min e foi encerrado.\n$tail';
    }
    return ToolResult(exitCode, stdoutBuf.toString(), tail, timedOut: timedOut);
  } finally {
    timeoutTimer?.cancel();
    pollTimer?.cancel();
    cancelReg?.dispose();
  }
}
