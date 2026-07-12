import 'package:dubbing_engine/src/models.dart';
import 'package:test/test.dart';

void main() {
  group('CancellationToken', () {
    test('starts not cancelled', () {
      expect(CancellationToken().isCancelled, isFalse);
    });

    test('cancel fires every registered callback once', () {
      final token = CancellationToken();
      var a = 0, b = 0;
      token.addCancellable(() => a++);
      token.addCancellable(() => b++);
      token.cancel();
      expect(token.isCancelled, isTrue);
      expect(a, 1);
      expect(b, 1);
    });

    test('cancel is idempotent', () {
      final token = CancellationToken();
      var fired = 0;
      token.addCancellable(() => fired++);
      token.cancel();
      token.cancel();
      expect(fired, 1);
    });

    test('registering on an already-cancelled token fires immediately', () {
      final token = CancellationToken()..cancel();
      var fired = 0;
      token.addCancellable(() => fired++);
      expect(fired, 1);
    });

    test('dispose removes the callback before cancel', () {
      final token = CancellationToken();
      var fired = 0;
      final reg = token.addCancellable(() => fired++);
      reg.dispose();
      token.cancel();
      expect(fired, 0);
    });

    test('dispose after cancel is a harmless no-op', () {
      final token = CancellationToken();
      var fired = 0;
      final reg = token.addCancellable(() => fired++);
      token.cancel();
      expect(fired, 1);
      reg.dispose(); // must not throw nor re-run anything
      expect(fired, 1);
    });

    test('a callback may dispose another during dispatch', () {
      final token = CancellationToken();
      var order = <String>[];
      late CancellationRegistration second;
      token.addCancellable(() {
        order.add('first');
        second.dispose(); // remove a sibling mid-dispatch
      });
      second = token.addCancellable(() => order.add('second'));
      token.cancel();
      // The copy taken in cancel() means removal mid-dispatch must not throw;
      // 'second' was already scheduled in the snapshot, so it still runs.
      expect(order, ['first', 'second']);
    });

    test('a throwing callback does not stop the others from firing', () {
      final token = CancellationToken();
      final fired = <String>[];
      token.addCancellable(() => fired.add('a'));
      token.addCancellable(() => throw StateError('boom'));
      token.addCancellable(() => fired.add('c'));
      // cancel() must not rethrow, and every well-behaved cancellable must run
      // — otherwise a failing FFmpeg cancel would orphan the sherpa/loop ones.
      expect(() => token.cancel(), returnsNormally);
      expect(fired, ['a', 'c']);
      expect(token.isCancelled, isTrue);
    });

    test('throwIfCancelled throws only after cancel', () {
      final token = CancellationToken();
      expect(() => token.throwIfCancelled(PipelineStage.mix), returnsNormally);
      token.cancel();
      expect(
        () => token.throwIfCancelled(PipelineStage.mix),
        throwsA(isA<PipelineException>()
            .having((e) => e.stage, 'stage', PipelineStage.mix)),
      );
    });
  });
}
