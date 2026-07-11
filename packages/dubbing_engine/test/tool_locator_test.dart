import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:test/test.dart';

void main() {
  group('Tools constructor', () {
    test('stores all tool paths', () {
      final tools = Tools(
        ffmpeg: 'a',
        ffprobe: 'b',
        whisperCli: 'c',
        translateLocally: 'd',
        sherpaSourceSeparation: 'e',
      );
      expect(tools.ffmpeg, 'a');
      expect(tools.ffprobe, 'b');
      expect(tools.whisperCli, 'c');
      expect(tools.translateLocally, 'd');
      expect(tools.sherpaSourceSeparation, 'e');
    });
  });
}
