import 'dart:io';

import 'package:dubbing_engine/dubbing_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:omnitranslator_app/src/platform/media_processing_service.dart';

/// Fake mínimo do path_provider — `getJob`/`listRecoverableJobs`/`exportJob`
/// (D-1 do plano D3.3) leem/escrevem `job.json` direto via
/// `getApplicationSupportDirectory()`, sem canal nenhum: mockar o
/// `PathProviderPlatform.instance` é o jeito documentado de testar isso sem
/// tocar um device real.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.supportPath);
  final String supportPath;
  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}

DubbingJobConfig _cfg() => DubbingJobConfig(
      inputVideo: '/sdcard/in.mp4',
      sourceLang: Lang.en,
      targetLang: Lang.pt,
      preset: Preset.fast,
      workDir: '/data/work/1',
      outputPath: '/sdcard/out.mp4',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('omnitranslator/service');
  const eventChannel = EventChannel('omnitranslator/service/events');
  const client = MediaProcessingServiceClient();

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mps_test_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(eventChannel, null);
    tmp.deleteSync(recursive: true);
  });

  group('MediaProcessingServiceClient — canal com o serviço vivo (§14.3)', () {
    test('startJob envia jobId/displayName/config.toJson()', () async {
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        received = call;
        return null;
      });

      await client.startJob('j1', _cfg(), displayName: 'meu_video.mp4');

      expect(received!.method, 'startJob');
      final args = (received!.arguments as Map).cast<String, dynamic>();
      expect(args['jobId'], 'j1');
      expect(args['displayName'], 'meu_video.mp4');
      expect(args['config'], _cfg().toJson());
    });

    test('cancelJob envia o jobId certo', () async {
      MethodCall? received;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        received = call;
        return null;
      });

      await client.cancelJob('j1');

      expect(received!.method, 'cancelJob');
      expect(received!.arguments, {'jobId': 'j1'});
    });

    test('startJob propaga PlatformException (ex.: job_in_progress)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        throw PlatformException(code: 'job_in_progress', message: 'já rodando');
      });

      expect(
        () => client.startJob('j2', _cfg(), displayName: 'x.mp4'),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'job_in_progress')),
      );
    });
  });

  group('MediaProcessingServiceClient.events() — §14.4', () {
    test('parseia kind/checkpoint/message de um evento ao vivo', () async {
      final now = DateTime.utc(2026, 7, 16, 12);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(onListen: (args, sink) {
          sink.success({
            'kind': 'jobProgress',
            'jobId': 'j1',
            'schemaVersion': jobCheckpointSchemaVersion,
            'state': 'transcribed',
            'configFingerprint': 'fp',
            'progress': 0.4,
            'artifacts': <String, String>{},
            'warnings': <String>[],
            'lastError': null,
            'createdAt': now.toIso8601String(),
            'updatedAt': now.toIso8601String(),
            'message': 'transcrevendo...',
          });
        }),
      );

      final event = await client.events().first;
      expect(event.kind, 'jobProgress');
      expect(event.checkpoint.jobId, 'j1');
      expect(event.checkpoint.state, JobState.transcribed);
      expect(event.checkpoint.progress, 0.4);
      expect(event.message, 'transcrevendo...');
    });

    test('parseia stage quando presente (D3.4/D-2)', () {
      final now = DateTime.utc(2026, 7, 16);
      final event = ServiceEvent.fromMap({
        'kind': 'jobProgress',
        'jobId': 'j1',
        'schemaVersion': jobCheckpointSchemaVersion,
        'state': 'demuxed',
        'configFingerprint': 'fp',
        'progress': 0.2,
        'artifacts': <String, String>{},
        'warnings': <String>[],
        'lastError': null,
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
        'stage': 'transcribe',
      });
      expect(event.stage, 'transcribe');
      expect(event.result, isNull);
    });

    test('stage ausente (ex.: jobStateChanged) vira null, não quebra (D-2)', () {
      final now = DateTime.utc(2026, 7, 16);
      final event = ServiceEvent.fromMap({
        'kind': 'jobStateChanged',
        'jobId': 'j1',
        'schemaVersion': jobCheckpointSchemaVersion,
        'state': 'demuxed',
        'configFingerprint': 'fp',
        'progress': 0.0,
        'artifacts': <String, String>{},
        'warnings': <String>[],
        'lastError': null,
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
      });
      expect(event.stage, isNull);
    });

    test('parseia result quando presente em jobCompleted (D3.4/D-3)', () {
      final now = DateTime.utc(2026, 7, 16);
      final event = ServiceEvent.fromMap({
        'kind': 'jobCompleted',
        'jobId': 'j1',
        'schemaVersion': jobCheckpointSchemaVersion,
        'state': 'completedPendingExport',
        'configFingerprint': 'fp',
        'progress': 1.0,
        'artifacts': <String, String>{},
        'warnings': <String>[],
        'lastError': null,
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
        'result': const DubbingResult(
          outputVideo: '/sdcard/out.mp4',
          voiceOverMode: false,
          segmentsWithOverflow: 0,
          elapsed: Duration(seconds: 5),
        ).toJson(),
      });
      expect(event.result, isNotNull);
      expect(event.result!.outputVideo, '/sdcard/out.mp4');
    });

    test('result ausente (jobProgress/jobFailed) vira null, não quebra', () {
      final now = DateTime.utc(2026, 7, 16);
      final event = ServiceEvent.fromMap({
        'kind': 'jobFailed',
        'jobId': 'j1',
        'schemaVersion': jobCheckpointSchemaVersion,
        'state': 'failed',
        'configFingerprint': 'fp',
        'progress': 0.5,
        'artifacts': <String, String>{},
        'warnings': <String>[],
        'lastError': 'boom',
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
        'message': 'boom',
      });
      expect(event.result, isNull);
    });
  });

  group(
      'getJob/listRecoverableJobs/exportJob — sem canal (D-1: sobrevivem à '
      'morte do serviço)', () {
    test('getJob lê o job.json gravado por outro FileJobCheckpointStore',
        () async {
      final jobsRoot = await jobsRootDir();
      final store = FileJobCheckpointStore(jobsRoot);
      final now = DateTime.utc(2026, 7, 16);
      await store.save(JobCheckpoint(
        jobId: 'j1',
        state: JobState.segmented,
        configFingerprint: 'fp',
        createdAt: now,
        updatedAt: now,
      ));

      final loaded = await client.getJob('j1');
      expect(loaded, isNotNull);
      expect(loaded!.state, JobState.segmented);
    });

    test('getJob de job inexistente é null', () async {
      expect(await client.getJob('nao_existe'), isNull);
    });

    test('listRecoverableJobs só traz os não-terminais', () async {
      final jobsRoot = await jobsRootDir();
      final store = FileJobCheckpointStore(jobsRoot);
      final now = DateTime.utc(2026, 7, 16);
      await store.save(JobCheckpoint(
          jobId: 'a',
          state: JobState.transcribed,
          configFingerprint: 'fp',
          createdAt: now,
          updatedAt: now));
      await store.save(JobCheckpoint(
          jobId: 'b',
          state: JobState.exported,
          configFingerprint: 'fp',
          createdAt: now,
          updatedAt: now));

      final rec = await client.listRecoverableJobs();
      expect(rec.map((c) => c.jobId), ['a']);
    });

    test('exportJob (D-2) só marca exported no checkpoint, não copia nada',
        () async {
      final jobsRoot = await jobsRootDir();
      final store = FileJobCheckpointStore(jobsRoot);
      final now = DateTime.utc(2026, 7, 16);
      await store.save(JobCheckpoint(
          jobId: 'j1',
          state: JobState.completedPendingExport,
          configFingerprint: 'fp',
          createdAt: now,
          updatedAt: now));

      await client.exportJob('j1');

      final after = await store.load('j1');
      expect(after!.state, JobState.exported);
    });

    test('exportJob de job inexistente não lança', () async {
      await client.exportJob('fantasma');
    });

    test('exportJob de job não-concluído não muda o estado (auditoria)', () async {
      // `exported` é terminal — flipar um job em andamento o faria sumir de
      // listRecoverableJobs() sem nunca ter produzido saída.
      final jobsRoot = await jobsRootDir();
      final store = FileJobCheckpointStore(jobsRoot);
      final now = DateTime.utc(2026, 7, 16);
      await store.save(JobCheckpoint(
          jobId: 'j2',
          state: JobState.transcribed,
          configFingerprint: 'fp',
          createdAt: now,
          updatedAt: now));

      await client.exportJob('j2');

      expect((await store.load('j2'))!.state, JobState.transcribed);
    });
  });

  test('jobsRootDir() é <applicationSupport>/jobs', () async {
    final root = await jobsRootDir();
    expect(root, p.join(tmp.path, 'jobs'));
  });

  test('appRootDir()/outputsRootDir()/workRootDir() são irmãos previsíveis '
      '(D3.4)', () async {
    expect(await appRootDir(), tmp.path);
    expect(await outputsRootDir(), p.join(tmp.path, 'outputs'));
    expect(await workRootDir(), p.join(tmp.path, 'work'));
    // outputsRootDir/workRootDir são DIFERENTES de jobsRootDir de propósito
    // (D3.4): pipeline.dart apaga o workDir de um job bem-sucedido, e isso
    // não pode arriscar levar o checkpoint (jobsRootDir/<jobId>/job.json)
    // junto.
    expect(await outputsRootDir(), isNot(await jobsRootDir()));
    expect(await workRootDir(), isNot(await jobsRootDir()));
  });

  test('mintJobId() gera ids distintos e monotônicos', () async {
    final a = mintJobId();
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final b = mintJobId();
    expect(a, isNot(b));
    expect(int.parse(b) >= int.parse(a), isTrue);
  });
}
