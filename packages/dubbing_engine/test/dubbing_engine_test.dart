import 'package:dubbing_engine/dubbing_engine.dart';
import 'package:test/test.dart';

void main() {
  test('dubbing_engine exports key types', () {
    expect(Lang.values.length, 3);
    expect(Preset.values.length, 2);
    expect(PipelineStage.values.length, 12);
  });
}
