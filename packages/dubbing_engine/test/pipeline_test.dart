import 'dart:io';
import 'dart:typed_data';
import 'package:dubbing_engine/src/wav.dart';
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/backends/youtube_downloader.dart';
import 'package:dubbing_engine/src/pipeline.dart';
import 'package:dubbing_engine/src/runtime/disk_space_probe.dart';
import 'package:dubbing_engine/src/runtime/dubbing_runtime.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ToolResult _okResult([String stdout = '']) => ToolResult(0, stdout, '');
// Evita que os testes dependam do espaço livre real do disco da máquina.
const _ampleFreeBytes = 999 * 1024 * 1024 * 1024;

class _MockSeparator implements Separator {
  final bool available;
  final String failureReason;
  final SeparationFailureReason reason;
  _MockSeparator(this.available,
      {this.failureReason = 'mock: separação indisponível',
      this.reason = SeparationFailureReason.toolFailed});
  @override
  Future<SeparationOutcome> separate(
      String inputWav, String workDir, CancellationToken token) async {
    if (!available) {
      return SeparationOutcome.failure(reason, detail: failureReason);
    }
    final vocals = p.join(workDir, 'vocals.wav');
    final accomp = p.join(workDir, 'accompaniment.wav');
    File(vocals).writeAsBytesSync(List.filled(100, 0));
    File(accomp).writeAsBytesSync(List.filled(100, 0));
    return SeparationOutcome.success((vocalsWav: vocals, accompanimentWav: accomp));
  }
}

class _MockTranscriber implements Transcriber {
  @override
  Future<List<TranscriptSegment>> transcribe(
      String wav16kMono, Lang sourceLang, CancellationToken token) async {
    return [
      TranscriptSegment(Duration.zero, Duration(milliseconds: 500), 'Hello world.'),
      TranscriptSegment(Duration(milliseconds: 600), Duration(milliseconds: 1000), 'How are you?'),
    ];
  }
}

class _MockTranslator implements Translator {
  @override
  Future<List<String>> translate(
      List<String> sentences, Lang from, Lang to, CancellationToken token) async {
    return sentences.map((s) => s == 'Hello world.' ? 'Olá mundo.' : 'Como vai você?').toList();
  }
}

class _MockSynthesizer implements Synthesizer {
  final List<int> speakersUsed = [];
  Map<int, SpeakerProfile>? profilesReceived;
  @override
  ({Float32List samples, int sampleRate}) synthesize(String text,
      {double speed = 1.0, int speaker = 0}) {
    speakersUsed.add(speaker);
    return (samples: Float32List(100), sampleRate: 22050);
  }

  @override
  void configureSpeakerVoices(Map<int, SpeakerProfile> speakerProfiles) {
    profilesReceived = speakerProfiles;
  }

  @override
  void dispose() {}
}

class _MockDiarizer implements Diarizer {
  final List<SpeakerTurn> turns;
  final Map<int, SpeakerProfile> profiles;
  _MockDiarizer(this.turns, {this.profiles = const {}});
  @override
  Future<DiarizationResult> diarize(String wav16kMonoPath, CancellationToken token) async {
    return DiarizationResult(turns, profiles);
  }
}

final _dummyTools = Tools(
  ffmpeg: 'ffmpeg',
  ffprobe: 'ffprobe',
  whisperCli: 'whisper-cli',
  translateLocally: 'translateLocally',
  sherpaSourceSeparation: 'sherpa-separation',
);

/// Runtime de teste: backends mockados por padrão, cada peça sobrescrevível.
/// Substitui as cinco factories soltas que `runDubbingJob` recebia antes —
/// agora existe um único ponto de injeção.
DubbingRuntime _runtime(
  ModelManager models, {
  Tools? tools,
  RunToolFn? runToolOverride,
  DiskSpaceProbe? diskSpace,
  SeparatorFactory? createSeparator,
  DiarizerFactory? createDiarizer,
  TranscriberFactory? createTranscriber,
  TranslatorFactory? createTranslator,
  SynthesizerFactory? createSynthesizer,
  bool withDownloader = true,
}) {
  final t = tools ?? _dummyTools;
  return DubbingRuntime(
    models: models,
    tools: t,
    runTool: runToolOverride ?? runTool,
    diskSpace: diskSpace ?? const FixedDiskSpaceProbe(_ampleFreeBytes),
    createSeparator: createSeparator ?? () => _MockSeparator(true),
    // Nulo por padrão: sem diarizer, a dublagem é de voz única (é também como
    // o Android M1 expressa a ausência de diarização).
    createDiarizer: createDiarizer,
    createTranscriber: createTranscriber ?? (_) => _MockTranscriber(),
    createTranslator: createTranslator ?? () => _MockTranslator(),
    createSynthesizer: createSynthesizer ??
        (_, {String? voiceModelId, int voiceSid = 0}) => _MockSynthesizer(),
    createDownloader: withDownloader
        ? () => YoutubeDownloader(t, runToolOverride: runToolOverride)
        : null,
  );
}

void main() {
  group('runDubbingJob', () {
    test('throws when required models are missing', () async {
      final tempDir = Directory.systemTemp.createTempSync('pipeline_test_');
      try {
        final models = ModelManager(tempDir.path, _dummyTools);
        final config = DubbingJobConfig(
          inputVideo: p.join(tempDir.path, 'input.mp4'),
          sourceLang: Lang.en,
          targetLang: Lang.pt,
          preset: Preset.best,
          workDir: p.join(tempDir.path, 'work'),
          outputPath: p.join(tempDir.path, 'out.mp4'),
        );
        File(config.inputVideo).writeAsBytesSync(List.filled(100, 0));

        PipelineException? error;
        final events = await runDubbingJob(config, CancellationToken(),
                runtime: _runtime(models))
            .handleError((e) {
              if (e is PipelineException) error = e;
            }).toList();

        expect(error, isNotNull);
        expect(error!.message, contains('Modelos necessários'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('a catalog without a separator does not require the separation model', () async {
      final tempDir = Directory.systemTemp.createTempSync('pipeline_nosep_');
      try {
        // Catálogo estilo Android M1: voice-over puro, sem spleeter. O prepare
        // não pode exigir um modelo que a plataforma nem usa — antes ele pedia
        // 'spleeter-2stems-fp16' hardcoded e o job morreria aqui.
        final catalog = ModelCatalog(
          platform: ModelPlatform.android,
          entries: ModelCatalog.windows().entries,
          asrModelIds: const {Preset.best: 'whisper-small-q5_1'},
          defaultVoiceIds: const {Lang.pt: 'piper-pt-br'},
        );
        final models = ModelManager(tempDir.path, _dummyTools, catalog: catalog);
        _prepareReadyModel(tempDir.path, 'whisper-small-q5_1', 'ggml-small-q5_1.bin');
        _prepareReadyModel(tempDir.path, 'piper-pt-br', 'pt_BR-faber-medium.onnx',
            extraFiles: ['tokens.txt'], extraDirs: ['espeak-ng-data']);
        // spleeter propositalmente AUSENTE.

        final config = DubbingJobConfig(
          inputVideo: p.join(tempDir.path, 'input.mp4'),
          sourceLang: Lang.en,
          targetLang: Lang.pt,
          preset: Preset.best,
          generateSrt: false,
          workDir: p.join(tempDir.path, 'work'),
          outputPath: p.join(tempDir.path, 'out.mp4'),
        );
        File(config.inputVideo).writeAsBytesSync(List.filled(100, 0));
        Directory(config.workDir).createSync(recursive: true);
        File(p.join(config.workDir, 'audio_full.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(config.workDir, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(config.workDir, 'dubbed.wav')).writeAsBytesSync(List.filled(100, 0));
        File(config.outputPath).writeAsBytesSync(List.filled(100, 0));

        final RunToolFn runToolMock = (
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          if (exePath == 'ffprobe') return _okResult('5.0\n');
          return _okResult();
        };

        PipelineException? error;
        await runDubbingJob(config, CancellationToken(),
                runtime: _runtime(models,
                    runToolOverride: runToolMock,
                    createSeparator: () => _MockSeparator(false,
                        reason: SeparationFailureReason.notSupportedOnPlatform)))
            .handleError((e) {
              if (e is PipelineException) error = e;
            }).toList();

        expect(error, isNull,
            reason: 'prepare must not demand a model the platform never uses');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('a runtime without a downloader refuses a remote URL instead of crashing', () async {
      final tempDir = Directory.systemTemp.createTempSync('pipeline_nodl_');
      try {
        final models = ModelManager(tempDir.path, _dummyTools);
        _prepareReadyModel(tempDir.path, 'whisper-small-q5_1', 'ggml-small-q5_1.bin');
        _prepareReadyModel(tempDir.path, 'piper-pt-br', 'pt_BR-faber-medium.onnx',
            extraFiles: ['tokens.txt'], extraDirs: ['espeak-ng-data']);
        _prepareReadyModel(tempDir.path, 'spleeter-2stems-fp16', 'vocals.fp16.onnx',
            extraFiles: ['accompaniment.fp16.onnx']);

        final config = DubbingJobConfig(
          inputVideo: 'https://youtube.com/watch?v=abc',
          youtubeUrl: 'https://youtube.com/watch?v=abc',
          sourceLang: Lang.en,
          targetLang: Lang.pt,
          preset: Preset.best,
          workDir: p.join(tempDir.path, 'work'),
          outputPath: p.join(tempDir.path, 'out.mp4'),
        );

        PipelineException? error;
        // É assim que o Android M1 expressa "não baixo vídeo remoto": sem
        // downloader no runtime. O pipeline recusa explicitamente, em vez de
        // importar um backend concreto que lá nem existiria.
        await runDubbingJob(config, CancellationToken(),
                runtime: _runtime(models, withDownloader: false))
            .handleError((e) {
              if (e is PipelineException) error = e;
            }).toList();

        expect(error, isNotNull);
        expect(error!.stage, PipelineStage.download);
        expect(error!.message, contains('não é suportado nesta plataforma'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('throws when separation model is missing even if others are ready', () async {
      final tempDir = Directory.systemTemp.createTempSync('pipeline_test_');
      try {
        final models = ModelManager(tempDir.path, _dummyTools);
        _prepareReadyModel(tempDir.path, 'whisper-small-q5_1', 'ggml-small-q5_1.bin');
        _prepareReadyModel(tempDir.path, 'piper-pt-br', 'pt_BR-faber-medium.onnx',
            extraFiles: ['tokens.txt'], extraDirs: ['espeak-ng-data']);
        // spleeter-2stems-fp16 propositalmente não preparado.

        final config = DubbingJobConfig(
          inputVideo: p.join(tempDir.path, 'input.mp4'),
          sourceLang: Lang.en,
          targetLang: Lang.pt,
          preset: Preset.best,
          workDir: p.join(tempDir.path, 'work'),
          outputPath: p.join(tempDir.path, 'out.mp4'),
        );
        File(config.inputVideo).writeAsBytesSync(List.filled(100, 0));

        PipelineException? error;
        await runDubbingJob(config, CancellationToken(),
                runtime: _runtime(models))
            .handleError((e) {
              if (e is PipelineException) error = e;
            }).toList();

        expect(error, isNotNull);
        expect(error!.message, contains('spleeter-2stems-fp16'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('throws a clear message when disk space is low', () async {
      final tempDir = Directory.systemTemp.createTempSync('pipeline_disk_');
      try {
        final models = ModelManager(tempDir.path, _dummyTools);
        final config = DubbingJobConfig(
          inputVideo: p.join(tempDir.path, 'input.mp4'),
          sourceLang: Lang.en,
          targetLang: Lang.pt,
          preset: Preset.best,
          workDir: p.join(tempDir.path, 'work'),
          outputPath: p.join(tempDir.path, 'out.mp4'),
        );
        File(config.inputVideo).writeAsBytesSync(List.filled(100, 0));

        PipelineException? error;
        await runDubbingJob(config, CancellationToken(),
                runtime: _runtime(models,
                    diskSpace: const FixedDiskSpaceProbe(100 * 1024 * 1024)))
            .handleError((e) {
              if (e is PipelineException) error = e;
            }).toList();

        expect(error, isNotNull);
        expect(error!.stage, PipelineStage.prepare);
        expect(error!.message, contains('Espaço em disco insuficiente'));
        expect(error!.message, contains('100 MB'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('completes successfully in voice-over mode', () async {
      final tempDir = Directory.systemTemp.createTempSync('pipeline_ok_');
      try {
        final models = ModelManager(tempDir.path, _dummyTools);
        _prepareReadyModel(tempDir.path, 'whisper-small-q5_1', 'ggml-small-q5_1.bin');
        _prepareReadyModel(tempDir.path, 'piper-pt-br', 'pt_BR-faber-medium.onnx',
            extraFiles: ['tokens.txt'], extraDirs: ['espeak-ng-data']);
        _prepareReadyModel(tempDir.path, 'spleeter-2stems-fp16', 'vocals.fp16.onnx',
            extraFiles: ['accompaniment.fp16.onnx']);

        final config = DubbingJobConfig(
          inputVideo: p.join(tempDir.path, 'input.mp4'),
          sourceLang: Lang.en,
          targetLang: Lang.pt,
          preset: Preset.best,
          generateSrt: true,
          workDir: p.join(tempDir.path, 'work'),
          outputPath: p.join(tempDir.path, 'out.mp4'),
        );
        File(config.inputVideo).writeAsBytesSync(List.filled(100, 0));

        final RunToolFn runToolMock = (
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          if (exePath == 'ffprobe') return _okResult('5.0\n');
          return _okResult();
        };

        // Pre-create files that pipeline checks
        Directory(config.workDir).createSync(recursive: true);
        File(p.join(config.workDir, 'audio_full.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(config.workDir, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(config.workDir, 'dubbed.wav')).writeAsBytesSync(List.filled(100, 0));
        File(config.outputPath).writeAsBytesSync(List.filled(100, 0));

        PipelineException? error;
        DubbingResult? result;

        final events = await runDubbingJob(
          config,
          CancellationToken(),
          runtime: _runtime(
            models,
            runToolOverride: runToolMock,
            createSeparator: () =>
                _MockSeparator(false, failureReason: 'mock: OOM no chunk 2'),
          ),
          onDone: (r) => result = r,
        ).handleError((e) {
          if (e is PipelineException) error = e;
        }).toList();

        expect(error, isNull);
        expect(events.length, greaterThanOrEqualTo(9));
        expect(events.last.message, 'Vídeo gerado com sucesso');

        expect(result, isNotNull);
        expect(result!.voiceOverMode, isTrue);

        final separateEvent = events.firstWhere((e) => e.stage == PipelineStage.separate && e.progress >= 1.0);
        expect(separateEvent.isWarning, isTrue);
        expect(separateEvent.message, contains('mock: OOM no chunk 2'));

        // Sem os modelos de diarização instalados: aviso + voz única.
        final diarizeEvent = events.firstWhere((e) => e.stage == PipelineStage.diarize);
        expect(diarizeEvent.isWarning, isTrue);
        expect(diarizeEvent.message, contains('voz única'));

        // SRT files should exist
        final outDir = tempDir.path;
        expect(File(p.join(outDir, 'out.en.srt')).existsSync(), isTrue);
        expect(File(p.join(outDir, 'out.pt.srt')).existsSync(), isTrue);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('unsupported-on-platform separation yields an informative event, not a warning', () async {
      final tempDir = Directory.systemTemp.createTempSync('pipeline_vo_expected_');
      try {
        final models = ModelManager(tempDir.path, _dummyTools);
        _prepareReadyModel(tempDir.path, 'whisper-small-q5_1', 'ggml-small-q5_1.bin');
        _prepareReadyModel(tempDir.path, 'piper-pt-br', 'pt_BR-faber-medium.onnx',
            extraFiles: ['tokens.txt'], extraDirs: ['espeak-ng-data']);
        _prepareReadyModel(tempDir.path, 'spleeter-2stems-fp16', 'vocals.fp16.onnx',
            extraFiles: ['accompaniment.fp16.onnx']);

        final config = DubbingJobConfig(
          inputVideo: p.join(tempDir.path, 'input.mp4'),
          sourceLang: Lang.en,
          targetLang: Lang.pt,
          preset: Preset.best,
          generateSrt: false,
          workDir: p.join(tempDir.path, 'work'),
          outputPath: p.join(tempDir.path, 'out.mp4'),
        );
        File(config.inputVideo).writeAsBytesSync(List.filled(100, 0));
        Directory(config.workDir).createSync(recursive: true);
        File(p.join(config.workDir, 'audio_full.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(config.workDir, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));
        File(config.outputPath).writeAsBytesSync(List.filled(100, 0));

        final RunToolFn runToolMock = (
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          if (exePath == 'ffprobe') return _okResult('5.0\n');
          return _okResult();
        };

        final events = await runDubbingJob(
          config,
          CancellationToken(),
          runtime: _runtime(
            models,
            runToolOverride: runToolMock,
            createSeparator: () => _MockSeparator(false,
                reason: SeparationFailureReason.notSupportedOnPlatform,
                failureReason: 'unused diagnostic'),
          ),
        ).handleError((_) {}).toList();

        final separateEvent = events.firstWhere(
            (e) => e.stage == PipelineStage.separate && e.progress >= 1.0);
        expect(separateEvent.isWarning, isFalse,
            reason: 'voice-over is the expected Android M1 mode, not a warning');
        expect(separateEvent.message, contains('voice-over'));
        // The diagnostic detail must never leak into the user-facing message.
        expect(separateEvent.message, isNot(contains('unused diagnostic')));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('completes successfully with separation available', () async {
      final tempDir = Directory.systemTemp.createTempSync('pipeline_sep_');
      try {
        final models = ModelManager(tempDir.path, _dummyTools);
        _prepareReadyModel(tempDir.path, 'whisper-small-q5_1', 'ggml-small-q5_1.bin');
        _prepareReadyModel(tempDir.path, 'piper-en', 'en_US-lessac-medium.onnx',
            extraFiles: ['tokens.txt'], extraDirs: ['espeak-ng-data']);
        _prepareReadyModel(tempDir.path, 'spleeter-2stems-fp16', 'vocals.fp16.onnx',
            extraFiles: ['accompaniment.fp16.onnx']);

        final config = DubbingJobConfig(
          inputVideo: p.join(tempDir.path, 'input.mp4'),
          sourceLang: Lang.pt,
          targetLang: Lang.en,
          preset: Preset.best,
          generateSrt: false,
          keepOriginalTrack: false,
          workDir: p.join(tempDir.path, 'work'),
          outputPath: p.join(tempDir.path, 'out.mp4'),
        );
        File(config.inputVideo).writeAsBytesSync(List.filled(100, 0));

        // Pre-create files that pipeline checks
        Directory(config.workDir).createSync(recursive: true);
        File(p.join(config.workDir, 'audio_full.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(config.workDir, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(config.workDir, 'dubbed.wav')).writeAsBytesSync(List.filled(100, 0));
        File(config.outputPath).writeAsBytesSync(List.filled(100, 0));

        final RunToolFn runToolMock = (
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          if (exePath == 'ffprobe') return _okResult('3.0\n');
          return _okResult();
        };

        DubbingResult? result;

        final events = await runDubbingJob(
          config,
          CancellationToken(),
          runtime: _runtime(
            models,
            runToolOverride: runToolMock,
            createSeparator: () => _MockSeparator(true),
          ),
          onDone: (r) => result = r,
        ).toList();

        expect(events.last.message, 'Vídeo gerado com sucesso');
        expect(result, isNotNull);
        expect(result!.voiceOverMode, isFalse);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('assigns different voices per speaker when diarization is ready', () async {
      final tempDir = Directory.systemTemp.createTempSync('pipeline_diar_');
      try {
        final models = ModelManager(tempDir.path, _dummyTools);
        _prepareReadyModel(tempDir.path, 'whisper-small-q5_1', 'ggml-small-q5_1.bin');
        _prepareReadyModel(tempDir.path, 'piper-pt-br', 'pt_BR-faber-medium.onnx',
            extraFiles: ['tokens.txt'], extraDirs: ['espeak-ng-data']);
        _prepareReadyModel(tempDir.path, 'spleeter-2stems-fp16', 'vocals.fp16.onnx',
            extraFiles: ['accompaniment.fp16.onnx']);
        _prepareReadyModel(tempDir.path, 'diarization-segmentation', 'model.onnx');
        _prepareReadyModel(tempDir.path, 'diarization-embedding', 'nemo_en_titanet_small.onnx');

        final config = DubbingJobConfig(
          inputVideo: p.join(tempDir.path, 'input.mp4'),
          sourceLang: Lang.en,
          targetLang: Lang.pt,
          preset: Preset.best,
          generateSrt: false,
          workDir: p.join(tempDir.path, 'work'),
          outputPath: p.join(tempDir.path, 'out.mp4'),
        );
        File(config.inputVideo).writeAsBytesSync(List.filled(100, 0));

        Directory(config.workDir).createSync(recursive: true);
        File(p.join(config.workDir, 'audio_full.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(config.workDir, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(config.workDir, 'dubbed.wav')).writeAsBytesSync(List.filled(100, 0));
        File(config.outputPath).writeAsBytesSync(List.filled(100, 0));

        String? diarizationInput;
        final RunToolFn runToolMock = (
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          if (exePath == 'ffprobe') return _okResult('5.0\n');
          if (args.isNotEmpty && args.last.endsWith('diar_in.wav')) {
            diarizationInput = args[args.indexOf('-i') + 1];
          }
          return _okResult();
        };

        final synth = _MockSynthesizer();
        // Ids brutos fora de ordem (7 e 3) para exercitar a renumeração:
        // o falante 7 fala mais tempo, então vira o índice 0.
        final events = await runDubbingJob(
          config,
          CancellationToken(),
          runtime: _runtime(
            models,
            runToolOverride: runToolMock,
            createSeparator: () => _MockSeparator(true),
            createDiarizer: ({int? speakerCount}) => _MockDiarizer(
              const [
                SpeakerTurn(0.0, 0.5, 7),
                SpeakerTurn(0.6, 1.0, 3),
              ],
              profiles: const {
                7: SpeakerProfile(VoiceGender.female, AgeBand.adult),
                3: SpeakerProfile(VoiceGender.male, AgeBand.adult),
              },
            ),
            createSynthesizer: (_, {String? voiceModelId, int voiceSid = 0}) => synth,
          ),
        ).toList();

        final diarizeDone = events.firstWhere(
            (e) => e.stage == PipelineStage.diarize && e.progress >= 1.0);
        expect(diarizeDone.isWarning, isFalse);
        expect(diarizeDone.message, contains('2 falante(s)'));
        expect(diarizeDone.message, contains('1 masculino(s), 1 feminino(s)'));

        // A diarização deve usar o áudio ORIGINAL — artefatos da separação
        // degradam os embeddings de falante e o pitch.
        expect(diarizationInput, endsWith('audio_full.wav'));

        // Os dois segmentos têm falantes diferentes: não são fundidos e cada
        // um é sintetizado com sua própria voz (0 = quem fala mais). O áudio
        // minúsculo do fake numa janela de 0.5s dispara o alongamento da
        // fase 2, então cada falante aparece duas vezes (1x natural + 1x
        // esticado).
        expect(synth.speakersUsed, [0, 1, 0, 1]);

        // Perfis renumerados junto com os falantes (7→0, 3→1) e entregues
        // ao sintetizador antes da síntese.
        expect(synth.profilesReceived, {
          0: SpeakerProfile(VoiceGender.female, AgeBand.adult),
          1: SpeakerProfile(VoiceGender.male, AgeBand.adult),
        });
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('child speaker gets pitch-shifted audio', () async {
      final tempDir = Directory.systemTemp.createTempSync('pipeline_child_');
      try {
        final models = ModelManager(tempDir.path, _dummyTools);
        _prepareReadyModel(tempDir.path, 'whisper-small-q5_1', 'ggml-small-q5_1.bin');
        _prepareReadyModel(tempDir.path, 'piper-pt-br', 'pt_BR-faber-medium.onnx',
            extraFiles: ['tokens.txt'], extraDirs: ['espeak-ng-data']);
        _prepareReadyModel(tempDir.path, 'spleeter-2stems-fp16', 'vocals.fp16.onnx',
            extraFiles: ['accompaniment.fp16.onnx']);
        _prepareReadyModel(tempDir.path, 'diarization-segmentation', 'model.onnx');
        _prepareReadyModel(tempDir.path, 'diarization-embedding', 'nemo_en_titanet_small.onnx');

        final config = DubbingJobConfig(
          inputVideo: p.join(tempDir.path, 'input.mp4'),
          sourceLang: Lang.en,
          targetLang: Lang.pt,
          preset: Preset.best,
          generateSrt: false,
          workDir: p.join(tempDir.path, 'work'),
          outputPath: p.join(tempDir.path, 'out.mp4'),
        );
        File(config.inputVideo).writeAsBytesSync(List.filled(100, 0));

        Directory(config.workDir).createSync(recursive: true);
        File(p.join(config.workDir, 'audio_full.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(config.workDir, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(config.workDir, 'dubbed.wav')).writeAsBytesSync(List.filled(100, 0));
        File(config.outputPath).writeAsBytesSync(List.filled(100, 0));

        final capturedFilters = <String>[];
        final RunToolFn runToolMock = (
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          if (exePath == 'ffprobe') return _okResult('5.0\n');
          final fIdx = args.indexOf('-filter:a');
          if (fIdx >= 0 && args[fIdx + 1].contains('asetrate')) {
            capturedFilters.add(args[fIdx + 1]);
            // O fitter lê o WAV de saída do pitch-shift: grava um válido.
            writeWavPcm16(args.last, WavData(Float32List(100), 44100, 1));
          }
          return _okResult();
        };

        final synth = _MockSynthesizer();
        // Falante 7 (mais tempo de fala → índice 0) é criança.
        final events = await runDubbingJob(
          config,
          CancellationToken(),
          runtime: _runtime(
            models,
            runToolOverride: runToolMock,
            createSeparator: () => _MockSeparator(true),
            createDiarizer: ({int? speakerCount}) => _MockDiarizer(
              const [
                SpeakerTurn(0.0, 0.5, 7),
                SpeakerTurn(0.6, 1.0, 3),
              ],
              profiles: const {
                7: SpeakerProfile(VoiceGender.unknown, AgeBand.child),
                3: SpeakerProfile(VoiceGender.male, AgeBand.adult),
              },
            ),
            createSynthesizer: (_, {String? voiceModelId, int voiceSid = 0}) => synth,
          ),
        ).toList();

        final diarizeDone = events.firstWhere(
            (e) => e.stage == PipelineStage.diarize && e.progress >= 1.0);
        expect(diarizeDone.message, contains('1 criança(s)'));

        // Só o segmento da criança (falante 0) passa pelo pitch-shift,
        // com o fator e a restauração de duração corretos.
        expect(capturedFilters, hasLength(1));
        expect(capturedFilters.single, contains('asetrate=${(22050 * 1.15).round()}'));
        expect(capturedFilters.single, contains('aresample=44100'));
        expect(capturedFilters.single, contains('atempo=0.8696'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('YouTube download keeps the original video in the output folder', () async {
      final tempDir = Directory.systemTemp.createTempSync('pipeline_yt_');
      try {
        final models = ModelManager(tempDir.path, _dummyTools);
        _prepareReadyModel(tempDir.path, 'whisper-small-q5_1', 'ggml-small-q5_1.bin');
        _prepareReadyModel(tempDir.path, 'piper-pt-br', 'pt_BR-faber-medium.onnx',
            extraFiles: ['tokens.txt'], extraDirs: ['espeak-ng-data']);
        _prepareReadyModel(tempDir.path, 'spleeter-2stems-fp16', 'vocals.fp16.onnx',
            extraFiles: ['accompaniment.fp16.onnx']);

        // Tools com yt-dlp "existente" para ativar o caminho de download.
        final fakeYtDlp = p.join(tempDir.path, 'yt-dlp.exe');
        File(fakeYtDlp).writeAsBytesSync([1]);
        final tools = Tools(
          ffmpeg: 'ffmpeg',
          ffprobe: 'ffprobe',
          whisperCli: 'whisper-cli',
          translateLocally: 'translateLocally',
          sherpaSourceSeparation: 'sherpa-separation',
          ytDlp: fakeYtDlp,
        );

        final outDir = p.join(tempDir.path, 'saida');
        Directory(outDir).createSync();
        final config = DubbingJobConfig(
          inputVideo: 'https://youtube.com/watch?v=abc',
          youtubeUrl: 'https://youtube.com/watch?v=abc',
          sourceLang: Lang.en,
          targetLang: Lang.pt,
          preset: Preset.best,
          generateSrt: false,
          workDir: p.join(tempDir.path, 'work'),
          outputPath: p.join(outDir, 'meu_video_dub_pt.mp4'),
        );

        Directory(config.workDir).createSync(recursive: true);
        File(p.join(config.workDir, 'audio_full.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(config.workDir, 'dub_voice.wav')).writeAsBytesSync(List.filled(100, 0));
        File(p.join(config.workDir, 'dubbed.wav')).writeAsBytesSync(List.filled(100, 0));
        File(config.outputPath).writeAsBytesSync(List.filled(100, 0));

        final RunToolFn runToolMock = (
          String exePath,
          List<String> args, {
          String? workingDirectory,
          Duration timeout = const Duration(minutes: 30),
          CancellationToken? token,
        }) async {
          if (exePath == 'ffprobe') return _okResult('5.0\n');
          if (exePath == fakeYtDlp) {
            // Simula o download gravando o vídeo no workDir.
            File(p.join(config.workDir, 'input.mp4'))
                .writeAsBytesSync(List.filled(300, 7));
          }
          return _okResult();
        };

        DubbingResult? result;
        await runDubbingJob(
          config,
          CancellationToken(),
          runtime: _runtime(
            models,
            tools: tools,
            runToolOverride: runToolMock,
            createSeparator: () => _MockSeparator(false),
          ),
          onDone: (r) => result = r,
        ).toList();

        final originalPath = p.join(outDir, 'meu_video_dub_pt_original.mp4');
        expect(result!.originalVideo, originalPath);
        expect(File(originalPath).existsSync(), isTrue);
        expect(File(originalPath).lengthSync(), 300);
        // O workDir (onde o download nasceu) foi apagado normalmente.
        expect(Directory(config.workDir).existsSync(), isFalse);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('cancellation stops pipeline early', () async {
      final tempDir = Directory.systemTemp.createTempSync('pipeline_cancel_');
      try {
        final models = ModelManager(tempDir.path, _dummyTools);
        _prepareReadyModel(tempDir.path, 'whisper-small-q5_1', 'ggml-small-q5_1.bin');
        _prepareReadyModel(tempDir.path, 'piper-pt-br', 'pt_BR-faber-medium.onnx',
            extraFiles: ['tokens.txt'], extraDirs: ['espeak-ng-data']);
        _prepareReadyModel(tempDir.path, 'spleeter-2stems-fp16', 'vocals.fp16.onnx',
            extraFiles: ['accompaniment.fp16.onnx']);

        final config = DubbingJobConfig(
          inputVideo: p.join(tempDir.path, 'input.mp4'),
          sourceLang: Lang.en,
          targetLang: Lang.pt,
          preset: Preset.best,
          workDir: p.join(tempDir.path, 'work'),
          outputPath: p.join(tempDir.path, 'out.mp4'),
        );
        File(config.inputVideo).writeAsBytesSync(List.filled(100, 0));

        final token = CancellationToken();
        token.cancel();

        await expectLater(
          () => runDubbingJob(config, token,
                  runtime: _runtime(models,
                      createSeparator: () => _MockSeparator(false)))
              .toList(),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}

void _prepareReadyModel(String root, String id, String mainFile,
    {List<String> extraFiles = const [], List<String> extraDirs = const []}) {
  final base = p.join(root, id);
  Directory(base).createSync(recursive: true);
  File(p.join(base, mainFile)).writeAsBytesSync([1, 2, 3]);
  for (final f in extraFiles) {
    File(p.join(base, f)).writeAsBytesSync([4, 5, 6]);
  }
  for (final d in extraDirs) {
    Directory(p.join(base, d)).createSync();
  }
  File(p.join(base, '.sha256')).writeAsStringSync('mock-hash');
}
