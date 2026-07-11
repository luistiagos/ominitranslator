import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/retry.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';

enum ModelState { missing, downloading, ready, corrupted }

/// Repete um download com resume ([attempt], tipicamente
/// `_downloadWithResume`) até [maxAttempts] vezes se ele lançar uma exceção
/// (erro de rede, HTTP intermitente etc.), aguardando [retryDelay] entre
/// tentativas. Cada nova tentativa reaproveita o arquivo parcial já
/// baixado (resume), então repetir é barato.
Stream<double> downloadWithRetry(
  Stream<double> Function() attempt, {
  int maxAttempts = defaultMaxAttempts,
  Duration Function(int attempt) retryDelay = defaultRetryDelay,
}) async* {
  for (int i = 1; i <= maxAttempts; i++) {
    try {
      // await for (e não yield*): erros do stream delegado por yield* vão
      // direto ao listener sem passar pelo catch desta função.
      await for (final progress in attempt()) {
        yield progress;
      }
      return;
    } catch (_) {
      if (i == maxAttempts) rethrow;
      await Future.delayed(retryDelay(i));
    }
  }
}

/// Identificador do modelo do translateLocally para o par [from]→[to].
String translationModelId(Lang from, Lang to) {
  if ((from == Lang.en && to == Lang.es) || (from == Lang.es && to == Lang.en)) {
    return '${from.name}-${to.name}-tiny';
  }
  return '${from.name}-${to.name}-base';
}

class ModelEntry {
  final String id;
  final String kind;
  final String url;
  final int sizeMb;
  final List<String> expects;
  final String displayName;

  /// SHA-256 esperado do primeiro arquivo em [expects]. Quando presente,
  /// o download é validado contra ele; null desativa a verificação.
  final String? sha256;
  const ModelEntry({
    required this.id,
    required this.kind,
    required this.url,
    required this.sizeMb,
    required this.expects,
    required this.displayName,
    this.sha256,
  });
}

class ModelManager {
  final String modelsRoot;
  final Tools tools;

  ModelManager(this.modelsRoot, this.tools);

  static List<ModelEntry> get manifest => [
    ModelEntry(
      id: 'whisper-small-q5_1',
      kind: 'file',
      url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin',
      sizeMb: 190,
      expects: ['ggml-small-q5_1.bin'],
      displayName: 'Reconhecimento de fala — Melhor',
    ),
    ModelEntry(
      id: 'whisper-base-q5_1',
      kind: 'file',
      url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin',
      sizeMb: 60,
      expects: ['ggml-base-q5_1.bin'],
      displayName: 'Reconhecimento de fala — Rápido',
    ),
    ModelEntry(
      id: 'spleeter-2stems-fp16',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/source-separation-models/sherpa-onnx-spleeter-2stems-fp16.tar.bz2',
      sizeMb: 40,
      expects: ['vocals.fp16.onnx', 'accompaniment.fp16.onnx'],
      displayName: 'Separação de voz e música',
    ),
    ModelEntry(
      id: 'piper-pt-br',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-faber-medium.tar.bz2',
      sizeMb: 65,
      expects: ['pt_BR-faber-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz — Português (BR)',
    ),
    ModelEntry(
      id: 'piper-es',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_ES-sharvard-medium.tar.bz2',
      sizeMb: 65,
      expects: ['es_ES-sharvard-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz — Espanhol',
    ),
    ModelEntry(
      id: 'piper-en',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium.tar.bz2',
      sizeMb: 65,
      expects: ['en_US-lessac-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz — Inglês',
    ),
    ModelEntry(
      id: 'piper-pt-br-edresson',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-edresson-low.tar.bz2',
      sizeMb: 64,
      expects: ['pt_BR-edresson-low.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Português (BR)',
    ),
    ModelEntry(
      id: 'piper-en-libritts',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-libritts_r-medium.tar.bz2',
      sizeMb: 79,
      expects: ['en_US-libritts_r-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Vozes extras — Inglês (multi)',
    ),
    ModelEntry(
      id: 'piper-es-davefx',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_ES-davefx-medium.tar.bz2',
      sizeMb: 65,
      expects: ['es_ES-davefx-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Espanhol',
    ),
    ModelEntry(
      id: 'piper-pt-br-dii',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-dii-high.tar.bz2',
      sizeMb: 64,
      expects: ['pt_BR-dii-high.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz feminina — Português (BR)',
    ),
    ModelEntry(
      id: 'piper-en-hfc-female',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-hfc_female-medium.tar.bz2',
      sizeMb: 64,
      expects: ['en_US-hfc_female-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz feminina — Inglês',
    ),
    ModelEntry(
      id: 'piper-en-hfc-male',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-hfc_male-medium.tar.bz2',
      sizeMb: 64,
      expects: ['en_US-hfc_male-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz masculina — Inglês',
    ),
    ModelEntry(
      id: 'piper-pt-br-cadu',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-cadu-medium.tar.bz2',
      sizeMb: 64,
      expects: ['pt_BR-cadu-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Cadu (masculina) — Português (BR)',
    ),
    ModelEntry(
      id: 'piper-pt-br-jeff',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-jeff-medium.tar.bz2',
      sizeMb: 64,
      expects: ['pt_BR-jeff-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Jeff (masculina) — Português (BR)',
    ),
    ModelEntry(
      id: 'piper-pt-br-miro',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-miro-high.tar.bz2',
      sizeMb: 64,
      expects: ['pt_BR-miro-high.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Miro — Português (BR)',
    ),
    ModelEntry(
      id: 'piper-es-daniela',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_AR-daniela-high.tar.bz2',
      sizeMb: 110,
      expects: ['es_AR-daniela-high.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Daniela (feminina) — Espanhol (AR)',
    ),
    ModelEntry(
      id: 'piper-es-claude',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_MX-claude-high.tar.bz2',
      sizeMb: 64,
      expects: ['es_MX-claude-high.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Claude — Espanhol (MX)',
    ),
    ModelEntry(
      id: 'piper-es-ald',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_MX-ald-medium.tar.bz2',
      sizeMb: 64,
      expects: ['es_MX-ald-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Ald — Espanhol (MX)',
    ),
    ModelEntry(
      id: 'piper-en-amy',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-amy-medium.tar.bz2',
      sizeMb: 64,
      expects: ['en_US-amy-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Amy (feminina) — Inglês',
    ),
    ModelEntry(
      id: 'piper-en-ryan',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-ryan-medium.tar.bz2',
      sizeMb: 64,
      expects: ['en_US-ryan-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Ryan (masculina) — Inglês',
    ),
    ModelEntry(
      id: 'piper-en-kristin',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-kristin-medium.tar.bz2',
      sizeMb: 64,
      expects: ['en_US-kristin-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Kristin (feminina) — Inglês',
    ),
    ModelEntry(
      id: 'piper-en-joe',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-joe-medium.tar.bz2',
      sizeMb: 64,
      expects: ['en_US-joe-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Joe (masculina) — Inglês',
    ),
    ModelEntry(
      id: 'gender-tagging',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/audio-tagging-models/sherpa-onnx-ced-tiny-audio-tagging-2024-04-19.tar.bz2',
      sizeMb: 27,
      expects: ['model.int8.onnx', 'class_labels_indices.csv'],
      displayName: 'Detecção de sexo/idade por voz',
    ),
    ModelEntry(
      id: 'diarization-segmentation',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
      sizeMb: 7,
      expects: ['model.onnx'],
      displayName: 'Detecção de falantes — segmentação',
    ),
    ModelEntry(
      id: 'diarization-embedding',
      kind: 'file',
      // O tag "speaker-recongition-models" tem esse typo no repositório real.
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx',
      sizeMb: 39,
      expects: ['nemo_en_titanet_small.onnx'],
      displayName: 'Detecção de falantes — vozes',
    ),
  ];

  String pathOf(String id, [String? file]) {
    final base = p.join(modelsRoot, id);
    if (file != null) return p.join(base, file);
    return base;
  }

  ModelState stateOf(String id) {
    final entry = manifest.firstWhere((e) => e.id == id);
    final base = pathOf(id);
    if (!Directory(base).existsSync()) return ModelState.missing;
    bool complete = true;
    for (final expected in entry.expects) {
      final f = p.join(base, expected);
      if (!File(f).existsSync() && !Directory(f).existsSync()) {
        complete = false;
        break;
      }
    }
    if (!complete) {
      // Um .part indica download interrompido (retomável), não corrupção.
      final hasPart = Directory(base)
          .listSync()
          .whereType<File>()
          .any((f) => f.path.endsWith('.part'));
      return hasPart ? ModelState.downloading : ModelState.corrupted;
    }
    final shaFile = p.join(base, '.sha256');
    if (!File(shaFile).existsSync()) return ModelState.corrupted;
    return ModelState.ready;
  }

  /// [maxAttempts]/[retryDelay] controlam o retry automático do download
  /// HTTP (erros de rede, HTTP intermitente) — cada nova tentativa retoma
  /// de onde o arquivo parcial parou, então é barato repetir.
  Stream<double> download(
    String id, {
    int maxAttempts = defaultMaxAttempts,
    Duration Function(int attempt) retryDelay = defaultRetryDelay,
  }) async* {
    final entry = manifest.firstWhere((e) => e.id == id);
    final destDir = pathOf(id);
    Directory(destDir).createSync(recursive: true);

    if (entry.kind == 'file') {
      final destFile = p.join(destDir, entry.expects.first);
      final partFile = '$destFile.part';
      yield* downloadWithRetry(() => _downloadWithResume(entry.url, partFile),
          maxAttempts: maxAttempts, retryDelay: retryDelay);
      File(partFile).renameSync(destFile);
      await _verifyAndWriteSha256(entry, destDir, destFile);
    } else if (entry.kind == 'tarbz2') {
      final archiveFile = p.join(destDir, 'model.tar.bz2');
      final partFile = '$archiveFile.part';
      yield* downloadWithRetry(() => _downloadWithResume(entry.url, partFile),
          maxAttempts: maxAttempts, retryDelay: retryDelay);
      File(partFile).renameSync(archiveFile);
      // Extrai num subdiretório do próprio destino: mesmo volume (rename
      // não cruza volumes) e sem colisão com sobras de outros modelos.
      final extractDir = p.join(destDir, '.extract');
      if (Directory(extractDir).existsSync()) {
        Directory(extractDir).deleteSync(recursive: true);
      }
      Directory(extractDir).createSync();
      try {
        final result = await runTool('tar', [
          '-xjf', archiveFile,
          '-C', extractDir,
        ], timeout: toolTimeout);
        if (result.exitCode != 0) {
          throw StateError('Extraction failed for $id: ${result.stderrTail}');
        }
        _moveContentsUp(extractDir, destDir);
        await _verifyAndWriteSha256(entry, destDir, p.join(destDir, entry.expects.first));
      } on ProcessException {
        throw StateError(
            'Não foi possível executar "tar" para extrair o modelo $id. '
            'O tar.exe vem com o Windows 10+; verifique se está no PATH.');
      } finally {
        if (Directory(extractDir).existsSync()) {
          Directory(extractDir).deleteSync(recursive: true);
        }
      }
      File(archiveFile).deleteSync();
    }
    yield 1.0;
  }

  Future<void> _verifyAndWriteSha256(ModelEntry entry, String destDir, String file) async {
    // Isolate próprio: hashear um arquivo de ~200 MB é pesado demais para
    // rodar no isolate da UI.
    final hash = await Isolate.run(() {
      final bytes = File(file).readAsBytesSync();
      return sha256.convert(bytes).toString();
    });
    if (entry.sha256 != null && hash != entry.sha256) {
      File(file).deleteSync();
      throw StateError(
          'Modelo ${entry.id} baixado com hash inesperado ($hash). '
          'O download pode estar corrompido; tente novamente.');
    }
    File(p.join(destDir, '.sha256')).writeAsStringSync(hash);
  }

  /// Baixa [url] para [partFile], retomando de onde parou se o arquivo já
  /// existe. Emite o progresso (0..1) quando o tamanho total é conhecido.
  Stream<double> _downloadWithResume(String url, String partFile) async* {
    int startByte = 0;
    if (File(partFile).existsSync()) {
      startByte = File(partFile).lengthSync();
    }
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      if (startByte > 0) {
        request.headers['Range'] = 'bytes=$startByte-';
      }
      final response = await client.send(request);
      var mode = FileMode.append;
      if (startByte > 0 && response.statusCode == 200) {
        // Servidor não suporta Range: recomeça do zero em vez de appendar.
        startByte = 0;
        mode = FileMode.write;
      } else if (startByte > 0 && response.statusCode == 416) {
        // Range além do fim: o .part pode estar completo ou corrompido;
        // apaga e recomeça para garantir consistência.
        File(partFile).deleteSync();
        yield* _downloadWithResume(url, partFile);
        return;
      } else if (response.statusCode != 200 && response.statusCode != 206) {
        throw StateError('Download falhou com HTTP ${response.statusCode} para $url');
      }
      final contentLength = response.contentLength;
      final total = contentLength != null ? contentLength + startByte : null;
      final sink = File(partFile).openWrite(mode: mode);
      try {
        int received = startByte;
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total != null && total > 0) {
            yield (received / total).clamp(0.0, 1.0);
          }
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }
  }

  void _moveContentsUp(String srcDir, String destDir) {
    final entries = Directory(srcDir).listSync();
    if (entries.length == 1 && entries.first is Directory) {
      final subDir = entries.first as Directory;
      for (final entry in subDir.listSync()) {
        final dest = p.join(destDir, p.basename(entry.path));
        if (entry is File) {
          File(entry.path).renameSync(dest);
        } else if (entry is Directory) {
          Directory(entry.path).renameSync(dest);
        }
      }
    } else {
      for (final entry in entries) {
        final dest = p.join(destDir, p.basename(entry.path));
        if (entry is File) {
          File(entry.path).renameSync(dest);
        } else if (entry is Directory) {
          Directory(entry.path).renameSync(dest);
        }
      }
    }
  }

  Future<void> delete(String id) async {
    final dir = Directory(pathOf(id));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  Future<void> ensureTranslationModels(Lang from, Lang to, CancellationToken token, {RunToolFn? runToolOverride}) async {
    // Rede: o download dos modelos de tradução merece retry.
    final exec = runToolOverride ?? runToolWithRetry;
    final pairs = <(Lang, Lang)>{};
    if (from == Lang.pt && to == Lang.es) {
      pairs.add((from, Lang.en));
      pairs.add((Lang.en, to));
    } else if (from == Lang.es && to == Lang.pt) {
      pairs.add((from, Lang.en));
      pairs.add((Lang.en, to));
    } else {
      pairs.add((from, to));
    }
    for (final pair in pairs) {
      final id = translationModelId(pair.$1, pair.$2);
      final r = await exec(tools.translateLocally, ['-d', id],
          token: token, timeout: toolTimeout);
      if (r.exitCode != 0) {
        throw PipelineException(PipelineStage.translate,
            'Falha ao baixar o modelo de tradução $id (código ${r.exitCode}). '
            'Verifique a conexão com a internet.');
      }
    }
  }
}
