import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:dubbing_engine/dubbing_engine.dart';

/// Ponte Activity <-> `MediaProcessingService` (D3.3, §14.2/§14.3). O engine
/// é Dart puro e não conhece `MethodChannel`; esta é a única casa onde esses
/// dois canais aparecem do lado Dart da Activity.
const _serviceChannel = MethodChannel('omnitranslator/service');
const _serviceEvents = EventChannel('omnitranslator/service/events');

/// Novo jobId: timestamp em ms — mesmo esquema que `home_screen.dart` já usa
/// pro nome do `workDir`, então `jobId == basename(workDir)` e os dois ficam
/// trivialmente correlacionáveis (§9.3), sem precisar inventar um segundo
/// identificador.
String mintJobId() => DateTime.now().millisecondsSinceEpoch.toString();

/// Onde os checkpoints (`job.json`) vivem. Calculado aqui (lado Activity) E
/// em `service_entrypoint.dart` (lado isolate do serviço) — os dois têm que
/// concordar, senão nunca enxergam os mesmos jobs. `getApplicationSupportDirectory`
/// é estável entre os dois processos/engines porque é o mesmo app Android.
Future<String> jobsRootDir() async {
  final dir = await getApplicationSupportDirectory();
  return p.join(dir.path, 'jobs');
}

/// Evento ao vivo de um job (§14.4) — `kind` é um dos 5 nomes do §14.4
/// (`jobStateChanged`/`jobProgress`/`jobWarning`/`jobCompleted`/`jobFailed`);
/// [checkpoint] é o estado persistido correspondente (inclui `jobId` e
/// `updatedAt`, como o §14.4 exige); [message] é só do evento pontual (a
/// mensagem do `PipelineEvent`), não fica gravado no checkpoint.
class ServiceEvent {
  final String kind;
  final JobCheckpoint checkpoint;
  final String? message;
  const ServiceEvent(this.kind, this.checkpoint, this.message);

  factory ServiceEvent.fromMap(Map<String, dynamic> m) => ServiceEvent(
        m['kind'] as String,
        JobCheckpoint.fromJson(m),
        m['message'] as String?,
      );
}

/// Cliente Dart do `MediaProcessingService` (§14.2/§14.3).
///
/// `startJob`/`cancelJob` falam com o serviço VIVO via [_serviceChannel].
/// `getJob`/`listRecoverableJobs`/`exportJob` leem/escrevem `job.json`
/// diretamente, sem canal — funcionam com ou sem o serviço rodando. Essa
/// divisão (decisão D-1 do plano D3.3) é o que faz `listRecoverableJobs()`
/// funcionar mesmo depois de o processo inteiro ter morrido: um `Map`/
/// `MethodChannel` só existe enquanto o serviço vive, mas `job.json` é um
/// arquivo comum.
class MediaProcessingServiceClient {
  const MediaProcessingServiceClient();

  /// Inicia o serviço (se não estiver rodando) e manda rodar [config] sob
  /// [jobId]. [displayName] alimenta o título da notificação (§14.5) — não é
  /// recalculado no lado Kotlin porque o nome amigável (ex.: nome do arquivo
  /// escolhido por SAF) só o Dart conhece.
  Future<void> startJob(
    String jobId,
    DubbingJobConfig config, {
    required String displayName,
  }) {
    return _serviceChannel.invokeMethod('startJob', {
      'jobId': jobId,
      'displayName': displayName,
      'config': config.toJson(),
    });
  }

  Future<void> cancelJob(String jobId) {
    return _serviceChannel.invokeMethod('cancelJob', {'jobId': jobId});
  }

  /// Stream ao vivo de progresso — nunca é a única fonte de verdade (§14.4):
  /// um evento perdido (Activity morta e reaberta) se resolve relendo
  /// [getJob], não esperando um evento atrasado.
  Stream<ServiceEvent> events() {
    return _serviceEvents.receiveBroadcastStream().map(
        (raw) => ServiceEvent.fromMap((raw as Map).cast<String, dynamic>()));
  }

  Future<JobCheckpoint?> getJob(String jobId) async {
    final store = FileJobCheckpointStore(await jobsRootDir());
    return store.load(jobId);
  }

  Future<List<JobCheckpoint>> listRecoverableJobs() async {
    final store = FileJobCheckpointStore(await jobsRootDir());
    return store.listRecoverable();
  }

  /// Escopo do MVP (D-2, revisão de 2026-07-16): só marca o job como
  /// exportado no checkpoint. A cópia SAF de verdade continua sendo a
  /// Activity quem faz, com `pickExportLocation`/`copyLocalFileToUri`
  /// (`android_storage.dart`, já existente) — `exportJob` não duplica esse
  /// fluxo, só fecha o estado depois que ele termina.
  Future<void> exportJob(String jobId) async {
    final store = FileJobCheckpointStore(await jobsRootDir());
    final cp = await store.load(jobId);
    if (cp == null) return;
    await store.save(
        cp.copyWith(state: JobState.exported, updatedAt: DateTime.now()));
  }
}
