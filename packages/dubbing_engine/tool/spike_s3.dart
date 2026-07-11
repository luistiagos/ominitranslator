// Spike S3 — Piper via Dart com controle de speed
// Run: dart run tool/spike_s3.dart
// Prerequisites: tools/win/, piper-en, piper-pt-br, piper-es models installed

import 'dart:io';
import 'package:dubbing_engine/dubbing_engine.dart';
import 'package:dubbing_engine/src/backends/piper_synthesizer.dart';

final sentences = {
  Lang.en: ['Hello, how are you today?', 'This is a test of the Piper voice.', 'The quick brown fox jumps over the lazy dog.'],
  Lang.pt: ['Olá, como você está hoje?', 'Este é um teste da voz do Piper.', 'O rato roeu a roupa do rei de Roma.'],
  Lang.es: ['Hola, ¿cómo estás hoy?', 'Esta es una prueba de la voz de Piper.', 'El veloz murciélago hindú comía feliz cardillo y kiwi.'],
};

void main() {
  final appData = Platform.environment['APPDATA'] ?? '${Platform.environment['USERPROFILE']}\\AppData\\Roaming';
  final modelsRoot = '$appData\\omnitranslator\\models';
  final tools = Tools.locate();
  final models = ModelManager(modelsRoot, tools);

  for (final lang in Lang.values) {
    print('\n=== Language: $lang ===');
    final synthesizer = PiperSynthesizer(lang, models);
    for (int si = 0; si < sentences[lang]!.length; si++) {
      final text = sentences[lang]![si];
      for (final speed in [1.0, 1.2, 1.35]) {
        final audio = synthesizer.synthesize(text, speed: speed);
        final dur = audio.samples.length / audio.sampleRate;
        final filename = 's3_${lang.name}_${speed.toString().replaceAll('.', '_')}_$si.wav';
        writeWavPcm16(filename, WavData(audio.samples, audio.sampleRate, 1));
        print('  $filename: ${dur.toStringAsFixed(2)}s (speed=$speed)');
      }
    }
    synthesizer.dispose();
  }

  print('\nDone. Generated 27 WAV files.');
}
