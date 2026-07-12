import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:test/test.dart';

void main() {
  group('SeparationOutcome', () {
    test('success carries files and no reason', () {
      const o = SeparationOutcome.success((vocalsWav: 'v.wav', accompanimentWav: 'a.wav'));
      expect(o.ok, isTrue);
      expect(o.reason, isNull);
      expect(o.detail, isNull);
      expect(o.isExpected, isFalse);
      expect(o.files!.vocalsWav, 'v.wav');
    });

    test('failure carries a reason and optional detail', () {
      const o = SeparationOutcome.failure(SeparationFailureReason.toolFailed,
          detail: 'sherpa exit 1');
      expect(o.ok, isFalse);
      expect(o.files, isNull);
      expect(o.reason, SeparationFailureReason.toolFailed);
      expect(o.detail, 'sherpa exit 1');
      expect(o.isExpected, isFalse);
    });

    test('notSupportedOnPlatform is the only expected failure', () {
      for (final r in SeparationFailureReason.values) {
        final o = SeparationOutcome.failure(r);
        expect(o.isExpected, r == SeparationFailureReason.notSupportedOnPlatform,
            reason: '$r');
      }
    });

    test('detail is optional', () {
      const o = SeparationOutcome.failure(SeparationFailureReason.cancelled);
      expect(o.detail, isNull);
      expect(o.reason, SeparationFailureReason.cancelled);
    });
  });
}
