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

/// Raiz privada do app no Android (D3.4) — `jobsRootDir`/`modelsRoot`
/// (`service_entrypoint.dart`)/`settings.json` (`settings.dart`) são todos
/// irmãos previsíveis debaixo desta única raiz, em vez de cada um chamar
/// `getApplicationSupportDirectory()` por conta própria.
Future<String> appRootDir() async {
  final dir = await getApplicationSupportDirectory();
  return dir.path;
}

/// Onde os checkpoints (`job.json`) vivem. Calculado aqui (lado Activity) E
/// em `service_entrypoint.dart` (lado isolate do serviço) — os dois têm que
/// concordar, senão nunca enxergam os mesmos jobs. `getApplicationSupportDirectory`
/// é estável entre os dois processos/engines porque é o mesmo app Android.
Future<String> jobsRootDir() async => p.join(await appRootDir(), 'jobs');

/// Destino final dos vídeos dublados no Android (D3.4/D-4) — fora de
/// `jobsRootDir()` de propósito: `pipeline.dart` apaga o `workDir` do job
/// depois do mux bem-sucedido, então o `outputPath` tem que morar em outro
/// lugar pra sobreviver a essa limpeza.
Future<String> outputsRootDir() async => p.join(await appRootDir(), 'outputs');

/// Raiz dos `workDir`s de job no Android (D3.4/D-4/D-6, `AppSettings.
/// workDirBase`) — DELIBERADAMENTE separada de `jobsRootDir()`, não a mesma
/// coisa: `pipeline.dart:349-351` apaga `Directory(workDir)` inteiro após um
/// mux bem-sucedido. Se `workDirBase` fosse `jobsRootDir()`, o `job.json` de
/// um job concluído (que mora em `jobsRootDir()/<jobId>/job.json`) seria
/// apagado junto — sobreviveria só porque `_runJob` reescreve o checkpoint
/// FINAL logo depois da limpeza, o que funciona mas é frágil (qualquer
/// checkpoint intermediário no mesmo diretório vira lixo transitório sem
/// necessidade). Mantendo as duas raízes fisicamente separadas, o checkpoint
/// nunca corre risco de ser apagado pela limpeza do pipeline.
Future<String> workRootDir() async => p.join(await appRootDir(), 'work');

/// Evento ao vivo de um job (§14.4) — `kind` é um dos 5 nomes do §14.4
/// (`jobStateChanged`/`jobProgress`/`jobWarning`/`jobCompleted`/`jobFailed`);
/// [checkpoint] é o estado persistido correspondente (inclui `jobId` e
/// `updatedAt`, como o §14.4 exige); [message] é só do evento pontual (a
/// mensagem do `PipelineEvent`), não fica gravado no checkpoint.
///
/// [stage] (D3.4) é o `PipelineStage.name` cru do evento original —
/// `checkpoint.state` sozinho não basta pra reconstruir a tela de progresso
/// porque é um `JobState` DERIVADO e com perda (`jobStateForStage`, D3.3:
/// `separate`/`diarize`/`transcribe` colapsam todos em `demuxed`). Só vem
/// preenchido em `jobProgress`/`jobWarning` (`jobStateChanged` continua
/// derived-state-only, por design). [result] só vem em `jobCompleted`.
class ServiceEvent {
  final String kind;
  final JobCheckpoint checkpoint;
  final String? message;
  final String? stage;
  final DubbingResult? result;
  const ServiceEvent(this.kind, this.checkpoint, this.message,
      {this.stage, this.result});

  factory ServiceEvent.fromMap(Map<String, dynamic> m) => ServiceEvent(
        m['kind'] as String,
        JobCheckpoint.fromJson(m),
        m['message'] as String?,
        stage: m['stage'] as String?,
        result: m['result'] != null
            ? DubbingResult.fromJson((m['result'] as Map).cast<String, dynamic>())
            : null,
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
  ///
  /// Só flipa a partir de `completedPendingExport` (auditoria de
  /// 2026-07-16): marcar `exported` num job que ainda roda (ou que falhou)
  /// o faria sumir de `listRecoverableJobs()` — `exported` é terminal — sem
  /// nunca ter produzido saída.
  Future<void> exportJob(String jobId) async {
    final store = FileJobCheckpointStore(await jobsRootDir());
    final cp = await store.load(jobId);
    if (cp == null || cp.state != JobState.completedPendingExport) return;
    await store.save(
        cp.copyWith(state: JobState.exported, updatedAt: DateTime.now()));
  }
}
