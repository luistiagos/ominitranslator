import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/backends/sherpa_bindings.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';

/// Whisper ONNX (sherpa-onnx) + Silero VAD, in-process via FFI — mesma API
/// provada no device pelo AT-2 (`docs/spikes-android/at2-evidence/
/// at2-bench-main.dart`, PASSOU: RTF 0,138-0,267, 96-99% de sincronia em
/// ±300ms). O VAD segmenta a fala (o `OfflineRecognizer` não devolve
/// timestamps nativos para Whisper — confirmado no AT-2, 0/6 combos), então
/// os segmentos já saem cortados na fala real: ao contrário do
/// `WhisperTranscriber` do desktop, não precisa de `trimSegmentsToSpeechFromFile`.
class AndroidTranscriber implements Transcriber {
  final ModelManager models;
  final Preset preset;

  AndroidTranscriber(this.models, this.preset);

  @override
  Future<List<TranscriptSegment>> transcribe(
      String wav16kMono, Lang sourceLang, CancellationToken token) async {
    ensureSherpaBindings();

    final whisperId = models.catalog.asrModelIds[preset]!;
    final whisperEntry = models.catalog.entryOf(whisperId)!;
    final encoderFile = whisperEntry.expects.firstWhere((f) => f.contains('encoder'));
    final decoderFile = whisperEntry.expects.firstWhere((f) => f.contains('decoder'));
    final tokensFile = whisperEntry.expects.firstWhere((f) => f.contains('tokens'));
    final encoder = models.pathOf(whisperId, encoderFile);
    final decoder = models.pathOf(whisperId, decoderFile);
    final tokens = models.pathOf(whisperId, tokensFile);

    final vadEntry = models.catalog.entryOf('silero-vad')!;
    final vadModel = models.pathOf('silero-vad', vadEntry.expects.first);

    final wave = sherpa.readWave(wav16kMono);
    if (wave.samples.isEmpty) {
      throw PipelineException(PipelineStage.transcribe, 'Falha ao ler o áudio para ASR');
    }

    final recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: encoder,
            decoder: decoder,
            language: sourceLang.whisperCode,
            task: 'transcribe',
            enableSegmentTimestamps: true,
          ),
          tokens: tokens,
          numThreads: 2,
          provider: 'cpu',
          debug: false,
        ),
      ),
    );

    final vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadModel,
          threshold: 0.5,
          minSilenceDuration: 0.4,
          minSpeechDuration: 0.25,
          windowSize: 512,
          maxSpeechDuration: 25.0, // teto de janela do §8/P3.
        ),
        numThreads: 1,
        provider: 'cpu',
      ),
      bufferSizeInSeconds: 30,
    );

    try {
      // Alimenta o VAD em blocos do windowSize (semântica correta do buffer
      // circular — ver AT2.md), coleta os segmentos de fala.
      final speechSegments = <sherpa.SpeechSegment>[];
      const window = 512;
      var pos = 0;
      while (pos + window <= wave.samples.length) {
        if (token.isCancelled) {
          throw PipelineException(PipelineStage.transcribe, 'Cancelado pelo usuário');
        }
        vad.acceptWaveform(wave.samples.sublist(pos, pos + window));
        while (!vad.isEmpty()) {
          speechSegments.add(vad.front());
          vad.pop();
        }
        pos += window;
      }
      vad.flush();
      while (!vad.isEmpty()) {
        speechSegments.add(vad.front());
        vad.pop();
      }

      final segments = <TranscriptSegment>[];
      for (final seg in speechSegments) {
        if (token.isCancelled) {
          throw PipelineException(PipelineStage.transcribe, 'Cancelado pelo usuário');
        }
        final stream = recognizer.createStream();
        stream.acceptWaveform(samples: seg.samples, sampleRate: wave.sampleRate);
        recognizer.decode(stream);
        final result = recognizer.getResult(stream);
        stream.free();

        final text = result.text.trim();
        if (text.isEmpty) continue;
        final startMs = (seg.start / wave.sampleRate * 1000).round();
        final durMs = (seg.samples.length / wave.sampleRate * 1000).round();
        segments.add(TranscriptSegment(
          Duration(milliseconds: startMs),
          Duration(milliseconds: startMs + durMs),
          text,
        ));
      }

      if (segments.isEmpty) {
        throw PipelineException(PipelineStage.transcribe, 'Nenhuma fala detectada no vídeo');
      }
      return segments;
    } finally {
      vad.free();
      recognizer.free();
    }
  }
}
