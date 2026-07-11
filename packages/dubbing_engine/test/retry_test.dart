import 'package:dubbing_engine/src/tools/retry.dart';
import 'package:test/test.dart';

void main() {
  group('defaultRetryDelay', () {
    test('grows exponentially and caps at 30s', () {
      expect(defaultRetryDelay(1), const Duration(seconds: 2));
      expect(defaultRetryDelay(2), const Duration(seconds: 4));
      expect(defaultRetryDelay(3), const Duration(seconds: 8));
      expect(defaultRetryDelay(4), const Duration(seconds: 16));
      expect(defaultRetryDelay(5), const Duration(seconds: 30));
      expect(defaultRetryDelay(10), const Duration(seconds: 30));
    });
  });

  group('retryAsync', () {
    test('returns immediately on first success without retrying', () async {
      int calls = 0;
      final result = await retryAsync<int>(
        () async {
          calls++;
          return 42;
        },
        isSuccess: (r) => r == 42,
        retryDelay: (_) => Duration.zero,
      );
      expect(result, 42);
      expect(calls, 1);
    });

    test('retries until success within maxAttempts', () async {
      int calls = 0;
      final result = await retryAsync<int>(
        () async {
          calls++;
          return calls < 3 ? 0 : 42;
        },
        isSuccess: (r) => r == 42,
        maxAttempts: 5,
        retryDelay: (_) => Duration.zero,
      );
      expect(result, 42);
      expect(calls, 3);
    });

    test('gives up and returns the last result after exhausting maxAttempts', () async {
      int calls = 0;
      final result = await retryAsync<int>(
        () async {
          calls++;
          return 0;
        },
        isSuccess: (r) => r == 42,
        maxAttempts: 4,
        retryDelay: (_) => Duration.zero,
      );
      expect(result, 0);
      expect(calls, 4);
    });

    test('stops immediately when isFatal is true, without retrying', () async {
      int calls = 0;
      final result = await retryAsync<int>(
        () async {
          calls++;
          return -1;
        },
        isSuccess: (r) => r == 42,
        isFatal: (r) => r == -1,
        maxAttempts: 5,
        retryDelay: (_) => Duration.zero,
      );
      expect(result, -1);
      expect(calls, 1);
    });

    test('stops after the in-flight attempt when isCancelled becomes true', () async {
      int calls = 0;
      bool cancelled = false;
      final result = await retryAsync<int>(
        () async {
          calls++;
          cancelled = true; // simula cancelamento ocorrendo durante a tentativa
          return 0;
        },
        isSuccess: (r) => r == 42,
        isCancelled: () => cancelled,
        maxAttempts: 5,
        retryDelay: (_) => Duration.zero,
      );
      expect(result, 0);
      expect(calls, 1);
    });

    test('does not start a new attempt if cancelled during the backoff wait', () async {
      int calls = 0;
      final result = await retryAsync<int>(
        () async {
          calls++;
          return 0;
        },
        isSuccess: (r) => r == 42,
        isCancelled: () => calls >= 1, // já cancelado antes da 2ª tentativa
        maxAttempts: 5,
        retryDelay: (_) => Duration.zero,
      );
      expect(result, 0);
      expect(calls, 1);
    });

    test('passes increasing attempt numbers to retryDelay', () async {
      final delaysRequested = <int>[];
      await retryAsync<int>(
        () async => 0,
        isSuccess: (r) => r == 42,
        maxAttempts: 4,
        retryDelay: (attempt) {
          delaysRequested.add(attempt);
          return Duration.zero;
        },
      );
      expect(delaysRequested, [1, 2, 3]);
    });
  });
}
