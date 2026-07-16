import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:dubbing_engine/dubbing_engine.dart';
import 'src/state/app_state.dart';
import 'src/screens/home_screen.dart';
// Mantém `serviceMain` (o entrypoint headless do MediaProcessingService,
// D3.3) alcançável a partir da entry library — sem este import o AOT/
// tree-shaking remove o símbolo mesmo com @pragma('vm:entry-point'), e
// `executeDartEntrypoint(..., "serviceMain")` falha em runtime com
// "entrypoint not found". Não chama nada daqui; main() continua só desktop.
// ignore: unused_import
import 'src/service_entrypoint.dart' show serviceMain;

void main() {
  WidgetsFlutterBinding.ensureInitialized();

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
