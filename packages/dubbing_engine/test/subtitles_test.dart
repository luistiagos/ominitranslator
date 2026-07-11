import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/steps/subtitles.dart';
import 'package:test/test.dart';

void main() {
  group('buildSrtContent', () {
    test('single segment formats correctly', () {
      final segments = [
        DubbingSegment(
          0,
          Duration(milliseconds: 61500),
          Duration(milliseconds: 63250),
          'Olá!',
        ),
      ];
      final result = buildSrtContent(segments, true);
      expect(result, '1\n00:01:01,500 --> 00:01:03,250\nOlá!\n\n');
    });

    test('timestamp over 1 hour formats correctly', () {
      final segments = [
        DubbingSegment(
          0,
          Duration(milliseconds: 3661000),
          Duration(milliseconds: 3680000),
          'Long video',
        ),
      ];
      final result = buildSrtContent(segments, true);
      expect(result, '1\n01:01:01,000 --> 01:01:20,000\nLong video\n\n');
    });

    test('uses translated text when useSource is false', () {
      final seg = DubbingSegment(
        0,
        Duration(milliseconds: 1000),
        Duration(milliseconds: 3000),
        'Hello',
      );
      seg.translatedText = 'Olá';
      final result = buildSrtContent([seg], false);
      expect(result, '1\n00:00:01,000 --> 00:00:03,000\nOlá\n\n');
    });
  });
}
