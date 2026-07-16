import 'dart:async';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/runtime/media_tool_runner.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';

/// Um poll de sessão FFmpegKit — espelha o retorno de `ffmpegPoll` do
/// MethodChannel (`at3-bench-MainActivity.kt`): `returnCode` só vem
/// preenchido quando a sessão termina (sucesso, erro ou cancelamento).
class FFmpegPollResult {
  final int? returnCode;
  final String logsTail;

  /// Tempo de mídia processada em ms (`Statistics.time`), ou null se ainda
  /// não há amostra.
  final double? statTimeMs;
  const FFmpegPollResult({this.returnCode, this.logsTail = '', this.statTimeMs});
}

class FfprobeResult {
  final int returnCode;
  final String output;
  const FfprobeResult(this.returnCode, this.output);
}

typedef FFmpegStartFn = Future<int> Function(List<String> args);
typedef FFmpegPollFn = Future<FFmpegPollResult> Function(int sessionId);
typedef FFmpegCancelFn = Future<void> Function(int sessionId);
typedef FfprobeFn = Future<FfprobeResult> Function(List<String> args);

/// [MediaToolRunner] do Android — FFmpegKitNext (AT-3) roda in-process no
/// device, então não existe `.exe`/subprocesso pra chamar. As 4 operações
/// (start/poll/cancel/ffprobe) são injetadas como callbacks em vez de um
/// `MethodChannel` direto: o `dubbing_engine` é Dart puro (zero dependência
/// de `package:flutter`), mesmo padrão do `AndroidDiskSpaceProbe`
/// (`runtime/disk_space_probe.dart`) — quem monta a ponte real com
/// `MethodChannel('omnitranslator/ffmpeg')` é a camada do app
/// (`app/lib/src/platform/`), não o engine.
///
/// API do canal provada no device pelo AT-3
/// (`docs/spikes-android/at3-evidence/at3-bench-MainActivity.kt`, 13/13
/// casos PASSOU). O handler Kotlin mora no `MediaProcessingService` (D3.3),
/// não na `MainActivity` — o job roda no serviço em foreground, não na UI.
class FFmpegKitNextRunner implements MediaToolRunner {
  final FFmpegStartFn _start;
  final FFmpegPollFn _poll;
  final FFmpegCancelFn _cancel;
  final FfprobeFn _ffprobe;
  final Duration _pollInterval;

  FFmpegKitNextRunner({
    required FFmpegStartFn start,
    required FFmpegPollFn poll,
    required FFmpegCancelFn cancel,
    required FfprobeFn ffprobe,
    Duration? pollInterval,
  })  : _start = start,
        _poll = poll,
        _cancel = cancel,
        _ffprobe = ffprobe,
        _pollInterval = pollInterval ?? const Duration(milliseconds: 200);

  @override
  Future<ToolResult> run(
    MediaTool tool,
    List<String> args, {
    String? workingDirectory,
    Duration timeout = toolTimeout,
    CancellationToken? token,
    void Function(double progress)? onProgress,
  }) {
    return switch (tool) {
      MediaTool.ffprobe => _runFfprobe(args),
      MediaTool.ffmpeg => _runFfmpeg(args, timeout: timeout, token: token, onProgress: onProgress),
    };
  }

  Future<ToolResult> _runFfprobe(List<String> args) async {
    final result = await _ffprobe(args);
    return ToolResult(result.returnCode, result.output, '');
  }

  Future<ToolResult> _runFfmpeg(
    List<String> args, {
    required Duration timeout,
    CancellationToken? token,
    void Function(double progress)? onProgress,
  }) async {
    if (token != null && token.isCancelled) {
      return ToolResult(-1, '', 'Cancelado pelo usuário antes de iniciar');
    }

    final sessionId = await _start(args);

    // -t <segundos>: quando o comando declara duração de saída explícita, dá
    // pra converter statTimeMs (ms de mídia processada) num progresso 0..1.
    // Sem isso não há como saber o total — onProgress simplesmente não é
    // chamado (nenhum chamador usa este parâmetro ainda; é preparação para a
    // D3.3/D3.4).
    final expectedDurationSeconds = _parseDashTSeconds(args);
    final expectedDurationMs = expectedDurationSeconds == null ? null : expectedDurationSeconds * 1000;

    final cancelReg = token?.addCancellable(() {
      unawaited(_cancel(sessionId));
    });
    var timedOut = false;
    Timer? timeoutTimer;
    if (timeout != Duration.zero) {
      timeoutTimer = Timer(timeout, () {
        timedOut = true;
        unawaited(_cancel(sessionId));
      });
    }

    try {
      while (true) {
        final poll = await _poll(sessionId);
        if (expectedDurationMs != null && onProgress != null && poll.statTimeMs != null) {
          final ratio = (poll.statTimeMs! / expectedDurationMs).clamp(0.0, 1.0);
          onProgress(ratio);
        }
        if (poll.returnCode != null) {
          final tail = timedOut
              ? 'Sessão excedeu o tempo limite de ${timeout.inMinutes} min e foi cancelada.\n${poll.logsTail}'
              : poll.logsTail;
          return ToolResult(poll.returnCode!, '', tail, timedOut: timedOut);
        }
        await Future.delayed(_pollInterval);
      }
    } finally {
      timeoutTimer?.cancel();
      cancelReg?.dispose();
    }
  }
}

int? _parseDashTSeconds(List<String> args) {
  final idx = args.indexOf('-t');
  if (idx < 0 || idx + 1 >= args.length) return null;
  return double.tryParse(args[idx + 1])?.round();
}
