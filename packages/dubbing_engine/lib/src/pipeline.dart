import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/runtime/dubbing_runtime.dart';
import 'package:dubbing_engine/src/steps/demux.dart';
import 'package:dubbing_engine/src/steps/fitter.dart';
import 'package:dubbing_engine/src/steps/mixer.dart';
import 'package:dubbing_engine/src/steps/muxer.dart';
import 'package:dubbing_engine/src/steps/segmenter.dart';
import 'package:dubbing_engine/src/steps/speaker_assign.dart';
import 'package:dubbing_engine/src/steps/speech_trim.dart';
import 'package:dubbing_engine/src/steps/subtitles.dart';
import 'package:dubbing_engine/src/steps/sync_report.dart';
import 'package:dubbing_engine/src/wav.dart';

/// Espaço mínimo livre recomendado no disco do diretório de trabalho.
/// Vídeo, áudio extraído e arquivos intermediários (WAVs) exigem bastante
/// espaço temporário durante o processamento.
const int minFreeDiskBytes = 2 * 1024 * 1024 * 1024; // 2 GB

Stream<PipelineEvent> runDubbingJob(
  DubbingJobConfig config,
  CancellationToken token, {
  required DubbingRuntime runtime,
  void Function(DubbingResult)? onDone,
}) async* {
  final models = runtime.models;
  final tools = runtime.tools;
  final exec = runtime.runTool;
  final stopwatch = Stopwatch()..start();
  String? srtSourcePath;
  String? srtTargetPath;
  bool voiceOverMode = false;
  int segmentsWithOverflow = 0;
  Duration truncatedTail = Duration.zero;
  String? syncReportPath;
  String workDir = config.workDir;
  String inputVideo = config.inputVideo;

  try {
    _ensureDirectories(workDir);

    yield PipelineEvent(PipelineStage.prepare, 0.0, 'Verificando espaço em disco...');
    final freeBytes = await runtime.diskSpace.freeBytes(workDir);
    if (freeBytes != null && freeBytes < minFreeDiskBytes) {
      final freeMb = (freeBytes / (1024 * 1024)).round();
      final drive = p.rootPrefix(p.absolute(workDir));
      throw PipelineException(PipelineStage.prepare,
          'Espaço em disco insuficiente na unidade $drive (apenas $freeMb MB livres). '
          'Libere espaço ou escolha um diretório de trabalho em outra unidade com mais espaço livre.');
    }
    yield PipelineEvent(PipelineStage.prepare, 1.0, 'Espaço em disco OK');

    final catalog = models.catalog;
    final targetVoiceId = catalog.defaultVoiceIds[config.targetLang];
    if (targetVoiceId == null) {
      throw PipelineException(PipelineStage.prepare,
          'O idioma ${config.targetLang.label} não tem voz de dublagem disponível.');
    }
    final asrId = catalog.asrModelIds[config.preset];
    if (asrId == null) {
      throw PipelineException(PipelineStage.prepare,
          'O preset ${config.preset.name} não tem modelo de ASR nesta plataforma.');
    }
    final requiredIds = <String>[
      asrId,
      targetVoiceId,
      // Plataforma sem separação (Android M1) não exige o modelo.
      if (catalog.separatorModelId != null) catalog.separatorModelId!,
    ];
    final missing = requiredIds.where((id) => models.stateOf(id) != ModelState.ready).toList();
    if (missing.isNotEmpty) {
      throw PipelineException(PipelineStage.prepare,
          'Modelos necessários não estão prontos: ${missing.join(', ')}');
    }

    if (config.youtubeUrl != null) {
      // A plataforma que não baixa vídeo remoto (Android M1) expressa isso com
      // um createDownloader nulo — e a recusa é explícita, não um crash.
      final createDownloader = runtime.createDownloader;
      if (createDownloader == null) {
        throw PipelineException(PipelineStage.download,
            'Download de vídeo remoto não é suportado nesta plataforma.');
      }
      yield PipelineEvent(PipelineStage.download, 0.0, 'Baixando vídeo do YouTube...');
      inputVideo = await createDownloader().download(config, workDir, token);
      yield PipelineEvent(PipelineStage.download, 1.0, 'Download concluído');
    }

    yield PipelineEvent(PipelineStage.demux, 0.0, 'Extraindo áudio do vídeo...');

    if (token.isCancelled) throw PipelineException(PipelineStage.demux, 'Cancelado pelo usuário');
    final videoDuration = await runDemux(config, tools, token,
        runToolOverride: exec, inputVideoOverride: inputVideo);

    yield PipelineEvent(PipelineStage.demux, 1.0, 'Áudio extraído com sucesso');

    yield PipelineEvent(PipelineStage.separate, 0.0, 'Separando voz da trilha...');
    if (token.isCancelled) throw PipelineException(PipelineStage.separate, 'Cancelado pelo usuário');

    final separator = runtime.createSeparator();
    final separationOutcome = await separator.separate(
      p.join(workDir, 'audio_full.wav'),
      workDir,
      token,
    );
    voiceOverMode = !separationOutcome.ok;
    final audioForAsr = voiceOverMode
        ? p.join(workDir, 'audio_full.wav')
        : separationOutcome.files!.vocalsWav;

    if (!voiceOverMode) {
      yield PipelineEvent(PipelineStage.separate, 1.0, 'Voz separada com sucesso');
    } else if (separationOutcome.isExpected) {
      // Android M1: voice-over é o modo previsto, não uma falha. Evento
      // informativo, sem warning técnico.
      yield PipelineEvent(PipelineStage.separate, 1.0,
          'Modo voice-over: o áudio original permanece baixo sob a dublagem.');
    } else {
      yield PipelineEvent(
          PipelineStage.separate,
          1.0,
          'Separação indisponível — modo voice-over (o áudio original '
          'permanecerá audível sob a dublagem). '
          'Motivo: ${separationOutcome.detail ?? separationOutcome.reason?.name}',
          isWarning: true);
    }

    // Diarização (multi-vozes): opcional — sem os modelos instalados a
    // dublagem segue com voz única. Com voz fixa escolhida pelo usuário,
    // a detecção de falantes é desnecessária.
    var speakerTurns = const <SpeakerTurn>[];
    var speakerProfiles = const <int, SpeakerProfile>{};
    final createDiarizer = runtime.createDiarizer;
    final diarizationReady = createDiarizer != null &&
        models.stateOf(diarizationSegmentationModelId) == ModelState.ready &&
            models.stateOf(diarizationEmbeddingModelId) == ModelState.ready;
    if (config.voiceModelId != null) {
      yield PipelineEvent(PipelineStage.diarize, 1.0,
          'Voz fixa selecionada — detecção de falantes ignorada');
    } else if (diarizationReady) {
      yield PipelineEvent(PipelineStage.diarize, 0.0, 'Detectando falantes...');
      if (token.isCancelled) throw PipelineException(PipelineStage.diarize, 'Cancelado pelo usuário');
      final diarIn = p.join(workDir, 'diar_in.wav');
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
      final diarizer = createDiarizer(speakerCount: config.speakerCount);
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

    final transcriber = runtime.createTranscriber(config.preset);
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

    final translator = runtime.createTranslator();
    final sentences = segments.map((s) => s.sourceText).toList();
    final translated = await translator.translate(
        sentences, config.sourceLang, config.targetLang, token);
    for (int i = 0; i < segments.length; i++) {
      segments[i].translatedText = translated[i].isNotEmpty ? translated[i] : segments[i].sourceText;
    }

    yield PipelineEvent(PipelineStage.translate, 1.0, 'Tradução concluída');

    yield PipelineEvent(PipelineStage.synthesize, 0.0, 'Sintetizando vozes...');
    if (token.isCancelled) throw PipelineException(PipelineStage.synthesize, 'Cancelado pelo usuário');

    final synthesizer = runtime.createSynthesizer(
      config.targetLang,
      voiceModelId: config.voiceModelId,
      voiceSid: config.voiceSid,
    );
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
            runToolOverride: exec, childSpeakers: childSpeakers, cursorSec: cursor);
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

    final dubTrack = await buildDubTrack(segments, videoDuration, workDir, token);
    truncatedTail = dubTrack.truncatedTail;
    await buildFinalMix(voiceOverMode, workDir, tools, token, runToolOverride: exec);

    if (truncatedTail > Duration.zero) {
      final ms = truncatedTail.inMilliseconds;
      yield PipelineEvent(PipelineStage.mix, 1.0,
          'A última fala passou ${ms}ms do fim do vídeo e foi cortada.',
          isWarning: truncatedTail > tailTruncationCap);
    }

    yield PipelineEvent(PipelineStage.mix, 1.0, 'Mixagem concluída');

    yield PipelineEvent(PipelineStage.mux, 0.0, 'Gerando vídeo final...');
    if (token.isCancelled) throw PipelineException(PipelineStage.mux, 'Cancelado pelo usuário');

    final outputVideo = await buildFinalVideo(
      config,
      p.join(workDir, 'dubbed.wav'),
      tools,
      token,
      runToolOverride: exec,
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

    // Relatório de sincronia: fica ao lado da saída (o workDir é apagado
    // abaixo). É o que torna o critério de ±300ms mensurável, e é o baseline
    // contra o qual o Android vai ser comparado.
    final report = buildSyncReport(segments, videoDuration, truncatedTail);
    syncReportPath = p.join(p.dirname(config.outputPath),
        '${p.basenameWithoutExtension(config.outputPath)}.sync.json');
    File(syncReportPath).writeAsStringSync(report.json);
    yield PipelineEvent(
        PipelineStage.mux,
        0.9,
        'Sincronia: ${report.summary.withinPct.toStringAsFixed(1)}% das falas '
        'dentro de ±${syncToleranceMs}ms (pior: ${report.summary.worstDeltaMs}ms)');

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
      truncatedTail: truncatedTail,
      syncReport: syncReportPath,
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
