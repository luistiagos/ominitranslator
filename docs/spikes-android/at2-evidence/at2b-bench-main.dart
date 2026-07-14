// AT-2b spike: Piper TTS (sherpa_onnx OfflineTts, VITS) on-device benchmark.
//
// Layout expected under the app-specific external files dir
// (/storage/emulated/0/Android/data/com.luistiagos.at2bench.at2_bench/files),
// pushed via adb before launch (see docs/spikes-android/AT2.md §11.4):
//   at2b/packages/en.tar.gz, pt.tar.gz, es.tar.gz  -- voice packages
//     (each: <voice>.onnx, <voice>.onnx.json, tokens.txt, espeak-ng-data/)
//
// Output (adb pull afterwards):
//   at2b/results/<lang>.json   -- per-language timing + memory + checks
//   at2b/results/summary.json
//   at2b/results/log.txt

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BenchApp());
}

class BenchApp extends StatefulWidget {
  const BenchApp({super.key});
  @override
  State<BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<BenchApp> {
  String _status = 'starting…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      await _runBenchmark((s) => setState(() => _status = s));
    } catch (e, st) {
      setState(() => _status = 'FATAL: $e\n$st');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_status, style: const TextStyle(fontSize: 14)),
            ),
          ),
        ),
      );
}

int _readVmHwmKb() {
  try {
    final text = File('/proc/self/status').readAsStringSync();
    for (final line in text.split('\n')) {
      if (line.startsWith('VmHWM:')) {
        final m = RegExp(r'(\d+)').firstMatch(line);
        if (m != null) return int.parse(m.group(1)!);
      }
    }
  } catch (_) {}
  return -1;
}

const Map<String, List<String>> _sentences = {
  'en': [
    'The weather is beautiful today.',
    'I would like a cup of coffee.',
    'The train leaves at seven in the morning.',
    'She bought three books yesterday.',
    'We are going to the beach this weekend.',
    'My brother works at a hospital downtown.',
    'Could you tell me where the station is?',
    'The children are playing in the garden.',
    'I have never been to Portugal before.',
    'He forgot his umbrella at the office.',
    'This restaurant serves the best pizza in town.',
    'Please turn off the lights before you leave.',
    'The meeting was postponed until next Thursday.',
    'Their new house has a large kitchen.',
    'I need to buy some milk and bread.',
    'The movie starts in twenty minutes.',
    'She speaks four languages fluently.',
    'We watched the sunset from the hilltop.',
    'The dog barked all night long.',
    'My grandmother taught me how to cook.',
  ],
  'pt': [
    'O tempo está lindo hoje.',
    'Eu gostaria de uma xícara de café.',
    'O trem sai às sete da manhã.',
    'Ela comprou três livros ontem.',
    'Vamos à praia neste fim de semana.',
    'Meu irmão trabalha num hospital no centro.',
    'Você poderia me dizer onde fica a estação?',
    'As crianças estão brincando no jardim.',
    'Eu nunca estive em Portugal antes.',
    'Ele esqueceu o guarda-chuva no escritório.',
    'Este restaurante serve a melhor pizza da cidade.',
    'Por favor, apague as luzes antes de sair.',
    'A reunião foi adiada para a próxima quinta-feira.',
    'A casa nova deles tem uma cozinha grande.',
    'Preciso comprar leite e pão.',
    'O filme começa em vinte minutos.',
    'Ela fala quatro idiomas fluentemente.',
    'Assistimos ao pôr do sol do alto do morro.',
    'O cachorro latiu a noite inteira.',
    'Minha avó me ensinou a cozinhar.',
  ],
  'es': [
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
  ],
};

/// Downmixa float32 [-1,1] a mono PCM16, reamostrando por interpolação
/// linear para [targetRate] — não é o resampler de produção (esse é
/// FFmpegKitNext, AT-3, ainda não construído), só valida que a saída do
/// TTS sobrevive ao round-trip para o formato final (§11.4).
Int16List _resampleToPcm16(Float32List samples, int srcRate, int targetRate) {
  final outLen = (samples.length * targetRate / srcRate).round();
  final out = Int16List(outLen);
  for (var i = 0; i < outLen; i++) {
    final srcPos = i * srcRate / targetRate;
    final i0 = srcPos.floor().clamp(0, samples.length - 1);
    final i1 = (i0 + 1).clamp(0, samples.length - 1);
    final frac = srcPos - i0;
    final v = samples[i0] * (1 - frac) + samples[i1] * frac;
    out[i] = (v.clamp(-1.0, 1.0) * 32767).round();
  }
  return out;
}

void _writeWavPcm16Mono(String path, Int16List pcm, int sampleRate) {
  final byteRate = sampleRate * 2;
  final dataLen = pcm.length * 2;
  final header = ByteData(44);
  void s(int off, String v) {
    for (var i = 0; i < v.length; i++) {
      header.setUint8(off + i, v.codeUnitAt(i));
    }
  }
  s(0, 'RIFF');
  header.setUint32(4, 36 + dataLen, Endian.little);
  s(8, 'WAVE');
  s(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little); // PCM
  header.setUint16(22, 1, Endian.little); // mono
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, 2, Endian.little); // block align
  header.setUint16(34, 16, Endian.little); // bits/sample
  s(36, 'data');
  header.setUint32(40, dataLen, Endian.little);

  final f = File(path).openSync(mode: FileMode.write);
  f.writeFromSync(header.buffer.asUint8List());
  f.writeFromSync(pcm.buffer.asUint8List());
  f.closeSync();
}

/// Lê só o suficiente do header pra confirmar formato/duração — reabertura
/// bem-sucedida é o que o critério pede, não um parser completo.
Map<String, dynamic> _reopenWavPcm16Mono(String path) {
  final bytes = File(path).readAsBytesSync();
  final bd = ByteData.sublistView(bytes);
  final riff = String.fromCharCodes(bytes.sublist(0, 4));
  final wave = String.fromCharCodes(bytes.sublist(8, 12));
  final sampleRate = bd.getUint32(24, Endian.little);
  final numChannels = bd.getUint16(22, Endian.little);
  final bitsPerSample = bd.getUint16(34, Endian.little);
  final dataLen = bd.getUint32(40, Endian.little);
  return {
    'ok': riff == 'RIFF' && wave == 'WAVE' && numChannels == 1 && bitsPerSample == 16,
    'sampleRate': sampleRate,
    'numChannels': numChannels,
    'bitsPerSample': bitsPerSample,
    'durationSec': dataLen / 2 / sampleRate,
  };
}

Future<void> _runBenchmark(void Function(String) status) async {
  final extDir = await getExternalStorageDirectory();
  if (extDir == null) throw Exception('no external storage dir');
  final base = '${extDir.path}/at2b';
  // <lang>.tar.gz pushed here via adb (world-readable, no per-app storage
  // isolation — see docs/decisoes.md 2026-07-14 sobre o gotcha do adb push).
  const pkgDir = '/data/local/tmp/at2b_packages';
  final voicesDir = '$base/voices'; // extracted here by this app (app-owned)
  final resultsDir = Directory('$base/results');
  resultsDir.createSync(recursive: true);
  final log = File('${resultsDir.path}/log.txt').openWrite(mode: FileMode.write);
  Future<void> logLine(String s) async {
    log.writeln('${DateTime.now().toIso8601String()} $s');
    await log.flush();
  }

  status('initBindings…');
  sherpa.initBindings();
  await logLine('vmhwm at start: ${_readVmHwmKb()} KB');

  const langs = ['en', 'pt', 'es'];
  final summary = <String, dynamic>{};

  for (final lang in langs) {
    status('extraindo pacote $lang…');
    await logLine('=== $lang ===');

    final tarGzPath = '$pkgDir/$lang.tar.gz';
    if (!File(tarGzPath).existsSync()) {
      await logLine('SKIP $lang: pacote ausente em $tarGzPath');
      continue;
    }
    final langVoiceDir = Directory('$voicesDir/$lang');
    langVoiceDir.createSync(recursive: true);

    final extractSw = Stopwatch()..start();
    final bytes = File(tarGzPath).readAsBytesSync();
    final tarBytes = GZipDecoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(tarBytes);
    for (final entry in archive) {
      final outPath = '${langVoiceDir.path}/${entry.name}';
      if (entry.isFile) {
        File(outPath).parent.createSync(recursive: true);
        File(outPath).writeAsBytesSync(entry.content as List<int>);
      } else {
        Directory(outPath).createSync(recursive: true);
      }
    }
    extractSw.stop();
    final extractSec = extractSw.elapsedMilliseconds / 1000.0;
    await logLine('extração: ${extractSec.toStringAsFixed(2)} s '
        '(${archive.length} entradas, ${(bytes.length / 1e6).toStringAsFixed(1)} MB compactado)');

    final onnxFiles = Directory(langVoiceDir.path)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.onnx'))
        .toList();
    if (onnxFiles.isEmpty) {
      await logLine('SKIP $lang: nenhum .onnx extraído');
      continue;
    }
    final modelPath = onnxFiles.first.path;
    final tokensPath = '${langVoiceDir.path}/tokens.txt';
    final dataDirPath = '${langVoiceDir.path}/espeak-ng-data';

    status('carregando OfflineTts $lang…');
    final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: modelPath,
          tokens: tokensPath,
          dataDir: dataDirPath,
          noiseScale: 0.667,
          noiseScaleW: 0.8,
          lengthScale: 1.0,
        ),
        numThreads: 2,
        provider: 'cpu',
        debug: false,
      ),
    ));
    final nativeSampleRate = tts.sampleRate;
    // Capturado agora, não reusado depois do teste de cancelamento: esse
    // teste chama tts.free(), e o getter em cima de um ponteiro nulo
    // silenciosamente devolve 0 em vez de lançar.
    final numSpeakers = tts.numSpeakers;
    await logLine('OfflineTts carregado: nativeSampleRate=$nativeSampleRate '
        'numSpeakers=$numSpeakers');

    final sentences = _sentences[lang]!;
    status('sintetizando $lang (${sentences.length} frases)…');

    final sw = Stopwatch()..start();
    var totalAudioSamples = 0;
    var emptyCount = 0;
    Float32List? lastAudio;
    for (final text in sentences) {
      final audio = tts.generate(text: text, sid: 0, speed: 1.0);
      if (audio.samples.isEmpty) {
        emptyCount++;
      } else {
        totalAudioSamples += audio.samples.length;
        lastAudio = audio.samples;
      }
    }
    sw.stop();
    final elapsedSec = sw.elapsedMilliseconds / 1000.0;
    final audioDurSec = totalAudioSamples / nativeSampleRate;
    final rtf = audioDurSec > 0 ? elapsedSec / audioDurSec : -1.0;
    final vmHwmKb = _readVmHwmKb();

    await logLine('$lang: rtf=${rtf.toStringAsFixed(3)} elapsed=${elapsedSec.toStringAsFixed(1)}s '
        'audioDur=${audioDurSec.toStringAsFixed(1)}s vmhwm=${vmHwmKb}KB empty=$emptyCount');

    // Reamostragem para PCM16 mono 44,1 kHz + reabertura (§11.4).
    Map<String, dynamic> reopenCheck = {'ok': false};
    if (lastAudio != null) {
      final pcm = _resampleToPcm16(lastAudio, nativeSampleRate, 44100);
      final wavPath = '${resultsDir.path}/${lang}_last_44k.wav';
      _writeWavPcm16Mono(wavPath, pcm, 44100);
      reopenCheck = _reopenWavPcm16Mono(wavPath);
      await logLine('reamostragem+reabertura: $reopenCheck');
    }

    // Cancelamento entre segmentos: interrompe no meio de um lote, libera o
    // OfflineTts, cria outro em seguida — sem exceção/crash = sem sessão órfã.
    status('testando cancelamento $lang…');
    var cancelledAfter = -1;
    var cancelOk = false;
    try {
      var cancelled = false;
      for (var i = 0; i < sentences.length; i++) {
        if (cancelled) break;
        tts.generate(text: sentences[i], sid: 0, speed: 1.0);
        if (i == sentences.length ~/ 2) {
          cancelled = true;
          cancelledAfter = i + 1;
        }
      }
      tts.free();
      final tts2 = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: modelPath,
            tokens: tokensPath,
            dataDir: dataDirPath,
          ),
          numThreads: 1,
          provider: 'cpu',
        ),
      ));
      final probe = tts2.generate(text: sentences.first, sid: 0, speed: 1.0);
      cancelOk = probe.samples.isNotEmpty;
      tts2.free();
    } catch (e) {
      cancelOk = false;
      await logLine('cancelamento FALHOU: $e');
    }
    await logLine('cancelamento: parou em $cancelledAfter/${sentences.length}, '
        'reinstanciação após free() ok=$cancelOk');

    final result = {
      'lang': lang,
      'extractSec': extractSec,
      'packageBytes': bytes.length,
      'packageEntries': archive.length,
      'nativeSampleRate': nativeSampleRate,
      'numSpeakers': numSpeakers,
      'sentenceCount': sentences.length,
      'emptyCount': emptyCount,
      'elapsedSec': elapsedSec,
      'audioDurationSec': audioDurSec,
      'rtf': rtf,
      'vmHwmKbAfterRun': vmHwmKb,
      'resample44kReopen': reopenCheck,
      'cancelledAfter': cancelledAfter,
      'cancelReinstantiateOk': cancelOk,
    };
    File('${resultsDir.path}/$lang.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
    summary[lang] = {
      'extractSec': extractSec,
      'rtf': rtf,
      'vmHwmKbAfterRun': vmHwmKb,
      'resample44kReopenOk': reopenCheck['ok'],
      'cancelReinstantiateOk': cancelOk,
    };

    status('$lang OK — rtf=${rtf.toStringAsFixed(2)} extract=${extractSec.toStringAsFixed(1)}s');
  }

  summary['finalVmHwmKb'] = _readVmHwmKb();
  File('${resultsDir.path}/summary.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));
  await logLine('=== DONE === finalVmHwm=${summary['finalVmHwmKb']}KB');
  await log.flush();
  await log.close();
  status('DONE — ver at2b/results/summary.json');
}
