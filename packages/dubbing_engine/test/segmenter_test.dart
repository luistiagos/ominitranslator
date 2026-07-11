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
    });
  });
}
