import 'package:dubbing_engine/dubbing_engine.dart';

void main() {
  final supportedLangs = Lang.values.map((l) => '${l.name}: ${l.whisperCode}').join(', ');
  print('OmniTranslator engine loaded. Supported languages: $supportedLangs');
}
