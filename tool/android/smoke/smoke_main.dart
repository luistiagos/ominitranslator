// Smoke test on-device dos backends Android escritos na D3.2 (AndroidTranslator
// via slimt FFI, AndroidTranscriber via sherpa Whisper+VAD FFI,
// AndroidSynthesizer via sherpa Piper FFI) + o catalogo real publicado
// (android-models-v1) -- fecha as pendencias de "smoke test funcional"
// registradas em decisoes.md/progresso-android.md desde a D3.1.
//
// COMO RODAR (mesmo padrao da D3.1 -- swap temporario, nunca comitado):
//   1. Rodar tool/android/fetch_native_libs.ps1 (P2 + F2) se ainda nao
//      rodou -- baixa libslimt.so E o AAR do FFmpegKitNext, ambos com
//      SHA-256 verificado.
//   2. Para o botao "Transcrever": o AAR do FFmpegKitNext ja esta
//      declarado em app/android/app/build.gradle.kts (F1-F4, revisao de
//      2026-07-16 -- gap fechado, compilacao confirmada contra o AAR real).
//      Falta so o handler Kotlin temporario (ver smoke_ffmpeg_handler.kt.snippet,
//      que ja documenta a API real testada -- getters explicitos, nao
//      properties). Os botoes 1/2/4 nao dependem do handler.
//   3. cp app/lib/main.dart /tmp/main.dart.backup
//   4. cp tool/android/smoke/smoke_main.dart app/lib/main.dart
//   5. flutter build apk --debug --target-platform android-arm64
//   6. adb install -r ...; abrir o app; apertar os botoes em ordem.
//   7. cp /tmp/main.dart.backup app/lib/main.dart (reverte -- nao comitar o
//      swap) -- e reverter o MainActivity.kt do passo 2, se foi tocado.
import 'dart:io';
import 'package:dubbing_engine/dubbing_engine.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'src/platform/android_ffmpeg.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _SmokeScreen()));
}

class _SmokeScreen extends StatefulWidget {
  const _SmokeScreen();
  @override
  State<_SmokeScreen> createState() => _SmokeScreenState();
}

class _SmokeScreenState extends State<_SmokeScreen> {
  String _log = '';
  ModelManager? _models;

  void _append(String s) => setState(() => _log = '$_log\n$s');

  Future<ModelManager> _modelsOrInit() async {
    if (_models != null) return _models!;
    final dir = await getApplicationSupportDirectory(); // §6.2: onde os modelos vivem de verdade
    // Tools.locate() procura .exe do Windows -- nunca chamar no Android. O
    // ModelManager exige um Tools nao-nulo so por assinatura compartilhada
    // com o desktop (nao ha .exe pra achar aqui); qualquer valor serve.
    _models = ModelManager(dir.path, _dummyTools, catalog: ModelCatalog.android());
    return _models!;
  }

  static final _dummyTools = Tools(
    ffmpeg: '', ffprobe: '', whisperCli: '', translateLocally: '', sherpaSourceSeparation: '',
  );

  static const _catalogIds = [
    'mt-tiny-enpt',
    'whisper-android-tiny',
    'silero-vad',
    'piper-android-pt-br',
    'espeak-ng-data',
  ];

  Future<void> _testCatalogDownload() async {
    final models = await _modelsOrInit();
    for (final id in _catalogIds) {
      final state = models.stateOf(id);
      if (state == ModelState.ready) {
        _append('$id: ja pronto, pulando');
        continue;
      }
      final sw = Stopwatch()..start();
      _append('$id: baixando...');
      try {
        await for (final _ in models.download(id)) {}
        sw.stop();
        _append('$id: OK em ${sw.elapsedMilliseconds}ms (state=${models.stateOf(id)})');
      } catch (e) {
        _append('$id: FALHOU -- $e');
      }
    }
  }

  Future<void> _testTranslator() async {
    final models = await _modelsOrInit();
    final translator = AndroidTranslator(models);
    try {
      // Mesmas 10 primeiras frases da suite versionada do AT-1
      // (docs/spikes-android/at1-suite/en.txt) -- criterios: saida
      // nao-vazia, sem eco degenerado obvio (palavra final repetida 3x+).
      const sentences = [
        'The weather is beautiful today.',
        'I would like a cup of coffee.',
        'The train leaves at seven in the morning.',
        'She bought three books yesterday.',
        'We are going to the beach this weekend.',
      ];
      final sw = Stopwatch()..start();
      final result = await translator.translate(sentences, Lang.en, Lang.pt, CancellationToken());
      sw.stop();
      var okCount = 0;
      for (var i = 0; i < sentences.length; i++) {
        final out = result[i];
        final looksDegenerate = RegExp(r'(\S+)(\s+\1){2,}').hasMatch(out);
        final ok = out.trim().isNotEmpty && !looksDegenerate;
        if (ok) okCount++;
        _append('  en: ${sentences[i]}\n  pt: $out ${ok ? "OK" : "SUSPEITO"}');
      }
      _append('Traducao: $okCount/${sentences.length} OK em ${sw.elapsedMilliseconds}ms');
    } finally {
      translator.dispose();
    }
  }

  Future<void> _testTranscriber() async {
    final models = await _modelsOrInit();
    final extDir = await getExternalStorageDirectory();
    // Fixture 44,1kHz ESTEREO de proposito -- e exatamente o formato que o
    // audio_full.wav real do demux produz (demux.dart:17), e o que o fix do
    // B1 (revisao de 2026-07-16) precisa provar que converte certo antes do
    // VAD/Whisper. Gerar com tool/at2_gen_fixture.dart (16kHz mono) + um
    // passo extra de ffmpeg no desktop:
    //   ffmpeg -i <gerado>.wav -ac 2 -ar 44100 fixture_44k_stereo.wav
    // adb push fixture_44k_stereo.wav <extDir>/smoke_asr_input.wav
    final inputWav = '${extDir!.path}/smoke_asr_input.wav';
    if (!File(inputWav).existsSync()) {
      _append('SKIP transcriber: adb push um WAV 44,1kHz estereo para $inputWav primeiro');
      return;
    }
    final runner = createFFmpegKitNextRunner(); // precisa do handler temporario -- ver cabecalho
    final transcriber = AndroidTranscriber(models, Preset.fast, runner);
    final sw = Stopwatch()..start();
    try {
      final segments = await transcriber.transcribe(inputWav, Lang.en, CancellationToken());
      sw.stop();
      _append('Transcricao: ${segments.length} segmentos em ${sw.elapsedMilliseconds}ms');
      for (final s in segments.take(5)) {
        _append('  [${s.start}-${s.end}] ${s.text}');
      }
      // Confirma que a conversao rodou: asr_in.wav deve existir ao lado do
      // input, e nao ser identico em tamanho ao original (taxa mudou).
      final converted = File('${extDir.path}/asr_in.wav');
      _append('asr_in.wav gerado: ${converted.existsSync()}'
          '${converted.existsSync() ? " (${converted.lengthSync()} bytes)" : ""}');
    } catch (e) {
      _append('Transcricao FALHOU -- $e');
    }
  }

  Future<void> _testSynthesizer() async {
    final models = await _modelsOrInit();
    final synthesizer = AndroidSynthesizer(Lang.pt, models);
    try {
      final sw = Stopwatch()..start();
      final audio = synthesizer.synthesize('Isto é um teste de síntese de voz no Android.');
      sw.stop();
      final extDir = await getExternalStorageDirectory();
      final outPath = '${extDir!.path}/smoke_tts_output.wav';
      // Piper (VITS) so sintetiza mono.
      writeWavPcm16(outPath, WavData(audio.samples, audio.sampleRate, 1));
      final durationSec = audio.samples.length / audio.sampleRate;
      _append('Sintese: ${audio.samples.length} samples @ ${audio.sampleRate}Hz '
          '(${durationSec.toStringAsFixed(2)}s) em ${sw.elapsedMilliseconds}ms -> $outPath');
      _append('adb pull $outPath pra conferir no desktop');
    } finally {
      synthesizer.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Smoke test D3.2 (temporario)')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              ElevatedButton(onPressed: _testCatalogDownload, child: const Text('1. Catalogo')),
              ElevatedButton(onPressed: _testTranslator, child: const Text('2. Traduzir')),
              ElevatedButton(onPressed: _testTranscriber, child: const Text('3. Transcrever')),
              ElevatedButton(onPressed: _testSynthesizer, child: const Text('4. Sintetizar')),
              ElevatedButton(onPressed: () => setState(() => _log = ''), child: const Text('limpar')),
            ]),
            const Divider(),
            Expanded(child: SingleChildScrollView(child: Text(_log, style: const TextStyle(fontSize: 12)))),
          ],
        ),
      ),
    );
  }
}
