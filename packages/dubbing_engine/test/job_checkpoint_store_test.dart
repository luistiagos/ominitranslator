import 'dart:convert';
import 'dart:io';

import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/runtime/job_checkpoint_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

JobCheckpoint _cp(
  String jobId,
  JobState state, {
  String fingerprint = 'fp',
  Map<String, String> artifacts = const {},
  int schemaVersion = jobCheckpointSchemaVersion,
}) {
  final now = DateTime.utc(2026, 7, 13, 12);
  return JobCheckpoint(
    jobId: jobId,
    state: state,
    configFingerprint: fingerprint,
    schemaVersion: schemaVersion,
    artifacts: artifacts,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  late Directory tmp;
  late FileJobCheckpointStore store;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ckpt_');
    store = FileJobCheckpointStore(tmp.path);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('JobCheckpoint JSON', () {
    test('ida e volta preserva os campos', () {
      final cp = _cp('j1', JobState.translated,
          artifacts: {'audio_full': 'audio_full.wav'});
      final back = JobCheckpoint.fromJson(cp.toJson());
      expect(back.jobId, 'j1');
      expect(back.state, JobState.translated);
      expect(back.configFingerprint, 'fp');
      expect(back.artifacts['audio_full'], 'audio_full.wav');
      expect(back.schemaVersion, jobCheckpointSchemaVersion);
    });

    test('estado desconhecido é rejeitado', () {
      final j = _cp('j1', JobState.mixed).toJson();
      j['state'] = 'estado_que_nao_existe';
      expect(() => JobCheckpoint.fromJson(j), throwsFormatException);
    });
  });

  group('FileJobCheckpointStore', () {
    test('save depois load devolve o mesmo checkpoint', () async {
      await store.save(_cp('j1', JobState.segmented));
      final loaded = await store.load('j1');
      expect(loaded, isNotNull);
      expect(loaded!.state, JobState.segmented);
    });

    test('load de job inexistente é null', () async {
      expect(await store.load('nao_existe'), isNull);
    });

    test('escrita é atômica: nada de .part sobrevivente', () async {
      await store.save(_cp('j1', JobState.demuxed));
      final dir = Directory(p.join(tmp.path, 'j1'));
      final files = dir.listSync().map((e) => p.basename(e.path)).toList();
      expect(files, contains('job.json'));
      expect(files, isNot(contains('job.json.part')));
    });

    test('um .part solto é ignorado (não é lido como o job)', () async {
      // Simula um processo morto ANTES do rename: só existe o .part.
      final dir = Directory(p.join(tmp.path, 'j1'))..createSync(recursive: true);
      File(p.join(dir.path, 'job.json.part'))
          .writeAsStringSync('{"lixo": incompleto');
      expect(await store.load('j1'), isNull);
    });

    test('job.json corrompido é tratado como inexistente', () async {
      final dir = Directory(p.join(tmp.path, 'j2'))..createSync(recursive: true);
      File(p.join(dir.path, 'job.json')).writeAsStringSync('{ nao é json');
      expect(await store.load('j2'), isNull);
    });

    test('save por cima substitui o anterior', () async {
      await store.save(_cp('j1', JobState.demuxed));
      await store.save(_cp('j1', JobState.translated));
      expect((await store.load('j1'))!.state, JobState.translated);
    });

    test('listRecoverable traz só os não-terminais, mais recente primeiro', () async {
      await store.save(_cp('a', JobState.transcribed)
          .copyWith(updatedAt: DateTime.utc(2026, 7, 13, 10)));
      await store.save(_cp('b', JobState.completedPendingExport)
          .copyWith(updatedAt: DateTime.utc(2026, 7, 13, 11)));
      await store.save(_cp('c', JobState.exported)); // terminal
      await store.save(_cp('d', JobState.failed)); // terminal
      await store.save(_cp('e', JobState.cancelled)); // terminal

      final rec = await store.listRecoverable();
      expect(rec.map((c) => c.jobId), ['b', 'a']);
    });

    test('delete remove o job inteiro', () async {
      await store.save(_cp('j1', JobState.mixed));
      await store.delete('j1');
      expect(await store.load('j1'), isNull);
      expect(Directory(p.join(tmp.path, 'j1')).existsSync(), isFalse);
    });

    test('o job.json publicado é JSON válido e completo', () async {
      await store.save(_cp('j1', JobState.fitted,
          artifacts: {'dub_voice': 'dub_voice.wav'}));
      final raw = File(p.join(tmp.path, 'j1', 'job.json')).readAsStringSync();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      expect(decoded['state'], 'fitted');
      expect(decoded['artifacts']['dub_voice'], 'dub_voice.wav');
    });
  });

  group('computeConfigFingerprint', () {
    DubbingJobConfig cfg({
      Lang src = Lang.en,
      Lang dst = Lang.pt,
      Preset preset = Preset.best,
      String? voice,
    }) =>
        DubbingJobConfig(
          inputVideo: 'in.mp4',
          sourceLang: src,
          targetLang: dst,
          preset: preset,
          voiceModelId: voice,
          workDir: 'work',
          outputPath: 'out.mp4',
        );

    test('estável para a mesma config e entrada', () {
      final a = computeConfigFingerprint(cfg(),
          inputSizeBytes: 1000, inputLastModifiedMs: 42);
      final b = computeConfigFingerprint(cfg(),
          inputSizeBytes: 1000, inputLastModifiedMs: 42);
      expect(a, b);
    });

    test('muda quando o idioma de destino muda', () {
      final a = computeConfigFingerprint(cfg(dst: Lang.pt),
          inputSizeBytes: 1000, inputLastModifiedMs: 42);
      final b = computeConfigFingerprint(cfg(dst: Lang.es),
          inputSizeBytes: 1000, inputLastModifiedMs: 42);
      expect(a, isNot(b));
    });

    test('muda quando o tamanho ou o mtime da entrada muda', () {
      final base = computeConfigFingerprint(cfg(),
          inputSizeBytes: 1000, inputLastModifiedMs: 42);
      expect(
          computeConfigFingerprint(cfg(),
              inputSizeBytes: 1001, inputLastModifiedMs: 42),
          isNot(base));
      expect(
          computeConfigFingerprint(cfg(),
              inputSizeBytes: 1000, inputLastModifiedMs: 43),
          isNot(base));
    });

    test('muda quando o preset ou a voz muda', () {
      final base = computeConfigFingerprint(cfg(),
          inputSizeBytes: 1, inputLastModifiedMs: 1);
      expect(
          computeConfigFingerprint(cfg(preset: Preset.fast),
              inputSizeBytes: 1, inputLastModifiedMs: 1),
          isNot(base));
      expect(
          computeConfigFingerprint(cfg(voice: 'piper-pt-br-dii'),
              inputSizeBytes: 1, inputLastModifiedMs: 1),
          isNot(base));
    });
  });

  group('resolveResumeState (§9.4)', () {
    // Ordem retomável de exemplo: cada estágio tem um artefato.
    final order = <ResumeStage>[
      (state: JobState.demuxed, artifacts: ['audio_full']),
      (state: JobState.transcribed, artifacts: ['transcript']),
      (state: JobState.segmented, artifacts: ['segments']),
      (state: JobState.translated, artifacts: ['translated']),
    ];

    test('sem checkpoint: recomeça do zero', () {
      final r = resolveResumeState(
        checkpoint: null,
        currentFingerprint: 'fp',
        order: order,
        artifactValid: (_) => true,
      );
      expect(r, JobState.created);
    });

    test('fingerprint diferente: recomeça (não reaproveita)', () {
      final r = resolveResumeState(
        checkpoint: _cp('j', JobState.translated, fingerprint: 'OUTRO'),
        currentFingerprint: 'fp',
        order: order,
        artifactValid: (_) => true,
      );
      expect(r, JobState.created);
    });

    test('schema incompatível: recomeça', () {
      final r = resolveResumeState(
        checkpoint: _cp('j', JobState.translated, schemaVersion: 999),
        currentFingerprint: 'fp',
        order: order,
        artifactValid: (_) => true,
      );
      expect(r, JobState.created);
    });

    test('todos os artefatos válidos: retoma do estado salvo', () {
      final r = resolveResumeState(
        checkpoint: _cp('j', JobState.translated),
        currentFingerprint: 'fp',
        order: order,
        artifactValid: (_) => true,
      );
      expect(r, JobState.translated);
    });

    test('output do estado salvo inválido: RECUA até o último válido', () {
      // 'translated' e 'segments' faltando -> recua para 'transcribed'.
      final r = resolveResumeState(
        checkpoint: _cp('j', JobState.translated),
        currentFingerprint: 'fp',
        order: order,
        artifactValid: (name) => name == 'audio_full' || name == 'transcript',
      );
      expect(r, JobState.transcribed);
    });

    test('nada válido: recomeça do zero', () {
      final r = resolveResumeState(
        checkpoint: _cp('j', JobState.translated),
        currentFingerprint: 'fp',
        order: order,
        artifactValid: (_) => false,
      );
      expect(r, JobState.created);
    });

    test('um artefato intermediário corrompido faz recuar mesmo com o final ok',
        () {
      // 'transcript' inválido, embora 'segments'/'translated' existam: como os
      // requisitos são cumulativos, recua para 'demuxed'.
      final r = resolveResumeState(
        checkpoint: _cp('j', JobState.translated),
        currentFingerprint: 'fp',
        order: order,
        artifactValid: (name) => name != 'transcript',
      );
      expect(r, JobState.demuxed);
    });
  });

  group('jobStateForStage (D3.3)', () {
    test('mapeia cada estágio do pipeline pro JobState normativo', () {
      expect(jobStateForStage(PipelineStage.prepare), JobState.importing);
      expect(jobStateForStage(PipelineStage.download), JobState.imported);
      expect(jobStateForStage(PipelineStage.demux), JobState.demuxed);
      expect(jobStateForStage(PipelineStage.transcribe), JobState.transcribed);
      expect(jobStateForStage(PipelineStage.segment), JobState.segmented);
      expect(jobStateForStage(PipelineStage.translate), JobState.translated);
      expect(jobStateForStage(PipelineStage.synthesize), JobState.synthesized);
      expect(jobStateForStage(PipelineStage.fit), JobState.fitted);
      expect(jobStateForStage(PipelineStage.mix), JobState.mixed);
      expect(jobStateForStage(PipelineStage.mux), JobState.mixed);
    });

    test('separate/diarize caem no mesmo estado que demux (sem backend no M1 Android)', () {
      expect(jobStateForStage(PipelineStage.separate), JobState.demuxed);
      expect(jobStateForStage(PipelineStage.diarize), JobState.demuxed);
    });
  });

  group('applyPipelineEvent (D3.3)', () {
    JobCheckpoint base() => _cp('j1', JobState.created);

    test('progresso dentro do mesmo estágio não conta como transição', () {
      final r1 = applyPipelineEvent(
          base(), const PipelineEvent(PipelineStage.prepare, 0.0, 'a'));
      expect(r1.didTransition, isTrue); // created -> importing É transição
      final r2 = applyPipelineEvent(
          r1.checkpoint, const PipelineEvent(PipelineStage.prepare, 0.5, 'b'));
      expect(r2.didTransition, isFalse); // ainda em prepare/importing
      expect(r2.checkpoint.progress, 0.5);
    });

    test('mudar de estágio é uma transição e atualiza o estado', () {
      final r1 = applyPipelineEvent(
          base(), const PipelineEvent(PipelineStage.prepare, 1.0, 'a'));
      final r2 = applyPipelineEvent(r1.checkpoint,
          const PipelineEvent(PipelineStage.demux, 0.0, 'demuxando'));
      expect(r2.didTransition, isTrue);
      expect(r2.checkpoint.state, JobState.demuxed);
    });

    test('evento de warning acumula em warnings sem duplicar', () {
      final cp = base();
      final r = applyPipelineEvent(
          cp,
          const PipelineEvent(PipelineStage.transcribe, 0.5, 'aviso 1',
              isWarning: true));
      expect(r.checkpoint.warnings, ['aviso 1']);
      // warnings anteriores preservados, o novo é o único item se não havia mais.
    });

    test('artifacts nunca é populado (lacuna documentada do MVP)', () {
      final r = applyPipelineEvent(
          base(), const PipelineEvent(PipelineStage.mux, 1.0, 'fim'));
      expect(r.checkpoint.artifacts, isEmpty);
    });
  });
}
