import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/backends/piper_synthesizer.dart';
import 'package:dubbing_engine/src/backends/sherpa_diarizer.dart';
import 'package:dubbing_engine/src/backends/sherpa_separator.dart';
import 'package:dubbing_engine/src/backends/translatelocally_translator.dart';
import 'package:dubbing_engine/src/backends/whisper_transcriber.dart';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/steps/demux.dart';
import 'package:dubbing_engine/src/steps/fitter.dart';
import 'package:dubbing_engine/src/steps/mixer.dart';
import 'package:dubbing_engine/src/steps/muxer.dart';
import 'package:dubbing_engine/src/steps/segmenter.dart';
import 'package:dubbing_engine/src/steps/speaker_assign.dart';
import 'package:dubbing_engine/src/steps/speech_trim.dart';
import 'package:dubbing_engine/src/steps/subtitles.dart';
import 'package:dubbing_engine/src/steps/youtube.dart';
import 'package:dubbing_engine/src/tools/disk_space.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:dubbing_engine/src/wav.dart';

/// Espaço mínimo livre recomendado no disco do diretório de trabalho.
/// Vídeo, áudio extraído e arquivos intermediários (WAVs) exigem bastante
/// espaço temporário durante o processamento.
const int minFreeDiskBytes = 2 * 1024 * 1024 * 1024; // 2 GB

Stream<PipelineEvent> runDubbingJob(
  DubbingJobConfig config,
  CancellationToken token, {
  required Tools tools,
  required ModelManager models,
  void Function(DubbingResult)? onDone,
  Separator Function(Tools, ModelManager)? separatorFactory,
  Diarizer Function(ModelManager)? diarizerFactory,
  Transcriber Function(Tools, ModelManager, Preset)? transcriberFactory,
  Translator Function(Tools, ModelManager)? translatorFactory,
  Synthesizer Function(Lang, ModelManager)? synthesizerFactory,
  RunToolFn? runToolOverride,
  int? Function(String)? freeBytesOverride,
}) async* {
  final stopwatch = Stopwatch()..start();
  String? srtSourcePath;
  String? srtTargetPath;
  bool voiceOverMode = false;
  int segmentsWithOverflow = 0;
  String workDir = config.workDir;
  String inputVideo = config.inputVideo;

  try {
    _ensureDirectories(workDir);

    yield PipelineEvent(PipelineStage.prepare, 0.0, 'Verificando espaço em disco...');
    final freeBytes = freeBytesOverride != null ? freeBytesOverride(workDir) : freeBytesForPath(workDir);
    if (freeBytes != null && freeBytes < minFreeDiskBytes) {
      final freeMb = (freeBytes / (1024 * 1024)).round();
      final drive = driveOf(workDir);
      throw PipelineException(PipelineStage.prepare,
          'Espaço em disco insuficiente na unidade $drive (apenas $freeMb MB livres). '
          'Libere espaço ou escolha um diretório de trabalho em outra unidade com mais espaço livre.');
    }
    yield PipelineEvent(PipelineStage.prepare, 1.0, 'Espaço em disco OK');

    final targetVoiceId = piperModelId[config.targetLang];
    if (targetVoiceId == null) {
      throw PipelineException(PipelineStage.prepare,
          'O idioma ${config.targetLang.label} não tem voz de dublagem disponível.');
    }
    final requiredIds = <String>[
      whisperModelId[config.preset]!,
      targetVoiceId,
      spleeterModelId,
    ];
    final missing = requiredIds.where((id) => models.stateOf(id) != ModelState.ready).toList();
    if (missing.isNotEmpty) {
      throw PipelineException(PipelineStage.prepare,
          'Modelos necessários não estão prontos: ${missing.join(', ')}');
    }

    if (config.youtubeUrl != null) {
      if (!tools.hasYtDlp) {
        throw PipelineException(PipelineStage.download,
            'yt-dlp não encontrado. Baixe yt-dlp.exe e coloque em tools/win/');
      }
      yield PipelineEvent(PipelineStage.download, 0.0, 'Baixando vídeo do YouTube...');
      inputVideo = await downloadFromYoutube(
        config.youtubeUrl!,
        workDir,
        tools.ytDlp,
        token,
        runToolOverride: runToolOverride,
        cookiesFromBrowser: config.ytDlpCookiesFromBrowser,
        cookiesFile: config.ytDlpCookiesFile,
      );
      yield PipelineEvent(PipelineStage.download, 1.0, 'Download concluído');
    }

    yield PipelineEvent(PipelineStage.demux, 0.0, 'Extraindo áudio do vídeo...');

    if (token.isCancelled) throw PipelineException(PipelineStage.demux, 'Cancelado pelo usuário');
    final videoDuration = await runDemux(config, tools, token,
        runToolOverride: runToolOverride, inputVideoOverride: inputVideo);

    yield PipelineEvent(PipelineStage.demux, 1.0, 'Áudio extraído com sucesso');

    yield PipelineEvent(PipelineStage.separate, 0.0, 'Separando voz da trilha...');
    if (token.isCancelled) throw PipelineException(PipelineStage.separate, 'Cancelado pelo usuário');

    final separator = separatorFactory != null ? separatorFactory(tools, models) : SherpaSeparator(tools, models);
    final separationOutcome = await separator.separate(
      p.join(workDir, 'audio_full.wav'),
      workDir,
      token,
    );
    voiceOverMode = !separationOutcome.ok;
    final audioForAsr = voiceOverMode
        ? p.join(workDir, 'audio_full.wav')
        : separationOutcome.files!.vocalsWav;

    yield voiceOverMode
        ? PipelineEvent(
            PipelineStage.separate,
            1.0,
            'Separação indisponível — modo voice-over (o áudio original '
            'permanecerá audível sob a dublagem). '
            'Motivo: ${separationOutcome.failureReason}',
            isWarning: true)
        : PipelineEvent(PipelineStage.separate, 1.0, 'Voz separada com sucesso');

    // Diarização (multi-vozes): opcional — sem os modelos instalados a
    // dublagem segue com voz única. Com voz fixa escolhida pelo usuário,
    // a detecção de falantes é desnecessária.
    var speakerTurns = const <SpeakerTurn>[];
    var speakerProfiles = const <int, SpeakerProfile>{};
    final diarizationReady =
        models.stateOf(diarizationSegmentationModelId) == ModelState.ready &&
            models.stateOf(diarizationEmbeddingModelId) == ModelState.ready;
    if (config.voiceModelId != null) {
      yield PipelineEvent(PipelineStage.diarize, 1.0,
          'Voz fixa selecionada — detecção de falantes ignorada');
    } else if (diarizationReady) {
      yield PipelineEvent(PipelineStage.diarize, 0.0, 'Detectando falantes...');
      if (token.isCancelled) throw PipelineException(PipelineStage.diarize, 'Cancelado pelo usuário');
      final diarIn = p.join(workDir, 'diar_in.wav');
      final exec = runToolOverride ?? runTool;
      // Sempre o áudio ORIGINAL: os artefatos da separação (spleeter)
      // degradam os embeddings de falante (fragmenta clusters) e atenuam
      // os graves masculinos (troca o sexo detectado pelo pitch).
      final rConv = await exec(tools.ffmpeg, [
        '-y', '-i', p.join(workDir, 'audio_full.wav'),
        '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le',
        diarIn,
      ], workingDirectory: workDir, token: token);
      if (rConv.exitCode != 0) {
        throw PipelineException(PipelineStage.diarize,
            'Erro ao preparar áudio para diarização: ${rConv.stderrTail}');
      }
      final diarizer = diarizerFactory != null
          ? diarizerFactory(models)
          : SherpaDiarizer(models, numClusters: config.speakerCount);
      final diarization = await diarizer.diarize(diarIn, token);
      speakerTurns = diarization.turns;
      // Renumera o mapa de perfis com o mesmo critério de assignSpeakers
      // (índice 0 = falante com mais tempo de fala).
      final rank = rankSpeakersByAirtime(speakerTurns);
      speakerProfiles = {
        for (final e in diarization.profiles.entries) rank[e.key] ?? 0: e.value,
      };
      final speakerCount = speakerTurns.map((t) => t.speaker).toSet().length;
      final maleCount = speakerProfiles.values
          .where((p) => p.gender == VoiceGender.male)
          .length;
      final femaleCount = speakerProfiles.values
          .where((p) => p.gender == VoiceGender.female)
          .length;
      final childCount = speakerProfiles.values
          .where((p) => p.age == AgeBand.child)
          .length;
      final childSuffix = childCount > 0 ? ', $childCount criança(s)' : '';
      yield PipelineEvent(PipelineStage.diarize, 1.0,
          'Detecção concluída: $speakerCount falante(s) '
          '($maleCount masculino(s), $femaleCount feminino(s)$childSuffix)');
    } else {
      yield PipelineEvent(PipelineStage.diarize, 1.0,
          'Modelos de detecção de falantes não instalados — dublagem com voz única. '
          'Baixe-os na tela Modelos para vozes diferentes por pessoa.',
          isWarning: true);
    }

    yield PipelineEvent(PipelineStage.transcribe, 0.0, 'Transcrevendo áudio...');
    if (token.isCancelled) throw PipelineException(PipelineStage.transcribe, 'Cancelado pelo usuário');

    final transcriber = transcriberFactory != null ? transcriberFactory(tools, models, config.preset) : WhisperTranscriber(tools, models, config.preset);
    final rawSegments = await transcriber.transcribe(audioForAsr, config.sourceLang, token);

    yield PipelineEvent(PipelineStage.transcribe, 1.0,
        'Transcrição concluída: ${rawSegments.length} segmentos');

    yield PipelineEvent(PipelineStage.segment, 0.0, 'Segmentando falas...');
    if (token.isCancelled) throw PipelineException(PipelineStage.segment, 'Cancelado pelo usuário');

    var segments = buildDubbingSegments(assignSpeakers(rawSegments, speakerTurns));
    // Reapara as unidades mescladas à fala real: os timestamps por palavra
    // do whisper são imprecisos, mas as unidades têm fala sólida para
    // ancorar por energia (usa o asr_in.wav gerado pela transcrição).
    final asrWavPath = p.join(workDir, 'asr_in.wav');
    if (File(asrWavPath).existsSync()) {
      final asr = readWav(asrWavPath);
      segments = trimDubbingSegmentsToSpeech(segments, asr.samples, asr.sampleRate);
    }

    yield PipelineEvent(PipelineStage.segment, 1.0,
        'Segmentação concluída: ${segments.length} unidades de dublagem');

    yield PipelineEvent(PipelineStage.translate, 0.0, 'Traduzindo falas...');
    if (token.isCancelled) throw PipelineException(PipelineStage.translate, 'Cancelado pelo usuário');

    final translator = translatorFactory != null ? translatorFactory(tools, models) : TranslateLocallyTranslator(tools, models);
    final sentences = segments.map((s) => s.sourceText).toList();
    final translated = await translator.translate(
        sentences, config.sourceLang, config.targetLang, token);
    for (int i = 0; i < segments.length; i++) {
      segments[i].translatedText = translated[i].isNotEmpty ? translated[i] : segments[i].sourceText;
    }

    yield PipelineEvent(PipelineStage.translate, 1.0, 'Tradução concluída');

    yield PipelineEvent(PipelineStage.synthesize, 0.0, 'Sintetizando vozes...');
    if (token.isCancelled) throw PipelineException(PipelineStage.synthesize, 'Cancelado pelo usuário');

    final synthesizer = synthesizerFactory != null
        ? synthesizerFactory(config.targetLang, models)
        : PiperSynthesizer(config.targetLang, models,
            voiceOverride: config.voiceModelId != null
                ? (config.voiceModelId!, config.voiceSid)
                : null);
    try {
      synthesizer.configureSpeakerVoices(speakerProfiles);
      final childSpeakers = {
        for (final e in speakerProfiles.entries)
          if (e.value.age == AgeBand.child) e.key,
      };
      // Fase 1: sintetiza tudo a 1x para conhecer as durações naturais.
      final totalSegs = segments.length;
      final naturalAudios = <({Float32List samples, int sampleRate})>[];
      for (int i = 0; i < totalSegs; i++) {
        if (token.isCancelled) throw PipelineException(PipelineStage.synthesize, 'Cancelado pelo usuário');
        naturalAudios.add(synthesizer.synthesize(segments[i].translatedText,
            speaker: segments[i].speaker));
        yield PipelineEvent(PipelineStage.synthesize, (i + 1) / totalSegs,
            'Sintetizando fala ${i + 1}/$totalSegs');
      }

      // Fase 2: planeja o ritmo por blocos (velocidade uniforme por região
      // densa, sem oscilação) e materializa cada fala.
      yield PipelineEvent(PipelineStage.fit, 0.0, 'Planejando o ritmo das falas...');
      final plan = planDubSchedule(
        [for (final s in segments) s.start.inMicroseconds / 1e6],
        [for (final s in segments) s.end.inMicroseconds / 1e6],
        [for (final a in naturalAudios) a.samples.length / a.sampleRate],
        videoDuration,
      );
      segmentsWithOverflow = plan.where((item) => item.clamped).length;

      double cursor = 0;
      for (int i = 0; i < totalSegs; i++) {
        if (token.isCancelled) throw PipelineException(PipelineStage.fit, 'Cancelado pelo usuário');
        cursor = await applyPlanToSegment(
            segments[i], naturalAudios[i], plan[i].speed, synthesizer, tools, workDir, token,
            runToolOverride: runToolOverride, childSpeakers: childSpeakers, cursorSec: cursor);
        yield PipelineEvent(PipelineStage.fit, (i + 1) / totalSegs,
            'Ajustando fala ${i + 1}/$totalSegs');
      }

      yield PipelineEvent(PipelineStage.fit, 1.0,
          'Ajuste concluído: $segmentsWithOverflow falas além do limite de velocidade');
    } finally {
      synthesizer.dispose();
    }

    yield PipelineEvent(PipelineStage.mix, 0.0, 'Mixando áudio final...');
    if (token.isCancelled) throw PipelineException(PipelineStage.mix, 'Cancelado pelo usuário');

    await buildDubTrack(segments, videoDuration, workDir, token);
    await buildFinalMix(voiceOverMode, workDir, tools, token, runToolOverride: runToolOverride);

    yield PipelineEvent(PipelineStage.mix, 1.0, 'Mixagem concluída');

    yield PipelineEvent(PipelineStage.mux, 0.0, 'Gerando vídeo final...');
    if (token.isCancelled) throw PipelineException(PipelineStage.mux, 'Cancelado pelo usuário');

    final outputVideo = await buildFinalVideo(
      config,
      p.join(workDir, 'dubbed.wav'),
      tools,
      token,
      runToolOverride: runToolOverride,
      inputVideoOverride: inputVideo,
    );

    if (config.generateSrt) {
      final baseName = p.basenameWithoutExtension(config.outputPath);
      final outDir = p.dirname(config.outputPath);
      srtSourcePath = p.join(outDir, '$baseName.${config.sourceLang.code}.srt');
      srtTargetPath = p.join(outDir, '$baseName.${config.targetLang.code}.srt');
      File(srtSourcePath).writeAsStringSync(buildSrtContent(segments, true));
      File(srtTargetPath).writeAsStringSync(buildSrtContent(segments, false));
    }

    // Vídeo baixado do YouTube: preserva o original na pasta de saída
    // (o diretório de trabalho, onde ele foi baixado, é apagado abaixo).
    String? originalVideoPath;
    if (config.youtubeUrl != null && File(inputVideo).existsSync()) {
      final baseName = p.basenameWithoutExtension(config.outputPath);
      final outDir = p.dirname(config.outputPath);
      originalVideoPath =
          p.join(outDir, '${baseName}_original${p.extension(inputVideo)}');
      File(inputVideo).copySync(originalVideoPath);
    }

    yield PipelineEvent(PipelineStage.mux, 1.0, 'Vídeo gerado com sucesso');

    stopwatch.stop();

    if (Directory(workDir).existsSync()) {
      Directory(workDir).deleteSync(recursive: true);
    }

    final result = DubbingResult(
      outputVideo: outputVideo,
      srtSource: srtSourcePath,
      srtTarget: srtTargetPath,
      originalVideo: originalVideoPath,
      voiceOverMode: voiceOverMode,
      segmentsWithOverflow: segmentsWithOverflow,
      elapsed: stopwatch.elapsed,
    );
    onDone?.call(result);
  } catch (e) {
    stopwatch.stop();
    if (e is PipelineException) {
      yield PipelineEvent(e.stage, 1.0, 'Erro: ${e.message}');
      rethrow;
    }
    rethrow;
  }
}

void _ensureDirectories(String workDir) {
  Directory(workDir).createSync(recursive: true);
}
