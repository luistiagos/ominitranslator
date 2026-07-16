import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:dubbing_engine/dubbing_engine.dart';

import 'platform/android_ffmpeg.dart';
import 'platform/android_storage.dart';
import 'platform/media_processing_service.dart';

/// Entrypoint do isolate Dart headless que o `MediaProcessingService` (D3.3,
/// §14.2) cria — roda no processo do app, mas num `FlutterEngine` separado
/// do da Activity, sem árvore de widgets. Precisa estar `@pragma('vm:entry-
/// point')` (senão o AOT/tree-shaking remove o símbolo em release) e
/// alcançável a partir de `main.dart` (Dart só inclui no snapshot o que é
/// transitivamente importado da entry library — a anotação impede o
/// tree-shaking, não substitui o import).
@pragma('vm:entry-point')
void serviceMain() {
  WidgetsFlutterBinding.ensureInitialized();
  const worker = MethodChannel('omnitranslator/service_worker');

  CancellationToken? activeToken;
  String? activeJobId;

  worker.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'runJob':
        final args = (call.arguments as Map).cast<String, dynamic>();
        final jobId = args['jobId'] as String;
        final config =
            DubbingJobConfig.fromJson((args['config'] as Map).cast<String, dynamic>());
        activeJobId = jobId;
        final token = CancellationToken();
        activeToken = token;
        unawaited(_runJob(jobId, config, token, worker));
        return null;
      case 'cancelJob':
        final jobId = (call.arguments as Map)['jobId'] as String?;
        if (jobId != null && jobId == activeJobId) activeToken?.cancel();
        return null;
      default:
        throw MissingPluginException('Método desconhecido: ${call.method}');
    }
  });
}

/// Tools.locate() procura `.exe` do Windows — nunca chamar no Android. O
/// `ModelManager` exige um `Tools` não-nulo só por assinatura compartilhada
/// com o desktop; nenhum campo é lido no Android (mesmo padrão já usado em
/// `tool/android/smoke/smoke_main.dart`).
final _dummyTools = Tools(
  ffmpeg: '',
  ffprobe: '',
  whisperCli: '',
  translateLocally: '',
  sherpaSourceSeparation: '',
);

Future<void> _emit(
  MethodChannel worker,
  String kind,
  JobCheckpoint checkpoint, {
  String? message,
}) {
  return worker.invokeMethod(kind, {
    ...checkpoint.toJson(),
    if (message != null) 'message': message,
  });
}

/// Roda `runDubbingJob` de ponta a ponta e traduz o `Stream<PipelineEvent>`
/// em dois efeitos, por evento: (1) sempre reenvia como `jobProgress`/
/// `jobWarning` pro `MediaProcessingService` (para a notificação e o
/// EventChannel ao vivo — §14.4); (2) só grava em disco (`JobCheckpointStore.
/// save` + `jobStateChanged`) quando o `JobState` muda de fato — o pipeline
/// emite progresso many vezes por estágio, e gravar a cada evento seria
/// I/O redundante sem ganho (o EventChannel já cobre o "ao vivo").
///
/// Escopo do MVP (revisão de 2026-07-16, decisão do usuário): só REGISTRA em
/// que estágio o job está — não pula estágios já concluídos. `resolveResumeState`
/// (job_checkpoint_store.dart) segue correto como está; sem artefatos
/// registrados em `checkpoint.artifacts`, ele sempre recua pra
/// `JobState.created` em caso de retomada — essa é a lacuna documentada:
/// depois de morte forçada do processo, `listRecoverableJobs()` mostra o job,
/// mas retomá-lo hoje significa rodar `runDubbingJob` do zero de novo
/// (reaproveitando modelos já baixados em disco, não computação já feita).
Future<void> _runJob(
  String jobId,
  DubbingJobConfig config,
  CancellationToken token,
  MethodChannel worker,
) async {
  final jobsRoot = await jobsRootDir();
  final store = FileJobCheckpointStore(jobsRoot);
  final modelsRoot = Directory(jobsRoot).parent.path;
  final models =
      ModelManager(modelsRoot, _dummyTools, catalog: ModelCatalog.android());
  final ffmpeg = androidFFmpegCallbacks();
  final runtime = androidRuntime(
    models: models,
    diskSpace: createAndroidDiskSpaceProbe(),
    ffmpegStart: ffmpeg.start,
    ffmpegPoll: ffmpeg.poll,
    ffmpegCancel: ffmpeg.cancel,
    ffprobe: ffmpeg.ffprobe,
  );

  // O input pode ainda não existir como arquivo local (job por URL do
  // YouTube, fora do escopo M1 Android — `createDownloader: null` já recusa
  // isso no `prepare`) — um fingerprint vazio nesse caso só degrada
  // `resolveResumeState` (fora de escopo do MVP), nunca impede o job de rodar.
  var fingerprint = '';
  try {
    final stat = File(config.inputVideo).statSync();
    fingerprint = computeConfigFingerprint(
      config,
      inputSizeBytes: stat.size,
      inputLastModifiedMs: stat.modified.millisecondsSinceEpoch,
    );
  } catch (_) {}

  final now = DateTime.now();
  var checkpoint = JobCheckpoint(
    jobId: jobId,
    state: JobState.created,
    configFingerprint: fingerprint,
    createdAt: now,
    updatedAt: now,
  );
  await store.save(checkpoint);
  await _emit(worker, 'jobStateChanged', checkpoint);

  try {
    final stream = runDubbingJob(config, token, runtime: runtime);
    await for (final event in stream) {
      final applied = applyPipelineEvent(checkpoint, event);
      checkpoint = applied.checkpoint;
      await _emit(
        worker,
        event.isWarning ? 'jobWarning' : 'jobProgress',
        checkpoint,
        message: event.message,
      );
      if (applied.didTransition) {
        await store.save(checkpoint);
        await _emit(worker, 'jobStateChanged', checkpoint);
      }
    }
    checkpoint = checkpoint.copyWith(
      state: JobState.completedPendingExport,
      progress: 1.0,
      updatedAt: DateTime.now(),
    );
    await store.save(checkpoint);
    await _emit(worker, 'jobCompleted', checkpoint);
  } catch (e) {
    checkpoint = checkpoint.copyWith(
      state: token.isCancelled ? JobState.cancelled : JobState.failed,
      lastError: e.toString(),
      updatedAt: DateTime.now(),
    );
    await store.save(checkpoint);
    await _emit(worker, 'jobFailed', checkpoint, message: e.toString());
  }
}
