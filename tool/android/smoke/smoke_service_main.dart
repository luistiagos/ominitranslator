// Smoke test on-device do MediaProcessingService (D3.3/AT-4) -- prova o
// servico em foreground de ponta a ponta SEM esperar a UI de producao (D3.4,
// que ainda nao existe). Cobre startJob/cancelJob/listRecoverableJobs
// (paginas 14.2/14.3) e os 5 cenarios de ciclo de vida do 14.6.
//
// COMO RODAR (mesmo padrao ja usado na D3.1/D3.2 -- swap temporario, nunca
// comitado):
//   1. Rodar tool/android/fetch_native_libs.ps1 (P2 + F2) se ainda nao rodou.
//   2. adb push um clipe curto (~20-30s, qualquer MP4 com audio falado) para
//      <externalStorage>/smoke_service_input.mp4 -- NAO usar um video de 30
//      min aqui: os 5 cenarios do 14.6 sao testados manualmente abaixo, nao
//      exigem a duracao real (o requisito e "sobrevive", nao "sobrevive
//      especificamente por 30min" -- 30min so aumenta o tempo de espera do
//      teste manual sem provar nada a mais sobre a arquitetura do servico).
//   3. cp app/lib/main.dart /tmp/main.dart.backup
//   4. cp tool/android/smoke/smoke_service_main.dart app/lib/main.dart
//   5. flutter build apk --debug --target-platform android-arm64
//   6. adb install -r ...
//   7. adb shell pm grant com.luistiagos.omnitranslator android.permission.POST_NOTIFICATIONS
//      (a UI de producao ainda nao pede essa permissao em runtime -- D3.4;
//      sem conceder manualmente aqui, a notificacao do servico nao aparece,
//      mas o servico roda igual)
//   8. abrir o app; apertar "1. Iniciar job curto"; observar a notificacao
//      "Processamento de video" aparecer e o log de eventos avancar.
//   9. cp /tmp/main.dart.backup app/lib/main.dart (reverte -- nao comitar o
//      swap).
//
// ROTEIRO MANUAL DOS 5 CENARIOS DO SS14.6 (rodar cada um com um job ativo):
//   a) tela apaga: apertar o botao de power, esperar uns 10s, reacender --
//      notificacao deve continuar avancando (prova que o processo nao foi
//      suspenso).
//   b) troca de app: apertar Home, abrir outro app por uns 10s, voltar --
//      mesma checagem.
//   c) rotacao/recriacao da Activity: girar o device (se a orientacao nao
//      estiver travada) -- o log de eventos deve continuar (reconectou ao
//      servico via onServiceConnected de novo).
//   d) Activity removida da memoria com o servico vivo: em
//      Configuracoes > Opcoes do desenvolvedor > "Nao manter atividades",
//      ligar; trocar de app (o Android destroi a Activity); voltar --
//      notificacao deve ter continuado a avancar o tempo todo (prova que o
//      job sobrevive independente da Activity: startForegroundService, nao
//      so bindService).
//   e) morte forcada do processo: `adb shell am force-stop
//      com.luistiagos.omnitranslator` com um job ativo -- reabrir o app e
//      apertar "3. Jobs recuperaveis": o job deve aparecer (prova o
//      checkpoint gravado), mas retomar hoje reinicia o pipeline do zero
//      (lacuna documentada do MVP, ver job_checkpoint_store.dart).
import 'dart:async';
import 'dart:io';

import 'package:dubbing_engine/dubbing_engine.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'src/platform/media_processing_service.dart';
// Igual ao main.dart de producao: mantem serviceMain (o entrypoint headless
// do MediaProcessingService) no snapshot -- sem isto o engine headless falha
// com "Could not resolve main entrypoint function" (achado do smoke
// on-device de 2026-07-17).
// ignore: unused_import
import 'src/service_entrypoint.dart' show serviceMain;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _SmokeServiceScreen()));
}

class _SmokeServiceScreen extends StatefulWidget {
  const _SmokeServiceScreen();
  @override
  State<_SmokeServiceScreen> createState() => _SmokeServiceScreenState();
}

class _SmokeServiceScreenState extends State<_SmokeServiceScreen> {
  String _log = '';
  String? _activeJobId;
  StreamSubscription<ServiceEvent>? _sub;
  final _client = const MediaProcessingServiceClient();

  void _append(String s) => setState(() => _log = '$_log\n$s');

  @override
  void initState() {
    super.initState();
    _sub = _client.events().listen(
      (event) {
        final cp = event.checkpoint;
        _append('[EVENTO] ${event.kind} jobId=${cp.jobId} state=${cp.state.name} '
            'progress=${(cp.progress * 100).toStringAsFixed(0)}% '
            '${event.message ?? ""}');
      },
      onError: (Object e) => _append('[EVENTO] erro: $e'),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _startShortJob() async {
    final extDir = await getExternalStorageDirectory();
    final inputVideo = '${extDir!.path}/smoke_service_input.mp4';
    if (!File(inputVideo).existsSync()) {
      _append('SKIP: adb push um clipe curto (~20-30s) pra $inputVideo primeiro');
      return;
    }
    final jobId = mintJobId();
    _activeJobId = jobId;
    final config = DubbingJobConfig(
      inputVideo: inputVideo,
      sourceLang: Lang.en,
      targetLang: Lang.pt,
      preset: Preset.fast,
      // jobId == basename(workDir) (§9.3) -- mesmo esquema que home_screen.dart usa.
      workDir: '${extDir.path}/smoke_service_work/$jobId',
      outputPath: '${extDir.path}/smoke_service_out.mp4',
    );
    _append('Iniciando job $jobId...');
    try {
      await _client.startJob(jobId, config, displayName: 'smoke_service_input.mp4');
      _append('startJob() retornou -- acompanhe pelos eventos acima e pela '
          'notificação "Processamento de vídeo".');
    } catch (e) {
      _append('startJob() FALHOU -- $e');
    }
  }

  Future<void> _cancelJob() async {
    final jobId = _activeJobId;
    if (jobId == null) {
      _append('Nenhum job iniciado nesta sessão do harness.');
      return;
    }
    await _client.cancelJob(jobId);
    _append('cancelJob($jobId) enviado.');
  }

  Future<void> _listRecoverable() async {
    final jobs = await _client.listRecoverableJobs();
    _append('listRecoverableJobs(): ${jobs.length} job(s)');
    for (final j in jobs) {
      _append('  ${j.jobId}: ${j.state.name} '
          '(${(j.progress * 100).toStringAsFixed(0)}%), atualizado ${j.updatedAt}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Smoke test D3.3 (temporário)')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              ElevatedButton(
                  onPressed: _startShortJob, child: const Text('1. Iniciar job curto')),
              ElevatedButton(onPressed: _cancelJob, child: const Text('2. Cancelar')),
              ElevatedButton(
                  onPressed: _listRecoverable, child: const Text('3. Jobs recuperáveis')),
              ElevatedButton(
                  onPressed: () => setState(() => _log = ''), child: const Text('limpar')),
            ]),
            const Divider(),
            Expanded(
              child: SingleChildScrollView(
                child: Text(_log, style: const TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
