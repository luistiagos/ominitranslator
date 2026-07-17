import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:dubbing_engine/dubbing_engine.dart';
import 'src/state/app_state.dart';
import 'src/state/settings.dart';
import 'src/screens/home_screen.dart';
import 'src/platform/android_storage.dart';
import 'src/platform/media_processing_service.dart';
// Mantém `serviceMain` (o entrypoint headless do MediaProcessingService,
// D3.3) alcançável a partir da entry library — sem este import o AOT/
// tree-shaking remove o símbolo mesmo com @pragma('vm:entry-point'), e
// `executeDartEntrypoint(..., "serviceMain")` falha em runtime com
// "entrypoint not found". Não chama nada daqui.
// ignore: unused_import
import 'src/service_entrypoint.dart' show serviceMain;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // D3.4: o Android nunca tem Tools.locate() (procura .exe do Windows) nem
  // as env vars abaixo — settings/modelos vêm de path_provider, e AppState
  // já sabe rodar o job via MediaProcessingService em vez do isolate local.
  if (Platform.isAndroid) {
    await _mainAndroid();
    return;
  }

  final Tools tools;
  try {
    tools = Tools.locate();
  } on StateError catch (e) {
    runApp(StartupErrorApp(message: e.message));
    return;
  }

  final appData = Platform.environment['APPDATA'] ??
      (Platform.environment['USERPROFILE'] != null
          ? '${Platform.environment['USERPROFILE']}\\AppData\\Roaming'
          : null);
  if (appData == null) {
    runApp(const StartupErrorApp(
        message: 'Variáveis de ambiente APPDATA/USERPROFILE não definidas — '
            'não foi possível determinar onde guardar os modelos.'));
    return;
  }
  final modelsRoot = '$appData\\omnitranslator\\models';
  final modelManager = ModelManager(modelsRoot, tools);
  final appState = AppState(tools, modelManager);

  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const OmniTranslatorApp(),
    ),
  );
}

/// `Tools.locate()` procura `.exe` do Windows — nunca chamar no Android. O
/// `ModelManager`/`AppState` exigem um `Tools` não-nulo só por assinatura
/// compartilhada com o desktop; nenhum campo é lido no Android (mesmo padrão
/// já usado em `service_entrypoint.dart`/`tool/android/smoke/smoke_main.dart`).
const _dummyTools = Tools(
  ffmpeg: '',
  ffprobe: '',
  whisperCli: '',
  translateLocally: '',
  sherpaSourceSeparation: '',
);

Future<void> _mainAndroid() async {
  // Resolvido ANTES do runApp: nenhuma tela chega a observar um `settings`
  // ainda não carregado (D3.4/D-6).
  final settings = await AppSettings.loadAndroid();
  final modelsRoot = p.join(await appRootDir(), 'models');
  final modelManager =
      ModelManager(modelsRoot, _dummyTools, catalog: ModelCatalog.android());
  final appState = AppState(
    _dummyTools,
    modelManager,
    diskSpace: createAndroidDiskSpaceProbe(),
    initialSettings: settings,
  );

  runApp(
    ChangeNotifierProvider.value(
      value: appState,
      child: const OmniTranslatorApp(),
    ),
  );
}

/// Tela mostrada quando o app não consegue nem inicializar (ex.: ferramentas
/// externas ausentes), para não fechar silenciosamente sem janela.
class StartupErrorApp extends StatelessWidget {
  final String message;
  const StartupErrorApp({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OmniTranslator',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('OmniTranslator — erro ao iniciar')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text(message),
              const SizedBox(height: 16),
              const Text('Corrija o problema e abra o aplicativo novamente.'),
            ],
          ),
        ),
      ),
    );
  }
}

class OmniTranslatorApp extends StatelessWidget {
  const OmniTranslatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OmniTranslator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
