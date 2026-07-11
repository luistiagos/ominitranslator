import 'dart:io';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ToolResult', () {
    test('stores exitCode, stdout and stderrTail', () {
      final r = ToolResult(42, 'out', 'err');
      expect(r.exitCode, 42);
      expect(r.stdout, 'out');
      expect(r.stderrTail, 'err');
    });
  });

  group('runTool', () {
    test('runs a simple command and returns stdout', () async {
      final r = await runTool('cmd', ['/c', 'echo', 'hello'], timeout: const Duration(seconds: 10));
      expect(r.exitCode, 0);
      expect(r.stdout.trim(), 'hello');
    });

    test('captures non-zero exit code', () async {
      final r = await runTool('cmd', ['/c', 'exit', '1'],
          timeout: const Duration(seconds: 10));
      expect(r.exitCode, 1);
    });

    test('does not retry on failure (deterministic errors fail fast)', () async {
      final tempDir = Directory.systemTemp.createTempSync('noretry_');
      try {
        final log = p.join(tempDir.path, 'log.txt');
        final script = p.join(tempDir.path, 'always_fail.bat');
        File(script).writeAsStringSync('@echo off\necho x >> "%~1"\nexit /b 1');

        final r = await runTool(script, [log], timeout: const Duration(seconds: 10));

        expect(r.exitCode, 1);
        // Uma linha por execução: rodou exatamente uma vez.
        expect(File(log).readAsLinesSync().length, 1);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    // Nota: 'ping' é invocado direto (sem 'cmd /c'): matar o cmd não mata o
    // ping filho, que seguraria os pipes de stdout/stderr por ~30s e
    // atrasaria o retorno do runTool.
    test('kills process on timeout and returns non-zero exit', () async {
      final r = await runTool('ping', ['-n', '30', '127.0.0.1'],
          timeout: const Duration(milliseconds: 200));
      expect(r.exitCode, isNot(0));
    });

    test('does not retry after a timeout (would otherwise take minutes)', () async {
      final stopwatch = Stopwatch()..start();
      final r = await runTool('ping', ['-n', '30', '127.0.0.1'],
          timeout: const Duration(milliseconds: 200));
      stopwatch.stop();
      expect(r.exitCode, isNot(0));
      expect(r.timedOut, isTrue);
      // 6 tentativas com timeout de 200ms + backoff somariam vários
      // segundos; sem retry, deve terminar quase junto com o timeout.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('CancellationToken cancels running process', () async {
      final token = CancellationToken();
      final future = runTool('ping', ['-n', '30', '127.0.0.1'],
          token: token, timeout: const Duration(seconds: 10));
      token.cancel();
      final r = await future;
      expect(r.exitCode, isNot(0));
    });

    test('does not retry after cancellation', () async {
      final token = CancellationToken();
      final stopwatch = Stopwatch()..start();
      final future = runTool('ping', ['-n', '30', '127.0.0.1'],
          token: token, timeout: const Duration(seconds: 10));
      token.cancel();
      final r = await future;
      stopwatch.stop();
      expect(r.exitCode, isNot(0));
      // Sem o guard de cancelamento, o retry ficaria matando novos
      // processos de ping por vários segundos a mais (backoff incluso).
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('truncates stderr to last 50 lines', () async {
      final tempDir = Directory.systemTemp.createTempSync('stderr_test_');
      try {
        final script = tempDir.path + '\\stderr_script.bat';
        File(script).writeAsStringSync('@echo off\nfor /l %%i in (1,1,100) do echo line %%i >&2\nexit /b 0');
        final r = await runTool(script, [], timeout: const Duration(seconds: 10));
        expect(r.exitCode, 0);
        expect(r.stderrTail.split('\n').length, 50);
        expect(r.stderrTail, contains('line 52'));
        expect(r.stderrTail, contains('line 100'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('runToolWithRetry', () {
    test('retries after a failure and succeeds', () async {
      final tempDir = Directory.systemTemp.createTempSync('retry_ok_');
      try {
        // Falha na 1ª execução (cria o marcador), sucede na 2ª (marcador
        // já existe) — simula um erro transitório que some sozinho.
        final marker = p.join(tempDir.path, 'marker');
        final script = p.join(tempDir.path, 'fail_once.bat');
        File(script).writeAsStringSync(
            '@echo off\nif exist "%~1" (exit /b 0) else (type nul > "%~1" && exit /b 1)');

        final r = await runToolWithRetry(script, [marker],
            timeout: const Duration(seconds: 10), maxAttempts: 2, retryDelay: (_) => Duration.zero);

        expect(r.exitCode, 0);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('gives up after exhausting maxAttempts and reports the attempt count', () async {
      final tempDir = Directory.systemTemp.createTempSync('retry_fail_');
      try {
        final log = p.join(tempDir.path, 'log.txt');
        final script = p.join(tempDir.path, 'always_fail.bat');
        File(script).writeAsStringSync('@echo off\necho x >> "%~1"\nexit /b 1');

        final r = await runToolWithRetry(script, [log],
            timeout: const Duration(seconds: 10), maxAttempts: 3, retryDelay: (_) => Duration.zero);

        expect(r.exitCode, 1);
        // O script grava uma linha por execução: prova que rodou exatamente
        // maxAttempts vezes, nem mais nem menos.
        final lines = File(log).readAsLinesSync();
        expect(lines.length, 3);
        expect(r.stderrTail, contains('Falhou após 3 tentativas'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('cancellation during backoff returns quickly', () async {
      final tempDir = Directory.systemTemp.createTempSync('retry_cancel_');
      try {
        final script = p.join(tempDir.path, 'always_fail.bat');
        File(script).writeAsStringSync('@echo off\nexit /b 1');

        final token = CancellationToken();
        final stopwatch = Stopwatch()..start();
        final future = runToolWithRetry(script, [],
            timeout: const Duration(seconds: 10),
            token: token,
            maxAttempts: 3,
            retryDelay: (_) => const Duration(seconds: 30));
        // Cancela durante o backoff de 30s da primeira falha.
        Future.delayed(const Duration(milliseconds: 300), token.cancel);
        final r = await future;
        stopwatch.stop();

        expect(r.exitCode, 1);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
