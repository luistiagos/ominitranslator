// AT-2 spike: Whisper ONNX (sherpa_onnx) + Silero VAD on-device benchmark.
//
// Layout expected under the app-specific external files dir
// (/storage/emulated/0/Android/data/com.luistiagos.at2bench.at2_bench/files),
// pushed via adb before launch:
//   at2/audio/en.wav, pt.wav, es.wav   (16 kHz mono PCM16, ~5 min each)
//   at2/models/whisper-tiny/{tiny-encoder.int8.onnx,tiny-decoder.int8.onnx,tiny-tokens.txt}
//   at2/models/whisper-base/{base-encoder.int8.onnx,base-decoder.int8.onnx,base-tokens.txt}
//   at2/models/silero_vad.onnx
//
// Output (adb pull afterwards):
//   at2/results/<lang>_<preset>.json   -- per-combo segments + timing + memory
//   at2/results/summary.json
//   at2/results/log.txt                -- flushed after each combo

import 'dart:convert';
import 'dart:io';

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

// Assets are adb-pushed here (world-readable, no per-app storage isolation)
// then copied by the app itself into its own external files dir, because
// files written directly by `adb push` (uid shell) into Android/data/<pkg>
// end up owned by shell and are invisible to the app's own FUSE view.
Future<void> _ensureAssetsCopied(String base, void Function(String) status) async {
  const srcRoot = '/data/local/tmp/at2assets';
  final srcDir = Directory(srcRoot);
  if (!srcDir.existsSync()) return;
  status('copiando assets…');
  await for (final entity in srcDir.list(recursive: true)) {
    if (entity is! File) continue;
    final rel = entity.path.substring(srcRoot.length + 1);
    final destFile = File('$base/$rel');
    if (destFile.existsSync() && destFile.lengthSync() == entity.lengthSync()) {
      continue;
    }
    destFile.parent.createSync(recursive: true);
    await entity.copy(destFile.path);
  }
}

Future<void> _runBenchmark(void Function(String) status) async {
  final extDir = await getExternalStorageDirectory();
  if (extDir == null) throw Exception('no external storage dir');
  final base = '${extDir.path}/at2';
  final audioDir = '$base/audio';
  final modelsDir = '$base/models';
  final resultsDir = Directory('$base/results');
  resultsDir.createSync(recursive: true);
  await _ensureAssetsCopied(base, status);
  final log = File('${resultsDir.path}/log.txt').openWrite(mode: FileMode.write);
  Future<void> logLine(String s) async {
    log.writeln('${DateTime.now().toIso8601String()} $s');
    await log.flush();
  }

  status('initBindings…');
  sherpa.initBindings();
  await logLine('vmhwm at start: ${_readVmHwmKb()} KB');

  const langs = ['en', 'pt', 'es'];
  const presets = {'fast': 'tiny', 'best': 'base'};

  final summary = <String, dynamic>{};

  for (final lang in langs) {
    for (final entry in presets.entries) {
      final preset = entry.key;
      final modelName = entry.value; // tiny | base
      final tag = '${lang}_$preset';
      status('rodando $tag…');
      await logLine('=== $tag (whisper-$modelName) ===');

      final wavPath = '$audioDir/$lang.wav';
      if (!File(wavPath).existsSync()) {
        await logLine('SKIP $tag: wav ausente em $wavPath');
        continue;
      }

      final encoder = '$modelsDir/whisper-$modelName/$modelName-encoder.int8.onnx';
      final decoder = '$modelsDir/whisper-$modelName/$modelName-decoder.int8.onnx';
      final tokens = '$modelsDir/whisper-$modelName/$modelName-tokens.txt';
      final vadModel = '$modelsDir/silero_vad.onnx';

      final wave = sherpa.readWave(wavPath);
      if (wave.samples.isEmpty) {
        await logLine('SKIP $tag: falha ao ler wav (samples vazio)');
        continue;
      }
      final audioDurSec = wave.samples.length / wave.sampleRate;
      await logLine('audio: ${wave.sampleRate} Hz, ${audioDurSec.toStringAsFixed(1)} s');

      final numThreads = 2; // max(2, min(4, processors-2)) — moto g86 é octa-core
      final recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            whisper: sherpa.OfflineWhisperModelConfig(
              encoder: encoder,
              decoder: decoder,
              language: lang,
              task: 'transcribe',
              enableSegmentTimestamps: true,
            ),
            tokens: tokens,
            numThreads: numThreads,
            provider: 'cpu',
            debug: false,
          ),
        ),
      );

      final vadConfig = sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadModel,
          threshold: 0.5,
          minSilenceDuration: 0.4,
          minSpeechDuration: 0.25,
          windowSize: 512,
          maxSpeechDuration: 25.0, // teto de janela do §8/P3
        ),
        numThreads: 1,
        provider: 'cpu',
      );
      final vad = sherpa.VoiceActivityDetector(
        config: vadConfig,
        bufferSizeInSeconds: 30,
      );

      final sw = Stopwatch()..start();

      // Alimenta o VAD em blocos do windowSize (semântica correta do buffer
      // circular), coleta os segmentos de fala.
      final segments = <sherpa.SpeechSegment>[];
      const window = 512;
      var pos = 0;
      while (pos + window <= wave.samples.length) {
        vad.acceptWaveform(wave.samples.sublist(pos, pos + window));
        while (!vad.isEmpty()) {
          segments.add(vad.front());
          vad.pop();
        }
        pos += window;
      }
      vad.flush();
      while (!vad.isEmpty()) {
        segments.add(vad.front());
        vad.pop();
      }
      vad.free();

      await logLine('VAD: ${segments.length} segmentos de fala');

      final outSegments = <Map<String, dynamic>>[];
      var lastEndMs = -1;
      var regressions = 0;
      var timestampsNonEmptyCount = 0;
      var emptyTextCount = 0;

      for (final seg in segments) {
        final stream = recognizer.createStream();
        stream.acceptWaveform(samples: seg.samples, sampleRate: wave.sampleRate);
        recognizer.decode(stream);
        final result = recognizer.getResult(stream);
        stream.free();

        final startMs = (seg.start / wave.sampleRate * 1000).round();
        final durMs = (seg.samples.length / wave.sampleRate * 1000).round();
        final endMs = startMs + durMs;
        final text = result.text.trim();

        if (text.isEmpty) emptyTextCount++;
        if (result.timestamps.isNotEmpty) timestampsNonEmptyCount++;
        if (startMs < lastEndMs) regressions++;
        lastEndMs = endMs;

        if (text.isNotEmpty) {
          outSegments.add({
            'startMs': startMs,
            'endMs': endMs,
            'text': text,
            'nativeTimestamps': result.timestamps,
          });
        }
      }

      sw.stop();
      recognizer.free();

      final elapsedSec = sw.elapsedMilliseconds / 1000.0;
      final rtf = audioDurSec > 0 ? elapsedSec / audioDurSec : -1.0;
      final vmHwmKb = _readVmHwmKb();

      final result = {
        'tag': tag,
        'lang': lang,
        'preset': preset,
        'model': modelName,
        'numThreads': numThreads,
        'audioDurationSec': audioDurSec,
        'elapsedSec': elapsedSec,
        'rtf': rtf,
        'vmHwmKbAfterRun': vmHwmKb,
        'vadSegmentCount': segments.length,
        'outputSegmentCount': outSegments.length,
        'emptyTextCount': emptyTextCount,
        'timestampRegressions': regressions,
        'nativeTimestampsNonEmptyCount': timestampsNonEmptyCount,
        'segments': outSegments,
      };
      File('${resultsDir.path}/$tag.json')
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));

      await logLine('$tag: rtf=${rtf.toStringAsFixed(3)} vmhwm=${vmHwmKb}KB '
          'segs=${segments.length} out=${outSegments.length} '
          'empty=$emptyTextCount regress=$regressions '
          'nativeTs=$timestampsNonEmptyCount');

      summary[tag] = {
        'rtf': rtf,
        'vmHwmKbAfterRun': vmHwmKb,
        'outputSegmentCount': outSegments.length,
        'emptyTextCount': emptyTextCount,
        'timestampRegressions': regressions,
        'nativeTimestampsNonEmptyCount': timestampsNonEmptyCount,
      };

      status('$tag OK — rtf=${rtf.toStringAsFixed(2)}');
    }
  }

  summary['finalVmHwmKb'] = _readVmHwmKb();
  File('${resultsDir.path}/summary.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));
  await logLine('=== DONE === finalVmHwm=${summary['finalVmHwmKb']}KB');
  await log.flush();
  await log.close();
  status('DONE — ver at2/results/summary.json');
}
