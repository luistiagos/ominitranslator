import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:path/path.dart' as p;

/// Versão do formato do checkpoint. Um job gravado com schema diferente não é
/// retomado (§9.4): os arquivos são preservados, mas o job reinicia.
const int jobCheckpointSchemaVersion = 1;

/// Estados normativos de um job (§9.1).
enum JobState {
  created,
  importing,
  imported,
  demuxed,
  transcribed,
  segmented,
  translated,
  synthesized,
  fitted,
  mixed,
  completedPendingExport,
  exported,
  cancelled,
  failed;

  /// Estados dos quais não se retoma: o job acabou (bem ou mal). Note que
  /// `completedPendingExport` NÃO é terminal — dá para exportar sem reprocessar.
  bool get isTerminal =>
      this == exported || this == cancelled || this == failed;
}

/// Estado persistido de um job, gravado como `job.json` (§9.3).
class JobCheckpoint {
  final int schemaVersion;
  final String jobId;
  final JobState state;

  /// Identifica a combinação (config + input) que gerou este job. Se o job for
  /// reaberto com uma config/entrada diferente, o resultado antigo não pode ser
  /// reaproveitado (§9.4).
  final String configFingerprint;
  final double progress;

  /// Nome lógico -> path relativo ao workdir dos artefatos já produzidos.
  final Map<String, String> artifacts;
  final List<String> warnings;
  final String? lastError;
  final DateTime createdAt;
  final DateTime updatedAt;

  const JobCheckpoint({
    required this.jobId,
    required this.state,
    required this.configFingerprint,
    this.schemaVersion = jobCheckpointSchemaVersion,
    this.progress = 0.0,
    this.artifacts = const {},
    this.warnings = const [],
    this.lastError,
    required this.createdAt,
    required this.updatedAt,
  });

  JobCheckpoint copyWith({
    JobState? state,
    double? progress,
    Map<String, String>? artifacts,
    List<String>? warnings,
    String? lastError,
    DateTime? updatedAt,
  }) =>
      JobCheckpoint(
        jobId: jobId,
        state: state ?? this.state,
        configFingerprint: configFingerprint,
        schemaVersion: schemaVersion,
        progress: progress ?? this.progress,
        artifacts: artifacts ?? this.artifacts,
        warnings: warnings ?? this.warnings,
        lastError: lastError ?? this.lastError,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'jobId': jobId,
        'state': state.name,
        'configFingerprint': configFingerprint,
        'progress': progress,
        'artifacts': artifacts,
        'warnings': warnings,
        'lastError': lastError,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  /// Lança [FormatException] se o JSON estiver incompleto ou corrompido — é o
  /// que faz o `load` tratar um `.part` sobrevivente como "não existe".
  static JobCheckpoint fromJson(Map<String, dynamic> j) {
    final stateName = j['state'] as String?;
    JobState? state;
    for (final s in JobState.values) {
      if (s.name == stateName) {
        state = s;
        break;
      }
    }
    if (state == null) {
      throw FormatException('Estado de job desconhecido: $stateName');
    }
    return JobCheckpoint(
      schemaVersion: j['schemaVersion'] as int,
      jobId: j['jobId'] as String,
      state: state,
      configFingerprint: j['configFingerprint'] as String,
      progress: (j['progress'] as num?)?.toDouble() ?? 0.0,
      artifacts: (j['artifacts'] as Map?)?.map(
              (k, v) => MapEntry(k as String, v as String)) ??
          const {},
      warnings:
          (j['warnings'] as List?)?.map((e) => e as String).toList() ?? const [],
      lastError: j['lastError'] as String?,
      createdAt: DateTime.parse(j['createdAt'] as String),
      updatedAt: DateTime.parse(j['updatedAt'] as String),
    );
  }
}

/// Persistência do estado de um job (§5.7). Uma implementação só serve as duas
/// plataformas — o engine só conhece paths locais (regra #8).
abstract interface class JobCheckpointStore {
  Future<JobCheckpoint?> load(String jobId);
  Future<void> save(JobCheckpoint checkpoint);
  Future<List<JobCheckpoint>> listRecoverable();
  Future<void> delete(String jobId);
}

/// Store em disco: `<jobsRoot>/<jobId>/job.json`, com escrita atômica.
class FileJobCheckpointStore implements JobCheckpointStore {
  final String jobsRoot;
  const FileJobCheckpointStore(this.jobsRoot);

  String _jsonPath(String jobId) => p.join(jobsRoot, jobId, 'job.json');

  @override
  Future<JobCheckpoint?> load(String jobId) async {
    final file = File(_jsonPath(jobId));
    if (!file.existsSync()) return null;
    try {
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return JobCheckpoint.fromJson(data);
    } catch (_) {
      // Corrompido (ex.: processo morto durante a escrita, antes do rename):
      // trata como inexistente. Um `.part` nunca é lido.
      return null;
    }
  }

  @override
  Future<void> save(JobCheckpoint checkpoint) async {
    final jsonPath = _jsonPath(checkpoint.jobId);
    Directory(p.dirname(jsonPath)).createSync(recursive: true);
    final partPath = '$jsonPath.part';
    final part = File(partPath);
    final encoded = const JsonEncoder.withIndent('  ').convert(checkpoint.toJson());

    final raf = part.openSync(mode: FileMode.write);
    try {
      raf.writeStringSync(encoded);
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    // Valida o que foi escrito ANTES de promover: nunca publicar um job.json
    // que não parseia.
    JobCheckpoint.fromJson(
        jsonDecode(await part.readAsString()) as Map<String, dynamic>);
    if (File(jsonPath).existsSync()) File(jsonPath).deleteSync();
    part.renameSync(jsonPath);
  }

  @override
  Future<List<JobCheckpoint>> listRecoverable() async {
    final root = Directory(jobsRoot);
    if (!root.existsSync()) return [];
    final out = <JobCheckpoint>[];
    for (final entry in root.listSync()) {
      if (entry is! Directory) continue;
      final cp = await load(p.basename(entry.path));
      if (cp != null && !cp.state.isTerminal) out.add(cp);
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  @override
  Future<void> delete(String jobId) async {
    final dir = Directory(p.join(jobsRoot, jobId));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

/// Impressão digital de (config + entrada). Muda se qualquer coisa que
/// invalidaria o resultado mudar — é o que a §9.4 usa para decidir se um
/// checkpoint pode ser reaproveitado.
String computeConfigFingerprint(
  DubbingJobConfig config, {
  required int inputSizeBytes,
  required int inputLastModifiedMs,
}) {
  final parts = <String>[
    'schema=$jobCheckpointSchemaVersion',
    'src=${config.sourceLang.code}',
    'dst=${config.targetLang.code}',
    'preset=${config.preset.name}',
    'voice=${config.voiceModelId ?? ''}',
    'sid=${config.voiceSid}',
    'keepOriginal=${config.keepOriginalTrack}',
    'srt=${config.generateSrt}',
    'youtube=${config.youtubeUrl ?? ''}',
    'inputSize=$inputSizeBytes',
    'inputMtime=$inputLastModifiedMs',
  ];
  return sha256.convert(utf8.encode(parts.join('|'))).toString();
}

/// Um estágio retomável e os artefatos (nomes lógicos) que precisam existir e
/// validar para considerá-lo concluído.
typedef ResumeStage = ({JobState state, List<String> artifacts});

/// Decide de onde retomar um job (§9.4).
///
/// Devolve o estado a partir de cujo FIM se pode continuar — o pipeline roda do
/// próximo estágio. Regras:
/// - sem checkpoint, fingerprint diferente ou schema diferente → recomeça do
///   zero ([JobState.created]);
/// - senão, valida os artefatos do estado salvo; se algum não valida, RECUA
///   até o último estágio cujos artefatos (dele e dos anteriores) ainda valem.
///
/// [order] são os estágios retomáveis em ordem; [artifactValid] diz se o
/// artefato de nome lógico dado existe e está íntegro (o chamador resolve o
/// path pelo `checkpoint.artifacts`).
JobState resolveResumeState({
  required JobCheckpoint? checkpoint,
  required String currentFingerprint,
  required List<ResumeStage> order,
  required bool Function(String logicalArtifact) artifactValid,
}) {
  if (checkpoint == null) return JobState.created;
  if (checkpoint.schemaVersion != jobCheckpointSchemaVersion) {
    return JobState.created;
  }
  if (checkpoint.configFingerprint != currentFingerprint) {
    return JobState.created;
  }

  // Índice do estado salvo dentro da ordem retomável.
  final savedIdx = order.indexWhere((s) => s.state == checkpoint.state);
  // Estado fora da lista retomável (ex.: terminal): não há de onde continuar.
  final from = savedIdx >= 0 ? savedIdx : order.length - 1;

  // Recua do estado salvo até achar um cujos artefatos cumulativos validem.
  for (int i = from; i >= 0; i--) {
    var allValid = true;
    for (int j = 0; j <= i && allValid; j++) {
      for (final a in order[j].artifacts) {
        if (!artifactValid(a)) {
          allValid = false;
          break;
        }
      }
    }
    if (allValid) return order[i].state;
  }
  return JobState.created;
}
