import 'package:dubbing_engine/src/backends/ffmpeg_kit_next_runner.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/runtime/media_tool_runner.dart';
import 'package:test/test.dart';

void main() {
  group('FFmpegKitNextRunner', () {
    test('ffprobe: calls the injected callback and maps the result', () async {
      final runner = FFmpegKitNextRunner(
        start: (_) async => throw UnimplementedError(),
        poll: (_) async => throw UnimplementedError(),
        cancel: (_) async {},
        ffprobe: (args) async {
          expect(args, ['-print_format', 'json', '-show_format']);
          return const FfprobeResult(0, '{"format": {}}');
        },
      );
      final result = await runner.run(MediaTool.ffprobe, ['-print_format', 'json', '-show_format']);
      expect(result.exitCode, 0);
      expect(result.stdout, '{"format": {}}');
    });

    test('ffmpeg: starts, polls until returnCode arrives, and returns success', () async {
      var pollCount = 0;
      final runner = FFmpegKitNextRunner(
        start: (args) async {
          expect(args, ['-i', 'in.mp4', 'out.wav']);
          return 42;
        },
        poll: (sessionId) async {
          expect(sessionId, 42);
          pollCount++;
          if (pollCount < 3) return const FFmpegPollResult();
          return const FFmpegPollResult(returnCode: 0, logsTail: 'done');
        },
        cancel: (_) async {},
        ffprobe: (_) async => throw UnimplementedError(),
        pollInterval: Duration.zero,
      );
      final result =
          await runner.run(MediaTool.ffmpeg, ['-i', 'in.mp4', 'out.wav'], token: CancellationToken());
      expect(result.exitCode, 0);
      expect(result.stderrTail, 'done');
      expect(result.timedOut, isFalse);
      expect(pollCount, 3);
    });

    test('ffmpeg: non-zero returnCode propagates as exitCode', () async {
      final runner = FFmpegKitNextRunner(
        start: (_) async => 1,
        poll: (_) async => const FFmpegPollResult(returnCode: 1, logsTail: 'boom'),
        cancel: (_) async {},
        ffprobe: (_) async => throw UnimplementedError(),
        pollInterval: Duration.zero,
      );
      final result = await runner.run(MediaTool.ffmpeg, ['-i', 'bad.mp4']);
      expect(result.exitCode, 1);
      expect(result.stderrTail, 'boom');
    });

    test('ffmpeg: cancellation before start returns without calling start', () async {
      var startCalled = false;
      final runner = FFmpegKitNextRunner(
        start: (_) async {
          startCalled = true;
          return 1;
        },
        poll: (_) async => throw UnimplementedError(),
        cancel: (_) async {},
        ffprobe: (_) async => throw UnimplementedError(),
      );
      final token = CancellationToken()..cancel();
      final result = await runner.run(MediaTool.ffmpeg, ['-i', 'in.mp4'], token: token);
      expect(startCalled, isFalse);
      expect(result.exitCode, -1);
    });

    test('ffmpeg: cancellation mid-run calls cancel() with the sessionId', () async {
      final cancelledSessions = <int>[];
      var pollCount = 0;
      final token = CancellationToken();
      final runner = FFmpegKitNextRunner(
        start: (_) async => 7,
        poll: (_) async {
          pollCount++;
          if (pollCount == 1) {
            token.cancel(); // simula o usuário cancelando entre dois polls
          }
          if (pollCount < 3) return const FFmpegPollResult();
          return const FFmpegPollResult(returnCode: 255, logsTail: 'cancelled');
        },
        cancel: (sessionId) async => cancelledSessions.add(sessionId),
        ffprobe: (_) async => throw UnimplementedError(),
        pollInterval: Duration.zero,
      );
      final result = await runner.run(MediaTool.ffmpeg, ['-i', 'in.mp4'], token: token);
      expect(cancelledSessions, [7]);
      expect(result.exitCode, 255);
    });

    test('ffmpeg: timeout calls cancel() and marks the result timedOut', () async {
      final cancelledSessions = <int>[];
      var pollCount = 0;
      final runner = FFmpegKitNextRunner(
        start: (_) async => 9,
        poll: (_) async {
          pollCount++;
          // nunca reporta returnCode antes do timeout dar match — simula uma
          // sessão travada, forçando o timer de timeout a agir.
          if (pollCount > 50) return const FFmpegPollResult(returnCode: 255);
          return const FFmpegPollResult();
        },
        cancel: (sessionId) async => cancelledSessions.add(sessionId),
        ffprobe: (_) async => throw UnimplementedError(),
        pollInterval: const Duration(milliseconds: 1),
      );
      final result = await runner.run(MediaTool.ffmpeg, ['-i', 'in.mp4'],
          timeout: const Duration(milliseconds: 5));
      expect(cancelledSessions, [9]);
      expect(result.timedOut, isTrue);
      expect(result.stderrTail, contains('tempo limite'));
    });

    test('ffmpeg: reports progress via onProgress when -t is present in args', () async {
      final progressValues = <double>[];
      var pollCount = 0;
      final runner = FFmpegKitNextRunner(
        start: (_) async => 3,
        poll: (_) async {
          pollCount++;
          if (pollCount == 1) return const FFmpegPollResult(statTimeMs: 5000);
          return const FFmpegPollResult(returnCode: 0, statTimeMs: 10000);
        },
        cancel: (_) async {},
        ffprobe: (_) async => throw UnimplementedError(),
        pollInterval: Duration.zero,
      );
      await runner.run(MediaTool.ffmpeg, ['-i', 'in.mp4', '-t', '10', 'out.mp4'],
          onProgress: progressValues.add);
      expect(progressValues, [0.5, 1.0]);
    });

    test('ffmpeg: without -t in args, onProgress is never called', () async {
      var progressCalls = 0;
      final runner = FFmpegKitNextRunner(
        start: (_) async => 3,
        poll: (_) async => const FFmpegPollResult(returnCode: 0, statTimeMs: 10000),
        cancel: (_) async {},
        ffprobe: (_) async => throw UnimplementedError(),
        pollInterval: Duration.zero,
      );
      await runner.run(MediaTool.ffmpeg, ['-i', 'in.mp4', 'out.mp4'],
          onProgress: (_) => progressCalls++);
      expect(progressCalls, 0);
    });
  });
}
