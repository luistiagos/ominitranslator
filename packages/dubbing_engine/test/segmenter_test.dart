import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/steps/segmenter.dart';
import 'package:test/test.dart';

void main() {
  group('buildDubbingSegments', () {
    test('does not merge adjacent segments from different speakers', () {
      final input = [
        TranscriptSegment(Duration.zero, Duration(milliseconds: 500), 'Oi', speaker: 0),
        TranscriptSegment(Duration(milliseconds: 600), Duration(milliseconds: 1000), 'Olá', speaker: 1),
      ];
      final result = buildDubbingSegments(input);
      expect(result.length, 2);
      expect(result[0].speaker, 0);
      expect(result[1].speaker, 1);
    });

    test('merges adjacent segments from the same speaker', () {
      final input = [
        TranscriptSegment(Duration.zero, Duration(milliseconds: 500), 'Oi', speaker: 1),
        TranscriptSegment(Duration(milliseconds: 600), Duration(milliseconds: 1000), 'tudo bem', speaker: 1),
      ];
      final result = buildDubbingSegments(input);
      expect(result.length, 1);
      expect(result.single.speaker, 1);
      expect(result.single.sourceText, 'Oi tudo bem');
    });

    test('speaker is propagated to sentence splits', () {
      final input = [
        TranscriptSegment(Duration.zero, Duration(milliseconds: 4000),
            'Primeira frase. Segunda frase.', speaker: 2),
      ];
      final result = buildDubbingSegments(input);
      expect(result.length, 2);
      expect(result.map((s) => s.speaker), everyElement(2));
    });

    test('merge segments with short pause', () {
      final input = [
        TranscriptSegment(
          Duration(milliseconds: 0),
          Duration(milliseconds: 2000),
          'Olá mundo.',
        ),
        TranscriptSegment(
          Duration(milliseconds: 2300),
          Duration(milliseconds: 4000),
          'Tudo bem?',
        ),
      ];
      final result = buildDubbingSegments(input);
      expect(result.length, 2);
      expect(result[0].start, Duration(milliseconds: 0));
      expect(result[0].sourceText, 'Olá mundo.');
      expect(result[1].sourceText, 'Tudo bem?');
    });

    test('no merge when pause exceeds limit', () {
      final input = [
        TranscriptSegment(
          Duration(milliseconds: 0),
          Duration(milliseconds: 2000),
          'Olá mundo.',
        ),
        TranscriptSegment(
          Duration(milliseconds: 2900),
          Duration(milliseconds: 4000),
          'Tudo bem?',
        ),
      ];
      final result = buildDubbingSegments(input);
      expect(result.length, 2);
      expect(result[0].end, Duration(milliseconds: 2000));
      expect(result[1].start, Duration(milliseconds: 2900));
    });

    test('filter out music and empty segments', () {
      final input = [
        TranscriptSegment(
          Duration(milliseconds: 0),
          Duration(milliseconds: 1000),
          '[Music]',
        ),
        TranscriptSegment(
          Duration(milliseconds: 1000),
          Duration(milliseconds: 2000),
          '♪',
        ),
        TranscriptSegment(
          Duration(milliseconds: 2000),
          Duration(milliseconds: 3000),
          '  ',
        ),
      ];
      final result = buildDubbingSegments(input);
      expect(result, isEmpty);
    });

    test('do not merge when char count exceeds limit', () {
      final longTextA = 'a' * 150;
      final longTextB = 'b' * 100;
      final input = [
        TranscriptSegment(
          Duration(milliseconds: 0),
          Duration(milliseconds: 2000),
          longTextA,
        ),
        TranscriptSegment(
          Duration(milliseconds: 2100),
          Duration(milliseconds: 4000),
          longTextB,
        ),
      ];
      final result = buildDubbingSegments(input);
      expect(result.length, 2);
    });

    test('split multi-sentence segment proportionally', () {
      final input = [
        TranscriptSegment(
          Duration(milliseconds: 0),
          Duration(milliseconds: 4000),
          'Olá mundo. Tudo bem?',
        ),
      ];
      final result = buildDubbingSegments(input);
      expect(result.length, 2);
      expect(result[0].sourceText, 'Olá mundo.');
      expect(result[1].sourceText, 'Tudo bem?');
      expect(result[0].start, Duration(milliseconds: 0));
      expect(result[1].end, Duration(milliseconds: 4000));
      // 10 chars of 19 over 4000 ms.
      expect(result[0].end, Duration(microseconds: 2105263));
      expect(result[1].start, Duration(microseconds: 2105263));
    });

    test('merge then split lands on the real constituent boundary', () {
      final input = [
        TranscriptSegment(
          Duration(milliseconds: 0),
          Duration(milliseconds: 2000),
          'Olá mundo.',
        ),
        TranscriptSegment(
          Duration(milliseconds: 2300),
          Duration(milliseconds: 4000),
          'Tudo bem?',
        ),
      ];
      final result = buildDubbingSegments(input);
      expect(result.length, 2);
      // The 300 ms pause between the two utterances must survive the merge.
      // Splitting the merged text by character count would put both boundaries
      // at 2105 ms, ending the first sentence 105 ms late and starting the
      // second one 195 ms early.
      expect(result[0].end, Duration(milliseconds: 2000));
      expect(result[1].start, Duration(milliseconds: 2300));
    });

    test('word-level input keeps each sentence anchored to its own words', () {
      // whisper-cli runs with `-ml 1 -sow`, so every segment is one word.
      final words = [
        (0, 400, 'The'),
        (400, 900, 'weather'),
        (900, 1200, 'is'),
        (1200, 2000, 'beautiful.'),
        (2600, 3000, 'Let'),
        (3000, 3200, 'us'),
        (3200, 4000, 'go.'),
      ];
      final input = [
        for (final (s, e, t) in words)
          TranscriptSegment(
              Duration(milliseconds: s), Duration(milliseconds: e), t),
      ];
      final result = buildDubbingSegments(input);
      expect(result.length, 2);
      expect(result[0].sourceText, 'The weather is beautiful.');
      expect(result[0].start, Duration(milliseconds: 0));
      expect(result[0].end, Duration(milliseconds: 2000));
      expect(result[1].sourceText, 'Let us go.');
      expect(result[1].start, Duration(milliseconds: 2600));
      expect(result[1].end, Duration(milliseconds: 4000));
    });

    test('boundary resolver overrides the proportional cut', () {
      final input = [
        TranscriptSegment(
          Duration(milliseconds: 0),
          Duration(milliseconds: 4000),
          'Olá mundo. Tudo bem?',
        ),
      ];
      late Duration seenEstimate;
      final result = buildDubbingSegments(
        input,
        resolveBoundary: (estimate, {required lower, required upper}) {
          seenEstimate = estimate;
          expect(lower, Duration.zero);
          expect(upper, Duration(milliseconds: 4000));
          return Duration(milliseconds: 2400);
        },
      );
      expect(seenEstimate, Duration(microseconds: 2105263));
      expect(result[0].end, Duration(milliseconds: 2400));
      expect(result[1].start, Duration(milliseconds: 2400));
    });

    test('boundary resolver result is clamped inside the segment', () {
      final input = [
        TranscriptSegment(
          Duration(milliseconds: 1000),
          Duration(milliseconds: 4000),
          'Olá mundo. Tudo bem?',
        ),
      ];
      final result = buildDubbingSegments(
        input,
        resolveBoundary: (estimate, {required lower, required upper}) =>
            Duration(milliseconds: 99999),
      );
      expect(result[0].end, Duration(milliseconds: 4000));
      expect(result[1].start, Duration(milliseconds: 4000));
    });

    test('abbreviation followed by lowercase does not split', () {
      final input = [
        TranscriptSegment(Duration.zero, Duration(milliseconds: 500), 'Dr.'),
        TranscriptSegment(
            Duration(milliseconds: 500), Duration(milliseconds: 1200), 'silva'),
        TranscriptSegment(
            Duration(milliseconds: 1200), Duration(milliseconds: 2000), 'chegou.'),
      ];
      final result = buildDubbingSegments(input);
      expect(result.length, 1);
      expect(result.single.sourceText, 'Dr. silva chegou.');
      expect(result.single.end, Duration(milliseconds: 2000));
    });
  });
}
