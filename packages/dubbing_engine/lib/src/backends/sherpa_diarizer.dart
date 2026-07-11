import 'dart:math' as math;
import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/backends/sherpa_bindings.dart';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/steps/gender_detect.dart';
import 'package:dubbing_engine/src/steps/speaker_assign.dart';
import 'package:dubbing_engine/src/wav.dart';

class SherpaDiarizer implements Diarizer {
  final ModelManager models;

  /// Número de falantes conhecido (clustering determinístico), ou null
  /// para detecção automática por threshold.
  final int? numClusters;
  SherpaDiarizer(this.models, {this.numClusters});

  @override
  Future<DiarizationResult> diarize(
      String wav16kMonoPath, CancellationToken token) async {
    ensureSherpaBindings();
    final segEntry = ModelManager.manifest
        .firstWhere((e) => e.id == diarizationSegmentationModelId);
    final embEntry = ModelManager.manifest
        .firstWhere((e) => e.id == diarizationEmbeddingModelId);
    final segmentationModel =
        models.pathOf(diarizationSegmentationModelId, segEntry.expects.first);
    final embeddingModel =
        models.pathOf(diarizationEmbeddingModelId, embEntry.expects.first);
    final diarizer = sherpa.OfflineSpeakerDiarization(
      sherpa.OfflineSpeakerDiarizationConfig(
        segmentation: sherpa.OfflineSpeakerSegmentationModelConfig(
          pyannote: sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(
              model: segmentationModel),
          numThreads: 2,
          debug: false,
        ),
        embedding: sherpa.SpeakerEmbeddingExtractorConfig(
          model: embeddingModel,
          numThreads: 2,
          debug: false,
        ),
        clustering: sherpa.FastClusteringConfig(
          numClusters: numClusters ?? -1,
          threshold: diarizationThreshold,
        ),
      ),
    );
    try {
      final wav = readWav(wav16kMonoPath);
      if (wav.sampleRate != diarizer.sampleRate) {
        throw PipelineException(PipelineStage.diarize,
            'Áudio para diarização deve estar a ${diarizer.sampleRate} Hz '
            '(recebido ${wav.sampleRate} Hz)');
      }
      final samples =
          wav.channels == 1 ? wav.samples : stereoToMono(wav.samples);
      final result = diarizer.processWithCallback(
        samples: samples,
        // Retornar != 0 aborta o processamento nativo.
        callback: (_, __) => token.isCancelled ? 1 : 0,
      );
      if (token.isCancelled) {
        throw PipelineException(PipelineStage.diarize, 'Cancelado pelo usuário');
      }
      // Poda clusters fantasma ANTES de medir os perfis: o áudio de um
      // cluster de ruído contamina a detecção de sexo.
      final turns = pruneMinorSpeakers(
          result.map((s) => SpeakerTurn(s.start, s.end, s.speaker)).toList());
      // Pitch como base; audio tagging (quando instalado) sobrescreve —
      // é muito mais robusto a fala enfática e música de fundo.
      var profiles = detectSpeakerProfiles(samples, wav.sampleRate, turns);
      if (models.stateOf(genderTaggingModelId) == ModelState.ready) {
        profiles = _profilesByTagging(samples, wav.sampleRate, turns, profiles);
      }
      return DiarizationResult(turns, profiles);
    } finally {
      diarizer.free();
    }
  }

  /// Classifica sexo/idade de cada falante com o modelo de audio tagging
  /// (classes AudioSet "Male/Female/Child speech"), alimentado com os
  /// turnos mais longos do falante. [pitchProfiles] é o fallback quando a
  /// pontuação do tagging é fraca demais.
  Map<int, SpeakerProfile> _profilesByTagging(
    Float32List samples,
    int sampleRate,
    List<SpeakerTurn> turns,
    Map<int, SpeakerProfile> pitchProfiles,
  ) {
    final tagger = sherpa.AudioTagging(
      config: sherpa.AudioTaggingConfig(
        model: sherpa.AudioTaggingModelConfig(
          ced: models.pathOf(genderTaggingModelId, 'model.int8.onnx'),
          numThreads: 2,
          debug: false,
        ),
        labels: models.pathOf(genderTaggingModelId, 'class_labels_indices.csv'),
      ),
    );
    try {
      final bySpeaker = <int, List<SpeakerTurn>>{};
      for (final turn in turns) {
        bySpeaker.putIfAbsent(turn.speaker, () => []).add(turn);
      }
      final result = <int, SpeakerProfile>{};
      for (final entry in bySpeaker.entries) {
        final spkTurns = entry.value.toList()
          ..sort((a, b) => b.duration.compareTo(a.duration));
        final scores = <String, double>{};
        for (final turn in spkTurns.take(genderTaggingMaxTurns)) {
          final start = (turn.start * sampleRate).round();
          final maxEnd = turn.start + genderTaggingMaxSecondsPerTurn;
          final end = math.min(
              ((turn.end < maxEnd ? turn.end : maxEnd) * sampleRate).round(),
              samples.length);
          if (end <= start) continue;
          final stream = tagger.createStream();
          stream.acceptWaveform(
              samples: Float32List.sublistView(samples, start, end),
              sampleRate: sampleRate);
          final events = tagger.compute(stream: stream, topK: 8);
          stream.free();
          for (final e in events) {
            scores[e.name] = (scores[e.name] ?? 0) + e.prob;
          }
        }
        result[entry.key] = profileFromTagScores(scores,
            fallback: pitchProfiles[entry.key] ?? SpeakerProfile.unknown);
      }
      return result;
    } finally {
      tagger.free();
    }
  }
}
