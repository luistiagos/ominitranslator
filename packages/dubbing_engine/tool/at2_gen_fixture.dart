// AT-2 spike: gera ~5 min de fala sintética (Piper) por idioma, com pausas
// conhecidas entre frases — dá VERDADE conhecida (ground truth) de onde cada
// fala começa, o que permite medir o erro absoluto de qualquer backend de ASR
// contra um valor exato, em vez de comparar dois backends ruidosos entre si.
//
// Não há mídia real commitada no repo (convenção do projeto); mesmo método já
// usado em tool/integration_test.dart.
//
// Saída: <out>/<lang>.wav (16 kHz mono PCM16, para o sherpa) e
//        <out>/<lang>_ground_truth.json (início/fim reais de cada frase).
//
// Uso: dart run tool/at2_gen_fixture.dart <outDir>
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dubbing_engine/dubbing_engine.dart';
import 'package:dubbing_engine/src/backends/piper_synthesizer.dart';
import 'package:path/path.dart' as p;

const _gapSec = 0.9; // pausa entre frases — dá ao VAD uma fronteira clara

/// Só o espanhol é hardcoded aqui; en/pt reusam a suíte de 100 frases já
/// vetada do AT-1 (docs/spikes-android/at1-suite/), lida em [_loadSentences].
final _esSentences = <String>[
    'El clima está hermoso hoy.',
    'Me gustaría una taza de café.',
    'El tren sale a las siete de la mañana.',
    'Ella compró tres libros ayer.',
    'Vamos a la playa este fin de semana.',
    'Mi hermano trabaja en un hospital del centro.',
    '¿Podría decirme dónde está la estación?',
    'Los niños están jugando en el jardín.',
    'Nunca he estado en Portugal antes.',
    'Él olvidó su paraguas en la oficina.',
    'Este restaurante sirve la mejor pizza de la ciudad.',
    'Por favor, apaga las luces antes de salir.',
    'La reunión se pospuso hasta el próximo jueves.',
    'Su casa nueva tiene una cocina grande.',
    'Necesito comprar leche y pan.',
    'La película comienza en veinte minutos.',
    'Ella habla cuatro idiomas con fluidez.',
    'Vimos la puesta de sol desde la colina.',
    'El perro ladró toda la noche.',
    'Mi abuela me enseñó a cocinar.',
    'El vuelo se retrasó por la tormenta.',
    'Él está estudiando medicina en la universidad.',
    '¿Puedes ayudarme a llevar estas cajas?',
    'El museo está cerrado los lunes.',
    'Perdí mis llaves en algún lugar del parque.',
    'Celebraron su aniversario en París.',
    'La sopa necesita un poco más de sal.',
    'Nuestro equipo ganó el campeonato el año pasado.',
    'Ella le escribió una carta a su vieja amiga.',
    'El puente se construyó hace más de cien años.',
    'Suelo despertarme a las seis en punto.',
    'La maestra explicó la lección con mucha claridad.',
    'Deberíamos salir ahora para evitar el tráfico.',
    'Su auto se averió en la carretera.',
    'El bebé durmió tranquilo toda la noche.',
    'Tengo miedo de las arañas y las serpientes.',
    'El jardín está lleno de flores coloridas.',
    'Ella trabaja desde casa tres días a la semana.',
    'El café está demasiado caliente para beber.',
    'Plantamos un árbol en el patio trasero.',
    'La biblioteca tiene miles de libros antiguos.',
    'Él toca la guitarra en una banda local.',
    'Olvidé enviar el correo esta mañana.',
    'Las montañas están cubiertas de nieve.',
    'Están construyendo una escuela nueva cerca del río.',
    'La batería de mi teléfono se agotó durante la llamada.',
    'El camarero trajo el pedido equivocado.',
    'Ella pintó las paredes de un azul suave.',
    'Tomamos el camino equivocado y nos perdimos.',
    'La panadería huele a pan fresco cada mañana.',
    'Prefiero quedarme en casa y leer esta noche.',
    'El científico descubrió una nueva especie de pez.',
    'Él se disculpó por llegar tan tarde.',
    'El mercado está lleno los sábados por la mañana.',
    'Ella guarda un pequeño cuaderno en su bolso.',
    'El reloj viejo de la pared dejó de funcionar.',
    'Necesitamos reservar los boletos con anticipación.',
    'El río se desbordó después de la fuerte lluvia.',
    'Mis vecinos son muy amables y serviciales.',
    'No puedo encontrar mis lentes en ningún lado.',
    'El concierto fue cancelado a último momento.',
    'Adoptaron un cachorro del refugio.',
    'La receta pide dos tazas de harina.',
    'Él corre cinco kilómetros todas las mañanas.',
    'El cielo se oscureció antes de la tormenta.',
    'Ella sonrió y saludó desde la ventana.',
    'Pasamos toda la tarde en el museo.',
    'El ascensor está descompuesto otra vez.',
    'Prometo llamarte cuando llegue.',
    'El agricultor se despierta antes del amanecer.',
    'Su vuelo aterriza a principios de la noche.',
    'La sala estaba decorada con globos y luces.',
    'No entiendo este problema de matemáticas.',
    'El gato saltó sobre la mesa de la cocina.',
    'Estamos planeando un viaje al campo.',
    'Él cumplió su promesa a pesar de las dificultades.',
    'La tienda cierra temprano los domingos.',
    'Ella tarareaba suavemente mientras cocinaba.',
    'El ingeniero reparó la máquina en una hora.',
    'Mi padre lee el periódico todos los días.',
    'El viento esparció las hojas por la carretera.',
    'Bailaron juntos hasta la medianoche.',
    'Dejé mi abrigo en el autobús esta mañana.',
    'El lago se congela por completo durante el invierno.',
    'Ella siempre lleva un par extra de calcetines.',
    'Podíamos escuchar el mar desde nuestra habitación.',
    'El médico recomendó mucho descanso.',
    'Él susurró la respuesta para que nadie oyera.',
    'El autobús estaba tan lleno que tuve que ir de pie.',
    'Riego las plantas día por medio.',
    'Los niños se rieron del payaso gracioso.',
    'Ella ahorró suficiente dinero para comprar una bicicleta.',
    'El sendero lleva directamente a la cascada.',
    'Celebramos la buena noticia con una cena.',
    'La impresora se quedó sin tinta otra vez.',
    'Aprendió a nadar cuando tenía cinco años.',
    'Las calles estaban vacías a altas horas de la noche.',
    'Siempre tomo té antes de dormir.',
    'El jardinero podó los setos esta mañana.',
];

/// en/pt vêm da suíte fixa do AT-1 (mesmas 100 frases já vetadas — não
/// duplicar corpora); es é a lista hardcoded acima.
Map<Lang, List<String>> _loadSentences(String repoRoot) {
  final suite = p.join(repoRoot, 'docs', 'spikes-android', 'at1-suite');
  List<String> readSuite(String name) => File(p.join(suite, name))
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .toList();
  return {
    Lang.en: readSuite('en.txt'),
    Lang.pt: readSuite('pt.txt'),
    Lang.es: _esSentences,
  };
}

const _voiceOverride = <Lang, String>{
  Lang.en: 'piper-en',
  Lang.pt: 'piper-pt-br',
  Lang.es: 'piper-es',
};

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('uso: dart run tool/at2_gen_fixture.dart <outDir>');
    exit(2);
  }
  final outDir = args[0];
  Directory(outDir).createSync(recursive: true);

  final appData = Platform.environment['APPDATA'] ??
      '${Platform.environment['USERPROFILE']}\\AppData\\Roaming';
  final modelsRoot = '$appData\\omnitranslator\\models';
  final tools = Tools.locate();
  final models = ModelManager(modelsRoot, tools);
  // Assume CWD = packages/dubbing_engine, como os demais scripts de tool/.
  final sentencesByLang = _loadSentences(p.join('..', '..'));

  for (final lang in [Lang.en, Lang.pt, Lang.es]) {
    print('=== ${lang.code} ===');
    final synth = PiperSynthesizer(lang, models,
        voiceOverride: (_voiceOverride[lang]!, 0));
    final sentences = sentencesByLang[lang]!;

    final allSamples = <double>[];
    final groundTruth = <Map<String, dynamic>>[];
    int sampleRate = 22050;

    for (final sentence in sentences) {
      final audio = synth.synthesize(sentence);
      sampleRate = audio.sampleRate;
      final startSec = allSamples.length / sampleRate;
      allSamples.addAll(audio.samples);
      final endSec = allSamples.length / sampleRate;
      groundTruth.add({
        'text': sentence,
        'startMs': (startSec * 1000).round(),
        'endMs': (endSec * 1000).round(),
      });
      final gapSamples = (sampleRate * _gapSec).round();
      allSamples.addAll(Float32List(gapSamples));
    }
    synth.dispose();

    final totalDurSec = allSamples.length / sampleRate;
    print('  ${sentences.length} frases, ${totalDurSec.toStringAsFixed(1)} s');

    final samples = Float32List(allSamples.length);
    for (int i = 0; i < allSamples.length; i++) {
      samples[i] = allSamples[i];
    }
    final rawWav = p.join(outDir, '${lang.code}_raw.wav');
    writeWavPcm16(rawWav, WavData(samples, sampleRate, 1));

    // Downmix para 16 kHz mono PCM16 — mesmo formato de asr_in.wav em produção.
    final finalWav = p.join(outDir, '${lang.code}.wav');
    final r = Process.runSync(tools.ffmpeg, [
      '-y', '-i', rawWav,
      '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le',
      finalWav,
    ]);
    if (r.exitCode != 0) {
      stderr.writeln('ffmpeg falhou para ${lang.code}: ${r.stderr}');
      exit(1);
    }
    File(rawWav).deleteSync();

    File(p.join(outDir, '${lang.code}_ground_truth.json')).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
      'lang': lang.code,
      'sampleRate': 16000,
      'totalDurationSec': totalDurSec,
      'gapSec': _gapSec,
      'sentences': groundTruth,
    }));
    print('  gravado: $finalWav');
  }
  print('OK');
}
