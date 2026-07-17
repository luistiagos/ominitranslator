import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:dubbing_engine/dubbing_engine.dart';
import 'package:path/path.dart' as p;
import '../platform/media_processing_service.dart';
import 'settings.dart';

/// Argumentos enviados ao isolate que executa o pipeline de dublagem.
class _JobArgs {
  final SendPort sendPort;
  final DubbingJobConfig config;
  final Tools tools;
  final String modelsRoot;
  const _JobArgs(this.sendPort, this.config, this.tools, this.modelsRoot);
}

/// Roda o pipeline num isolate próprio para não travar a UI (a síntese
/// ONNX e os buffers de áudio são pesados e síncronos).
Future<void> _jobEntry(_JobArgs args) async {
  final controlPort = ReceivePort();
  args.sendPort.send(('control', controlPort.sendPort));
  final token = CancellationToken();
  controlPort.listen((msg) {
    if (msg == 'cancel') token.cancel();
  });
  try {
    DubbingResult? result;
    final stream = runDubbingJob(
      args.config,
      token,
      runtime: desktopRuntime(
        tools: args.tools,
        models: ModelManager(args.modelsRoot, args.tools),
      ),
      onDone: (r) => result = r,
    );
    await for (final event in stream) {
      args.sendPort.send(('event', event));
    }
    args.sendPort.send(('done', result));
  } catch (e) {
    args.sendPort.send(('error', e.toString()));
  } finally {
    controlPort.close();
  }
}

class AppState extends ChangeNotifier {
  final Tools tools;
  final ModelManager modelManager;

  /// Probe de espaço livre. A UI é compartilhada com o Android, onde o
  /// `StatFs` vem por MethodChannel — por isso é injetável e assíncrono.
  final DiskSpaceProbe diskSpace;

  AppSettings settings;

  AppState(
    this.tools,
    this.modelManager, {
    this.diskSpace = const WindowsDiskSpaceProbe(),
    AppSettings? initialSettings,
  }) : settings = initialSettings ?? AppSettings.load() {
    refreshModelStates();
    // D3.4: no Android o foreground service pode manter um job vivo depois
    // que a Activity/AppState é destruída e recriada (app trocado, reaberto)
    // — reconstruir AppState nesse meio tempo apagaria o workDir de um job
    // EM ANDAMENTO. Os diretórios abandonados no Android ficam acumulando
    // (pendência documentada, não regressão: hoje nada limpa isso também).
    if (!Platform.isAndroid) _cleanupOldWorkDirs();
  }

  /// Remove diretórios de trabalho de jobs antigos (que falharam ou foram
  /// cancelados). Só apaga subdiretórios cujo nome é um timestamp gerado
  /// pelo próprio app, para nunca tocar em dados do usuário. Só roda no
  /// desktop — ver o guard no construtor.
  void _cleanupOldWorkDirs() {
    final base = Directory(settings.workDirBase);
    if (!base.existsSync()) return;
    final timestampName = RegExp(r'^\d{13}$');
    for (final entry in base.listSync()) {
      if (entry is Directory &&
          timestampName.hasMatch(p.basename(entry.path))) {
        try {
          entry.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  void setWorkDirBase(String path) {
    settings = settings.copyWith(workDirBase: path);
    unawaited(settings.save());
    notifyListeners();
  }

  /// Define o navegador de cookies do YouTube, limpando o arquivo de
  /// cookies (as duas opções são mutuamente exclusivas).
  void setYtDlpCookiesFromBrowser(String browser) {
    settings = settings.copyWith(
      ytDlpCookiesFromBrowser: browser,
      ytDlpCookiesFile: '',
    );
    unawaited(settings.save());
    notifyListeners();
  }

  /// Define o arquivo cookies.txt do YouTube, limpando a seleção de
  /// navegador (as duas opções são mutuamente exclusivas).
  void setYtDlpCookiesFile(String file) {
    settings = settings.copyWith(
      ytDlpCookiesFile: file,
      ytDlpCookiesFromBrowser: '',
    );
    unawaited(settings.save());
    notifyListeners();
  }

  /// Define a voz fixa da dublagem (vazio = automática por falante).
  void setVoice(String modelId, int sid) {
    settings = settings.copyWith(voiceModelId: modelId, voiceSid: sid);
    unawaited(settings.save());
    notifyListeners();
  }

  final Map<String, ModelState> _modelStates = {};
  Map<String, ModelState> get modelStates => _modelStates;

  DubbingJobConfig? currentJob;

  /// jobId do job Android em andamento (null no desktop — o isolate não tem
  /// conceito de jobId, D3.4/D-1). `jobId == basename(workDir)`, convenção
  /// já documentada em `mintJobId()`.
  String? currentJobId;
  final List<PipelineEvent> jobEvents = [];
  DubbingResult? jobResult;
  String? jobError;
  bool jobRunning = false;

  Isolate? _jobIsolate;
  ReceivePort? _jobReceivePort;
  ReceivePort? _jobErrorPort;
  ReceivePort? _jobExitPort;
  SendPort? _jobControlPort;
  bool _cancelRequested = false;
  bool _jobFinished = false;

  StreamSubscription<ServiceEvent>? _androidEventsSub;

  Future<void> refreshModelStates() async {
    for (final entry in modelManager.catalog.entries) {
      _modelStates[entry.id] = modelManager.stateOf(entry.id);
    }
    notifyListeners();
  }

  /// [displayName] só é usado no Android (título da notificação do
  /// serviço, §14.5) — ignorado no desktop.
  Future<void> startJob(DubbingJobConfig config, {String? displayName}) async {
    if (jobRunning) {
      throw StateError('Já existe uma dublagem em andamento');
    }
    if (Platform.isAndroid) {
      await _startAndroidJob(config, displayName);
      return;
    }
    currentJob = config;
    jobEvents.clear();
    jobResult = null;
    jobError = null;
    jobRunning = true;
    _jobControlPort = null;
    _cancelRequested = false;
    _jobFinished = false;
    notifyListeners();

    final port = ReceivePort();
    _jobReceivePort = port;
    port.listen((msg) {
      final (type, payload) = msg as (String, Object?);
      switch (type) {
        case 'control':
          _jobControlPort = payload as SendPort;
          if (_cancelRequested) _jobControlPort!.send('cancel');
        case 'event':
          jobEvents.add(payload as PipelineEvent);
        case 'done':
          jobResult = payload as DubbingResult?;
          _finishJob();
        case 'error':
          jobError = payload as String;
          _finishJob();
      }
      notifyListeners();
    });

    // Erros não capturados dentro do isolate e morte inesperada (ex.: falta
    // de memória) também precisam destravar a UI — sem isso o app ficaria
    // preso em "executando" para sempre.
    final errorPort = ReceivePort();
    _jobErrorPort = errorPort;
    errorPort.listen((msg) {
      if (_jobFinished) return;
      final errorList = msg as List<dynamic>;
      jobError = 'Erro inesperado na dublagem: ${errorList.first}';
      _finishJob();
      notifyListeners();
    });

    final exitPort = ReceivePort();
    _jobExitPort = exitPort;
    exitPort.listen((_) {
      if (_jobFinished) return;
      jobError =
          'O processo de dublagem encerrou inesperadamente '
          '(possível falta de memória). Tente um vídeo mais curto ou '
          'libere memória e tente novamente.';
      _finishJob();
      notifyListeners();
    });

    try {
      _jobIsolate = await Isolate.spawn(
        _jobEntry,
        _JobArgs(port.sendPort, config, tools, modelManager.modelsRoot),
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
      );
    } catch (e) {
      jobError = 'Não foi possível iniciar a dublagem: $e';
      _finishJob();
      notifyListeners();
    }
  }

  void _finishJob() {
    _jobFinished = true;
    jobRunning = false;
    _closeJobPort();
  }

  void _closeJobPort() {
    _jobReceivePort?.close();
    _jobReceivePort = null;
    _jobErrorPort?.close();
    _jobErrorPort = null;
    _jobExitPort?.close();
    _jobExitPort = null;
    _jobControlPort = null;
    _jobIsolate = null;
  }

  /// Contraparte Android de `startJob` (D3.4/D-1) — em vez de um isolate
  /// local, fala com o `MediaProcessingService` real via
  /// `MediaProcessingServiceClient` (D3.3). jobId = basename(workDir), a
  /// mesma convenção que `mintJobId()` documenta — não inventa um segundo
  /// id, reaproveita o timestamp que `home_screen.dart` já usou pro workDir.
  Future<void> _startAndroidJob(
    DubbingJobConfig config,
    String? displayName,
  ) async {
    final jobId = p.basename(config.workDir);
    currentJob = config;
    currentJobId = jobId;
    jobEvents.clear();
    jobResult = null;
    jobError = null;
    jobRunning = true;
    notifyListeners();

    const client = MediaProcessingServiceClient();

    // Assina ANTES de chamar startJob: events() é um stream global do
    // serviço (não filtrado na origem por jobId) — se assinasse depois,
    // arriscaria perder o primeiro jobStateChanged (state=created).
    await _androidEventsSub?.cancel();
    _androidEventsSub = client.events().listen((evt) {
      if (evt.checkpoint.jobId != jobId) return;
      switch (evt.kind) {
        case 'jobProgress':
        case 'jobWarning':
          // `stage` só vem preenchido nesses dois kinds (D-2) -- é o
          // PipelineStage cru que reconstrói o PipelineEvent real, pro
          // progress_screen.dart renderizar exatamente como no desktop.
          if (evt.stage != null) {
            jobEvents.add(PipelineEvent(
              PipelineStage.values.byName(evt.stage!),
              evt.checkpoint.progress,
              evt.message ?? '',
              isWarning: evt.kind == 'jobWarning',
            ));
          }
        case 'jobCompleted':
          jobResult = evt.result;
          _finishAndroidJob();
        case 'jobFailed':
          jobError = evt.message ?? 'Falha desconhecida na dublagem.';
          _finishAndroidJob();
        // 'jobStateChanged' não carrega `stage` (D-2, por design) -- nada a
        // refletir em jobEvents; quem lê isso é listRecoverableJobs(), não
        // a tela de progresso ao vivo.
      }
      notifyListeners();
    });

    try {
      await client.startJob(
        jobId,
        config,
        displayName: displayName ?? p.basename(config.inputVideo),
      );
    } catch (e) {
      jobError = 'Não foi possível iniciar a dublagem: $e';
      _finishAndroidJob();
      notifyListeners();
    }
  }

  void _finishAndroidJob() {
    jobRunning = false;
    unawaited(_androidEventsSub?.cancel());
    _androidEventsSub = null;
  }

  void cancelJob() {
    if (Platform.isAndroid) {
      if (currentJobId != null) {
        unawaited(const MediaProcessingServiceClient().cancelJob(currentJobId!));
      }
      jobRunning = false;
      notifyListeners();
      return;
    }
    _cancelRequested = true;
    _jobControlPort?.send('cancel');
    jobRunning = false;
    notifyListeners();
  }

  @override
  void dispose() {
    if (Platform.isAndroid) {
      unawaited(_androidEventsSub?.cancel());
    } else {
      _jobControlPort?.send('cancel');
      _jobReceivePort?.close();
      _jobIsolate?.kill(priority: Isolate.beforeNextEvent);
    }
    super.dispose();
  }
}
