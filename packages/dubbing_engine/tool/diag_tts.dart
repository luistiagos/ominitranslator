// Sintetiza cada linha de um arquivo de texto com uma voz e grava um WAV
// único (para inspecionar o que o TTS realmente fala).
// Run: diag_tts.exe <lang> <modelId> <sid> <textFile> <outWav>

import 'dart:io';
import 'dart:typed_data';
import 'package:dubbing_engine/dubbing_engine.dart';

void main(List<String> argv) {
  final lang = Lang.values.byName(argv[0]);
  final modelId = argv[1];
  final sid = int.parse(argv[2]);
  final lines = File(argv[3])
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .toList();
  final outWav = argv[4];

  final appData = Platform.environment['APPDATA']!;
  const dummyTools = Tools(
    ffmpeg: '',
    ffprobe: '',
    whisperCli: '',
    translateLocally: '',
    sherpaSourceSeparation: '',
  );
  final models = ModelManager('$appData\\omnitranslator\\models', dummyTools);
  final synth = PiperSynthesizer(lang, models, voiceOverride: (modelId, sid));
  try {
    final chunks = <Float32List>[];
    int rate = ttsSampleRate;
    for (final line in lines) {
      final audio = synth.synthesize(line);
      chunks.add(audio.samples);
      rate = audio.sampleRate;
      // Pausa de 300ms entre linhas.
      chunks.add(Float32List((rate * 0.3).round()));
    }
    final total = chunks.fold<int>(0, (s, c) => s + c.length);
    final joined = Float32List(total);
    int pos = 0;
    for (final c in chunks) {
      joined.setAll(pos, c);
      pos += c.length;
    }
    writeWavPcm16(outWav, WavData(joined, rate, 1));
    print('OK: $outWav (${(total / rate).toStringAsFixed(1)}s, ${lines.length} linhas)');
  } finally {
    synth.dispose();
  }
}
