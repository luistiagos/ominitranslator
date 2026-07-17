import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dubbing_engine/dubbing_engine.dart';
import 'package:path/path.dart' as p;
import '../platform/android_storage.dart';
import '../platform/media_processing_service.dart';
import '../state/app_state.dart';
import 'progress_screen.dart';
import 'models_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _videoPath;

  /// URI content:// + nome de exibição escolhidos por SAF (D3.4/D-4) — o
  /// Android usa isto no lugar de [_videoPath], nunca os dois ao mesmo
  /// tempo. Ver [_hasVideoSelected].
  String? _androidVideoUri;
  String? _androidVideoName;

  String? _outputPath;
  final _youtubeController = TextEditingController();
  final _speakerCountController = TextEditingController();
  Lang _sourceLang = Lang.en;
  Lang _targetLang = Lang.pt;
  Preset _preset = Preset.best;
  bool _keepOriginalTrack = true;
  bool _generateSrt = true;

  static const _cookieBrowsers = {
    '': 'Nenhum',
    'chrome': 'Chrome',
    'edge': 'Edge',
    'firefox': 'Firefox',
    'brave': 'Brave',
    'opera': 'Opera',
    'vivaldi': 'Vivaldi',
  };

  @override
  void dispose() {
    _youtubeController.dispose();
    _speakerCountController.dispose();
    super.dispose();
  }

  /// Espaço livre por diretório, medido fora do `build()`.
  ///
  /// Antes a UI chamava `freeBytesForPath` (FFI síncrono) direto no `build()`,
  /// a cada frame. No Android o `StatFs` vem por MethodChannel e é assíncrono,
  /// então isso é impossível — e mesmo no Windows era I/O de disco no caminho
  /// de renderização. Agora o valor é medido sob demanda e cacheado; um path
  /// ainda não medido simplesmente não mostra o rodapé de espaço.
  final Map<String, int?> _freeBytes = {};
  final Set<String> _probing = {};

  int? _freeBytesFor(AppState state, String? dirPath) {
    if (dirPath == null) return null;
    if (_freeBytes.containsKey(dirPath)) return _freeBytes[dirPath];
    if (_probing.add(dirPath)) {
      // Fora do build: medir e só então reconstruir.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final bytes = await state.diskSpace.freeBytes(dirPath);
        if (!mounted) return;
        setState(() => _freeBytes[dirPath] = bytes);
      });
    }
    return null;
  }

  /// Descarta as medições: o usuário mudou de diretório ou liberou espaço.
  void _invalidateFreeBytes() {
    _freeBytes.clear();
    _probing.clear();
  }

  /// Número de falantes informado pelo usuário (1–20), ou null para
  /// detecção automática.
  int? _speakerCount() {
    final parsed = int.tryParse(_speakerCountController.text.trim());
    if (parsed == null || parsed < 1 || parsed > 20) return null;
    return parsed;
  }

  /// true se há um vídeo local escolhido — pelo SAF no Android
  /// ([_androidVideoUri]) ou pelo `file_picker` no desktop ([_videoPath]).
  /// Nunca os dois setados ao mesmo tempo (as duas plataformas usam rotas
  /// de import mutuamente exclusivas).
  bool get _hasVideoSelected =>
      Platform.isAndroid ? _androidVideoUri != null : _videoPath != null;

  Future<void> _pickVideo() async {
    if (Platform.isAndroid) {
      // §15.1/AT-5: SAF, não `file_picker` — uma `content://` URI do
      // `file_picker` nem sempre é um path local de verdade (scoped
      // storage); o fluxo já existente de `android_storage.dart` copia
      // explicitamente pro workDir do job antes de rodar (D-4).
      final picked = await pickImportDocument();
      if (picked != null) {
        setState(() {
          _androidVideoUri = picked.uri;
          _androidVideoName = picked.displayName;
        });
      }
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp4', 'mkv', 'mov', 'webm'],
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _videoPath = result.files.single.path;
        _youtubeController.clear();
      });
    }
  }

  static List<Lang> get _sourceLangOptions =>
      Lang.values.toList()..sort((a, b) => a.label.compareTo(b.label));

  static List<Lang> get _targetLangOptions => _sourceLangOptions
      .where((l) => l.isDubTarget)
      .toList();

  List<String> _requiredModelIds(AppState state) {
    final catalog = state.modelManager.catalog;
    return [
      catalog.asrModelIds[_preset]!,
      catalog.defaultVoiceIds[_targetLang]!,
      // Plataforma sem separação (Android M1) não exige o modelo.
      if (catalog.separatorModelId != null) catalog.separatorModelId!,
    ];
  }

  bool _canDub(AppState state) {
    if (state.jobRunning) return false;
    if (!_hasVideoSelected && _youtubeController.text.trim().isEmpty) return false;
    if (!canTranslate(_sourceLang, _targetLang)) return false;
    return _requiredModelIds(state)
        .every((id) => state.modelStates[id] == ModelState.ready);
  }

  String? _missingModels(AppState state) {
    final missing = <String>[];
    for (final id in _requiredModelIds(state)) {
      if (state.modelStates[id] != ModelState.ready) {
        missing.add(state.modelStates[id] == ModelState.corrupted ? 'corrompido' : 'ausente');
      }
    }
    if (missing.isEmpty) return null;
    return 'Modelos ${missing.join(', ')}. Acesse Modelos para baixar.';
  }

  /// Voz fixa selecionada, válida para o idioma alvo atual e instalada,
  /// ou null (automática).
  (String, int)? _selectedVoice(AppState state) {
    final id = state.settings.voiceModelId;
    if (id.isEmpty) return null;
    final sid = state.settings.voiceSid;
    final options = pickableVoices[_targetLang] ?? const [];
    final valid = options.any((v) => v.$1 == id && v.$2 == sid) &&
        state.modelStates[id] == ModelState.ready;
    return valid ? (id, sid) : null;
  }

  Widget _buildVoicePicker(AppState state) {
    final options = (pickableVoices[_targetLang] ?? const [])
        .where((v) => state.modelStates[v.$1] == ModelState.ready)
        .toList();
    final selected = _selectedVoice(state);
    final currentKey = selected != null ? '${selected.$1}#${selected.$2}' : '';
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            value: currentKey,
            decoration: const InputDecoration(labelText: 'Voz da dublagem'),
            items: [
              const DropdownMenuItem(
                  value: '', child: Text('Automática (por falante)')),
              for (final v in options)
                DropdownMenuItem(value: '${v.$1}#${v.$2}', child: Text(v.$3)),
            ],
            onChanged: (key) {
              if (key == null || key.isEmpty) {
                state.setVoice('', 0);
              } else {
                final parts = key.split('#');
                state.setVoice(parts[0], int.parse(parts[1]));
              }
            },
          ),
        ),
        if (selected != null)
          TextButton(
            onPressed: () => _playVoiceSample(state),
            child: const Text('Ouvir'),
          ),
      ],
    );
  }

  /// Sintetiza uma frase curta com a voz selecionada (em isolate, para não
  /// travar a UI) e abre o WAV no player padrão do sistema.
  ///
  /// D3.4/D-7: `Process.start('cmd', ...)` é Windows puro (sem `cmd.exe` no
  /// Android) — em vez de adicionar uma dependência de player de áudio só
  /// pra isto (desproporcional ao gate da D3.4), o Android mostra um aviso
  /// direto e nem sintetiza (não há por que gastar CPU/bateria numa amostra
  /// que ninguém vai poder tocar).
  Future<void> _playVoiceSample(AppState state) async {
    if (Platform.isAndroid) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Pré-visualização de voz não disponível nesta plataforma.')),
        );
      }
      return;
    }
    final voice = _selectedVoice(state);
    if (voice == null) return;
    final lang = _targetLang;
    final modelsRoot = state.modelManager.modelsRoot;
    final (modelId, sid) = voice;
    final text = voiceSampleSentence[lang] ?? voiceSampleSentence[Lang.en]!;
    final outPath =
        p.join(Directory.systemTemp.path, 'omnitranslator_voice_sample.wav');
    try {
      await Isolate.run(() {
        const dummyTools = Tools(
          ffmpeg: '',
          ffprobe: '',
          whisperCli: '',
          translateLocally: '',
          sherpaSourceSeparation: '',
        );
        final synth = PiperSynthesizer(lang, ModelManager(modelsRoot, dummyTools),
            voiceOverride: (modelId, sid));
        try {
          final audio = synth.synthesize(text);
          writeWavPcm16(outPath, WavData(audio.samples, audio.sampleRate, 1));
        } finally {
          synth.dispose();
        }
      });
      await Process.start('cmd', ['/c', 'start', '', outPath]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha ao gerar amostra: $e')),
        );
      }
    }
  }

  /// Dica quando os modelos de diarização não estão instalados (multi-vozes
  /// é opcional: sem eles a dublagem funciona com voz única).
  String? _diarizationHint(AppState state) {
    final ready = state.modelStates[diarizationSegmentationModelId] == ModelState.ready &&
        state.modelStates[diarizationEmbeddingModelId] == ModelState.ready;
    if (ready) return null;
    return 'Para vozes diferentes por falante, baixe os modelos de '
        'detecção de falantes na tela Modelos.';
  }

  Future<void> _pickWorkDir(AppState state) async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      _invalidateFreeBytes();
      state.setWorkDirBase(result);
    }
  }

  Future<void> _pickCookiesFile(AppState state) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
    );
    if (result != null && result.files.single.path != null) {
      state.setYtDlpCookiesFile(result.files.single.path!);
    }
  }

  /// Seção opcional para o YouTube bloquear menos ("Sign in to confirm
  /// you're not a bot" / HTTP 429): cookies de uma sessão logada, extraídos
  /// de um navegador ou de um arquivo cookies.txt (mutuamente exclusivos).
  Widget _buildYoutubeCookiesSection(AppState state) {
    final browser = state.settings.ytDlpCookiesFromBrowser;
    final cookiesFile = state.settings.ytDlpCookiesFile;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Cookies do YouTube (opcional — evita bloqueios de "confirme que não é robô")',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            value: _cookieBrowsers.containsKey(browser) ? browser : '',
            decoration: const InputDecoration(labelText: 'Extrair cookies do navegador'),
            items: _cookieBrowsers.entries
                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
            onChanged: (v) => state.setYtDlpCookiesFromBrowser(v ?? ''),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  cookiesFile.isEmpty
                      ? 'Ou use um arquivo cookies.txt exportado do navegador'
                      : cookiesFile,
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () => _pickCookiesFile(state),
                child: const Text('Escolher arquivo'),
              ),
              if (cookiesFile.isNotEmpty)
                TextButton(
                  onPressed: () => state.setYtDlpCookiesFile(''),
                  child: const Text('Limpar'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Onde o vídeo final seria salvo caso o usuário não escolha um destino
  /// explicitamente. Retorna null se ainda não há vídeo/link selecionado.
  String? _computeDefaultOutputPath() {
    final youtubeUrl = _youtubeController.text.trim();
    if (_videoPath == null && youtubeUrl.isEmpty) return null;
    final baseName = _videoPath != null
        ? p.basenameWithoutExtension(File(_videoPath!).path)
        : 'youtube_${DateTime.now().millisecondsSinceEpoch}';
    if (_videoPath != null) {
      return '${p.dirname(_videoPath!)}\\${baseName}_dub_${_targetLang.code}.mp4';
    }
    final userProfile = Platform.environment['USERPROFILE'];
    final downloadsDir = userProfile != null
        ? '$userProfile\\Downloads'
        : Directory.systemTemp.path;
    return '$downloadsDir\\${baseName}_dub_${_targetLang.code}.mp4';
  }

  Future<void> _pickOutputPath() async {
    final defaultPath = _outputPath ?? _computeDefaultOutputPath();
    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Salvar vídeo dublado como',
      fileName: defaultPath != null ? p.basename(defaultPath) : 'video_dub.mp4',
      initialDirectory: defaultPath != null ? p.dirname(defaultPath) : null,
      type: FileType.custom,
      allowedExtensions: ['mp4'],
    );
    if (result != null) {
      setState(() {
        _invalidateFreeBytes();
        _outputPath = result.toLowerCase().endsWith('.mp4') ? result : '$result.mp4';
      });
    }
  }

  Future<void> _startDub(AppState state) async {
    if (Platform.isAndroid) {
      await _startDubAndroid(state);
      return;
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final workDir = '${state.settings.workDirBase}\\$timestamp';
    final youtubeUrl = _youtubeController.text.trim();
    final inputVideo = _videoPath ?? youtubeUrl;
    final actualOutput = _outputPath ?? _computeDefaultOutputPath()!;

    final config = DubbingJobConfig(
      inputVideo: inputVideo,
      sourceLang: _sourceLang,
      targetLang: _targetLang,
      preset: _preset,
      keepOriginalTrack: _keepOriginalTrack,
      generateSrt: _generateSrt,
      workDir: workDir,
      outputPath: actualOutput,
      youtubeUrl: _videoPath == null ? youtubeUrl : null,
      ytDlpCookiesFromBrowser: state.settings.ytDlpCookiesFromBrowser.isEmpty
          ? null
          : state.settings.ytDlpCookiesFromBrowser,
      ytDlpCookiesFile:
          state.settings.ytDlpCookiesFile.isEmpty ? null : state.settings.ytDlpCookiesFile,
      speakerCount: _speakerCount(),
      voiceModelId: _selectedVoice(state)?.$1,
      voiceSid: _selectedVoice(state)?.$2 ?? 0,
    );

    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ProgressScreen()),
    );

    state.startJob(config);
  }

  /// D3.4/D-4: o vídeo escolhido por SAF é uma `content://` URI — o engine
  /// só conhece paths locais (regra #8), então copia pro `workDir` do job
  /// ANTES de montar o `DubbingJobConfig`. `outputPath` mora fora do
  /// `workDir` de propósito (`outputsRootDir()`, ver o comentário do
  /// `pipeline.dart` apagando o `workDir` após um mux bem-sucedido). Navega
  /// pra `ProgressScreen` só DEPOIS da cópia (não antes, como no desktop) —
  /// senão o usuário ficaria olhando pra uma tela de progresso vazia
  /// enquanto a cópia (potencialmente de centenas de MB) ainda roda.
  Future<void> _startDubAndroid(AppState state) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final workDir = p.join(state.settings.workDirBase, timestamp);
    Directory(workDir).createSync(recursive: true);

    final ext = p.extension(_androidVideoName ?? '');
    final destPath = p.join(workDir, 'input${ext.isEmpty ? '.mp4' : ext}');
    try {
      await copyUriToLocalFile(_androidVideoUri!, destPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha ao importar o vídeo: $e')),
        );
      }
      return;
    }

    final outputDir = await outputsRootDir();
    Directory(outputDir).createSync(recursive: true);
    final outputPath =
        p.join(outputDir, '${timestamp}_dub_${_targetLang.code}.mp4');

    final config = DubbingJobConfig(
      inputVideo: destPath,
      sourceLang: _sourceLang,
      targetLang: _targetLang,
      preset: _preset,
      keepOriginalTrack: _keepOriginalTrack,
      generateSrt: _generateSrt,
      workDir: workDir,
      outputPath: outputPath,
      speakerCount: _speakerCount(),
      voiceModelId: _selectedVoice(state)?.$1,
      voiceSid: _selectedVoice(state)?.$2 ?? 0,
    );

    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ProgressScreen()),
    );
    await state.startJob(config, displayName: _androidVideoName);
  }

  Widget _buildWorkDirTile(AppState state) {
    final dir = state.settings.workDirBase;
    final freeBytes = _freeBytesFor(state, dir);
    final freeMb = freeBytes != null ? (freeBytes / (1024 * 1024)).round() : null;
    final low = freeBytes != null && freeBytes < minFreeDiskBytes;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.folder),
      title: Text('Diretório de trabalho: $dir'),
      subtitle: freeMb != null
          ? Text(
              '$freeMb MB livres em ${p.rootPrefix(dir)}',
              style: TextStyle(color: low ? Colors.red : null),
            )
          : null,
      // D3.4/D-8: `FilePicker.getDirectoryPath()` devolve uma tree URI
      // `content://` no Android, incompatível com todo uso de path cru rio
      // abaixo (FFmpeg, tar, `File` I/O) — o diretório de trabalho no
      // Android é interno ao app (`workRootDir()`), não escolhível pelo
      // usuário.
      trailing: Platform.isAndroid
          ? null
          : TextButton(
              onPressed: () => _pickWorkDir(state),
              child: const Text('Alterar'),
            ),
    );
  }

  String? _lowDiskSpaceWarning(AppState state) {
    final freeBytes = _freeBytesFor(state, state.settings.workDirBase);
    if (freeBytes == null || freeBytes >= minFreeDiskBytes) return null;
    final freeMb = (freeBytes / (1024 * 1024)).round();
    return 'Espaço em disco insuficiente em ${p.rootPrefix(state.settings.workDirBase)} '
        '(apenas $freeMb MB livres). Escolha outro diretório de trabalho acima.';
  }

  Widget _buildOutputTile(AppState state) {
    final path = _outputPath ?? _computeDefaultOutputPath();
    if (path == null) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.save),
        title: Text('Escolha um vídeo ou link para definir onde salvar'),
      );
    }
    final freeBytes = _freeBytesFor(state, p.dirname(path));
    final freeMb = freeBytes != null ? (freeBytes / (1024 * 1024)).round() : null;
    final low = freeBytes != null && freeBytes < minFreeDiskBytes;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.save),
      title: Text('Salvar em: $path'),
      subtitle: freeMb != null
          ? Text(
              '$freeMb MB livres em ${p.rootPrefix(path)}',
              style: TextStyle(color: low ? Colors.red : null),
            )
          : null,
      trailing: TextButton(
        onPressed: _pickOutputPath,
        child: const Text('Alterar'),
      ),
    );
  }

  String? _lowOutputDiskSpaceWarning(AppState state) {
    final path = _outputPath ?? _computeDefaultOutputPath();
    if (path == null) return null;
    final freeBytes = _freeBytesFor(state, p.dirname(path));
    if (freeBytes == null || freeBytes >= minFreeDiskBytes) return null;
    final freeMb = (freeBytes / (1024 * 1024)).round();
    return 'Espaço em disco insuficiente em ${p.rootPrefix(path)} '
        '(apenas $freeMb MB livres). Escolha outro destino de saída acima.';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Scaffold(
      appBar: AppBar(title: const Text('OmniTranslator')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton.icon(
              onPressed: _pickVideo,
              icon: const Icon(Icons.video_file),
              label: Text(_hasVideoSelected
                  ? (Platform.isAndroid
                      ? _androidVideoName!
                      : _videoPath!.split('\\').last)
                  : 'Escolher vídeo'),
            ),
            if (_hasVideoSelected && !Platform.isAndroid)
              Text(_videoPath!, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            // D3.4/D-8: link do YouTube não existe no Android — o M1 usa
            // `createDownloader: null` (`android_runtime.dart`), e
            // `pipeline.dart` recusa `youtubeUrl` não-nulo explicitamente
            // (`PipelineException` no `prepare`). Deixar o campo visível só
            // levaria o usuário a preencher algo que falha na hora de
            // dublar.
            if (!Platform.isAndroid) ...[
              TextField(
                controller: _youtubeController,
                decoration: const InputDecoration(
                  labelText: 'Ou cole um link do YouTube',
                  hintText: 'https://youtube.com/watch?v=...',
                  prefixIcon: Icon(Icons.link),
                ),
                onChanged: (v) {
                  if (v.isNotEmpty && _videoPath != null) {
                    setState(() => _videoPath = null);
                  } else {
                    setState(() {});
                  }
                },
              ),
              if (_youtubeController.text.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Usando link do YouTube',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 12)),
                ),
                _buildYoutubeCookiesSection(state),
              ],
            ],
            const SizedBox(height: 16),
            DropdownButtonFormField<Lang>(
              value: _sourceLang,
              decoration: const InputDecoration(labelText: 'Idioma do vídeo'),
              items: _sourceLangOptions.map((l) => DropdownMenuItem(
                value: l,
                child: Text(l.label),
              )).toList(),
              onChanged: (v) => setState(() => _sourceLang = v!),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<Lang>(
              value: _targetLang,
              decoration: const InputDecoration(labelText: 'Dublar para'),
              items: _targetLangOptions.map((l) => DropdownMenuItem(
                value: l,
                child: Text(l.label),
              )).toList(),
              onChanged: (v) => setState(() => _targetLang = v!),
            ),
            const SizedBox(height: 8),
            _buildVoicePicker(state),
            const SizedBox(height: 8),
            TextField(
              controller: _speakerCountController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Nº de pessoas que falam no vídeo (opcional)',
                hintText: 'Deixe vazio para detecção automática',
                prefixIcon: Icon(Icons.people),
              ),
            ),
            const SizedBox(height: 16),
            RadioListTile<Preset>(
              title: const Text('Rápido'),
              value: Preset.fast,
              groupValue: _preset,
              onChanged: (v) => setState(() => _preset = v!),
            ),
            RadioListTile<Preset>(
              title: const Text('Melhor'),
              value: Preset.best,
              groupValue: _preset,
              onChanged: (v) => setState(() => _preset = v!),
            ),
            CheckboxListTile(
              title: const Text('Manter áudio original como segunda faixa'),
              value: _keepOriginalTrack,
              onChanged: (v) => setState(() => _keepOriginalTrack = v!),
            ),
            CheckboxListTile(
              title: const Text('Gerar legendas SRT'),
              value: _generateSrt,
              onChanged: (v) => setState(() => _generateSrt = v!),
            ),
            const SizedBox(height: 8),
            _buildWorkDirTile(state),
            // D3.4/D-8: no Android o destino final não é escolhido aqui —
            // `outputPath` vai pra uma pasta interna do app
            // (`outputsRootDir()`) e o usuário escolhe onde salvar de
            // verdade DEPOIS que o job termina, via export SAF na tela de
            // progresso (D-5). Mostrar esta ficha antes disso só exibiria
            // "Escolha um vídeo..." pra sempre (`_computeDefaultOutputPath`
            // é Windows puro e nunca resolve no Android).
            if (!Platform.isAndroid) _buildOutputTile(state),
            const SizedBox(height: 16),
            if (_missingModels(state) case final warning?)
              Text(warning, style: const TextStyle(color: Colors.orange)),
            // D3.4/D-8: no M1 Android `createDiarizer` é sempre nulo
            // (`android_runtime.dart`) — baixar os modelos de detecção de
            // falantes nunca habilitaria multi-voz lá, então a dica (que
            // sugere exatamente isso) seria enganosa.
            if (!Platform.isAndroid)
              if (_diarizationHint(state) case final hint?)
                Text(hint, style: Theme.of(context).textTheme.bodySmall),
            if (_lowDiskSpaceWarning(state) case final warning?)
              Text(warning, style: const TextStyle(color: Colors.red)),
            if (_lowOutputDiskSpaceWarning(state) case final warning?)
              Text(warning, style: const TextStyle(color: Colors.red)),
            ElevatedButton(
              onPressed: _canDub(state) &&
                      _lowDiskSpaceWarning(state) == null &&
                      _lowOutputDiskSpaceWarning(state) == null
                  ? () => _startDub(state)
                  : null,
              child: const Text('Dublar'),
            ),
            TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ModelsScreen()),
              ),
              child: const Text('Modelos'),
            ),
          ],
        ),
      ),
    );
  }
}
