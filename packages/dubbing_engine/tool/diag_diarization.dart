// Diagnóstico de diarização/gênero/vozes sobre um WAV 16 kHz mono.
// Run: dart run tool/diag_diarization.dart <diar_in.wav> [numClusters] [pitchWav]
// pitchWav: WAV alternativo (ex.: vocals separados) para medir o F0 usando
// os MESMOS turnos detectados no primeiro WAV.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:dubbing_engine/dubbing_engine.dart';
import 'package:dubbing_engine/src/backends/piper_synthesizer.dart';
import 'package:dubbing_engine/src/backends/sherpa_bindings.dart';
import 'package:dubbing_engine/src/backends/sherpa_diarizer.dart';
import 'package:dubbing_engine/src/steps/gender_detect.dart';
import 'package:dubbing_engine/src/steps/speaker_assign.dart';

Future<void> main(List<String> argv) async {
  final wavPath = argv[0];
  final numClusters = argv.length > 1 ? int.parse(argv[1]) : -1;
  ensureSherpaBindings();
  final appData = Platform.environment['APPDATA']!;
  final modelsRoot = '$appData\\omnitranslator\\models';

  final diarizer = sherpa.OfflineSpeakerDiarization(
    sherpa.OfflineSpeakerDiarizationConfig(
      segmentation: sherpa.OfflineSpeakerSegmentationModelConfig(
        pyannote: sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(
            model: '$modelsRoot\\diarization-segmentation\\model.onnx'),
        numThreads: 2,
        debug: false,
      ),
      embedding: sherpa.SpeakerEmbeddingExtractorConfig(
        model: '$modelsRoot\\diarization-embedding\\nemo_en_titanet_small.onnx',
        numThreads: 2,
        debug: false,
      ),
      clustering: sherpa.FastClusteringConfig(
        numClusters: numClusters,
        threshold: diarizationThreshold,
      ),
    ),
  );

  final wav = readWav(wavPath);
  final samples = wav.channels == 1 ? wav.samples : stereoToMono(wav.samples);
  print('audio: ${samples.length / wav.sampleRate}s @ ${wav.sampleRate}Hz, '
      'numClusters=$numClusters, threshold=$diarizationThreshold');

  final raw = diarizer.process(samples: samples);
  diarizer.free();

  print('\n--- turnos BRUTOS (${raw.length}) ---');
  for (final s in raw) {
    print('  ${s.start.toStringAsFixed(1)}-${s.end.toStringAsFixed(1)}s  spk${s.speaker}');
  }

  final turns = raw.map((s) => SpeakerTurn(s.start, s.end, s.speaker)).toList();
  final pruned = pruneMinorSpeakers(turns);

  final airtime = <int, double>{};
  for (final t in pruned) {
    airtime[t.speaker] = (airtime[t.speaker] ?? 0) + t.duration;
  }
  print('\n--- após poda: airtime por falante ---');
  airtime.forEach((spk, s) => print('  spk$spk: ${s.toStringAsFixed(1)}s'));

  var pitchSamples = samples;
  var pitchRate = wav.sampleRate;
  if (argv.length > 2) {
    final pitchWav = readWav(argv[2]);
    pitchSamples = pitchWav.channels == 1
        ? pitchWav.samples
        : stereoToMono(pitchWav.samples);
    pitchRate = pitchWav.sampleRate;
    print('\n(pitch medido em ${argv[2]})');
  }

  print('\n--- F0 mediano e perfil por falante ---');
  final profiles = detectSpeakerProfiles(pitchSamples, pitchRate, pruned);
  for (final spk in airtime.keys) {
    final f0 = _medianF0(pitchSamples, pitchRate, pruned.where((t) => t.speaker == spk).toList());
    print('  spk$spk: F0=${f0?.toStringAsFixed(1) ?? "null"} Hz → ${profiles[spk]}');
  }

  // Classificação por audio tagging (AudioSet: Male/Female/Child speech),
  // como alternativa ao pitch — validação com o modelo ced-tiny local.
  final cedModel = Platform.environment['DIAG_CED_MODEL'];
  if (cedModel != null) {
    print('\n--- audio tagging (ced-tiny) por falante ---');
    final tagger = sherpa.AudioTagging(
      config: sherpa.AudioTaggingConfig(
        model: sherpa.AudioTaggingModelConfig(
          ced: '$cedModel\\model.int8.onnx',
          numThreads: 2,
          debug: false,
        ),
        labels: '$cedModel\\class_labels_indices.csv',
      ),
    );
    for (final spk in airtime.keys) {
      final spkTurns = pruned.where((t) => t.speaker == spk).toList()
        ..sort((a, b) => b.duration.compareTo(a.duration));
      // Usa os 3 turnos mais longos (até ~10s cada) do áudio ORIGINAL.
      final scores = <String, double>{};
      for (final turn in spkTurns.take(3)) {
        final start = (turn.start * wav.sampleRate).round();
        final end = math.min(
            ((turn.end < turn.start + 10 ? turn.end : turn.start + 10) *
                    wav.sampleRate)
                .round(),
            samples.length);
        if (end <= start) continue;
        final stream = tagger.createStream();
        stream.acceptWaveform(
            samples: Float32List.sublistView(samples, start, end),
            sampleRate: wav.sampleRate);
        final events = tagger.compute(stream: stream, topK: 8);
        stream.free();
        for (final e in events) {
          scores[e.name] = (scores[e.name] ?? 0) + e.prob;
        }
      }
      final top = scores.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      print('  spk$spk: ${top.take(5).map((e) => '${e.key}=${e.value.toStringAsFixed(2)}').join(', ')}');
    }
    tagger.free();
  }

  // Caminho de PRODUÇÃO: SherpaDiarizer de ponta a ponta (inclui poda e
  // audio tagging quando o modelo gender-tagging está instalado).
  print('\n--- SherpaDiarizer end-to-end (produção) ---');
  final dummyTools = Tools(
    ffmpeg: 'ffmpeg',
    ffprobe: 'ffprobe',
    whisperCli: 'whisper-cli',
    translateLocally: 'translateLocally',
    sherpaSourceSeparation: 'sherpa-separation',
  );
  final manager = ModelManager(modelsRoot, dummyTools);
  final prodDiarizer = SherpaDiarizer(manager,
      numClusters: numClusters > 0 ? numClusters : null);
  final prod = await prodDiarizer.diarize(wavPath, CancellationToken());
  final prodProfiles = prod.profiles;
  prodProfiles.forEach((spk, p) => print('  spk$spk → $p'));

  // Simula a escolha de vozes para pt-BR (banco: faber M, dii F, edresson M).
  final rank = rankSpeakersByAirtime(prod.turns);
  final renumbered = {for (final e in prodProfiles.entries) rank[e.key] ?? 0: e.value};
  final slotGenders = [VoiceGender.male, VoiceGender.female, VoiceGender.male];
  const slotNames = ['faber(M)', 'dii(F)', 'edresson(M)'];
  final voices = assignVoicesToSpeakers(renumbered, slotGenders);
  print('\n--- vozes (banco pt-BR) ---');
  voices.forEach((spk, slot) =>
      print('  falante $spk (${renumbered[spk]}) → ${slotNames[slot]}'));
}

double? _medianF0(Float32List samples, int sampleRate, List<SpeakerTurn> turns) {
  final frameLen = sampleRate * 40 ~/ 1000;
  final hopLen = sampleRate * 20 ~/ 1000;
  final f0s = <double>[];
  final f0sGlobalMax = <double>[];
  for (final turn in turns) {
    final start = (turn.start * sampleRate).round();
    final end = math.min((turn.end * sampleRate).round(), samples.length);
    for (int pos = start; pos + frameLen <= end; pos += hopLen) {
      final frame = Float32List.sublistView(samples, pos, pos + frameLen);
      final f0 = estimateFrameF0(frame, sampleRate);
      if (f0 != null) f0s.add(f0);
      final g = _globalMaxF0(frame, sampleRate);
      if (g != null) f0sGlobalMax.add(g);
    }
  }
  if (f0sGlobalMax.length >= 10) {
    f0sGlobalMax.sort();
    print('    [comparação] globalMax: '
        '${f0sGlobalMax[f0sGlobalMax.length ~/ 2].toStringAsFixed(1)} Hz '
        '(${f0sGlobalMax.length} frames)');
  }
  if (f0s.length < 10) return null;
  f0s.sort();
  return f0s[f0s.length ~/ 2];
}

/// Variante do estimador usando o máximo global da autocorrelação (o
/// comportamento antigo), para comparação com o "primeiro pico forte".
double? _globalMaxF0(Float32List frame, int sampleRate) {
  final n = frame.length;
  double mean = 0;
  for (final s in frame) {
    mean += s;
  }
  mean /= n;
  final centered = Float32List(n);
  double energy = 0;
  for (int i = 0; i < n; i++) {
    centered[i] = frame[i] - mean;
    energy += centered[i] * centered[i];
  }
  final rms = math.sqrt(energy / n);
  if (rms < 0.01 || energy == 0) return null;
  final minLag = (sampleRate / 350).floor();
  final maxLag = (sampleRate / 60).ceil();
  if (maxLag >= n) return null;
  double bestValue = 0;
  int bestLag = 0;
  for (int lag = minLag; lag <= maxLag; lag++) {
    double sum = 0;
    for (int i = 0; i + lag < n; i++) {
      sum += centered[i] * centered[i + lag];
    }
    final v = sum / energy;
    if (v > bestValue) {
      bestValue = v;
      bestLag = lag;
    }
  }
  if (bestLag == 0 || bestValue < 0.5) return null;
  return sampleRate / bestLag;
}
