// Espelha os assets do ModelCatalog.android() como .tar.gz num diretório
// local, pronto pra virar os assets de uma GitHub Release do próprio
// repositório (§6.1.1 da spec: "todo asset do catálogo Android é espelhado
// como .tar.gz num GitHub Release do próprio repositório, com SHA-256
// fixado" — o Android não tem `tar`, e o BZip2Decoder Dart-puro do
// package:archive é lento demais no device; por isso .tar.gz em vez do
// .tar.bz2 upstream, e por isso o espelho em vez de apontar direto pro
// k2-fsa/sherpa-onnx).
//
// Usa o `tar` do sistema (Windows 10+/Linux) pra extrair o .tar.bz2 upstream
// e recriar como .tar.gz — mais rápido que decodificar bzip2 em Dart puro,
// e esta ferramenta roda uma vez no desktop do desenvolvedor, não no device.
//
// Uso:
//   dart run tool/mirror_models.dart [--out <dir>] [--piper-root <dir>]
//
// [--piper-root]: raiz dos modelos Piper já instalados no desktop (mesmos
// arquivos citados no AT2.md §8 — "os mesmos arquivos já em produção no
// desktop"), default %APPDATA%/omnitranslator/models.
//
// A saída (stdout) inclui os SHA-256 e um bloco `ModelEntry(...)` pronto pra
// colar em `ModelCatalog.android()` depois de revisado e as URLs da Release
// preenchidas — este script não escreve no catálogo sozinho (mesmo padrão
// de `gen_voice_manifest.dart`).
//
// LIMITE CONHECIDO DE REPRODUTIBILIDADE: o script zera o timestamp do
// cabeçalho gzip e normaliza o mtime de cada arquivo antes de empacotar
// (`_zeroGzipTimestamp`/`_normalizeMtime`) — sem isso, hashes mudavam a cada
// execução mesmo com conteúdo-fonte idêntico. Mesmo assim, reruns em
// máquinas/tar diferentes AINDA podem produzir bytes diferentes (o `tar`
// do Windows grava atime/ctime em headers PAX que não são controláveis por
// `File.setLastModifiedSync`, achado desta sessão). Por isso: o hash que vai
// pro catálogo é sempre o hash do arquivo REALMENTE publicado na Release,
// medido no momento do upload — nunca um hash de uma execução anterior.
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

const _whisperTinyUrl =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.tar.bz2';
const _whisperBaseUrl =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-base.tar.bz2';
const _sileroVadUrl =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx';

const _remoteSettingsCdn =
    'https://firefox-settings-attachments.cdn.mozilla.net/main-workspace/translations-models/';

/// Modelos de tradução tiny (Remote Settings do Firefox, MPL-2.0), `location`
/// e tamanho verificados contra o índice ao vivo em 2026-07-15 (AT1.md §4,
/// reconfirmado — os `location` batem exatos com o que o AT-1 já tinha
/// registrado pra en-pt/pt-en). Só `model`+`vocab`: o AT-1 (§6.1) achou que
/// `lex` degenera a saída do slimt — o pacote Android não precisa dele.
class _TranslationModelSpec {
  final String id; // mt-tiny-*
  final String modelLocation;
  final String vocabLocation;
  final String modelFileName;
  final String vocabFileName;
  final String displayName;
  const _TranslationModelSpec({
    required this.id,
    required this.modelLocation,
    required this.vocabLocation,
    required this.modelFileName,
    required this.vocabFileName,
    required this.displayName,
  });
}

const _translationModels = [
  _TranslationModelSpec(
    id: 'mt-tiny-enpt',
    modelLocation: 'b268bf87-94b6-4893-9da1-c4e75284ace7.bin',
    vocabLocation: '745bff57-f929-41d9-8f0f-913513cfd334.spm',
    modelFileName: 'model.enpt.intgemm.alphas.bin',
    vocabFileName: 'vocab.enpt.spm',
    displayName: 'Tradução — Inglês → Português',
  ),
  _TranslationModelSpec(
    id: 'mt-tiny-pten',
    modelLocation: 'dc4327ec-9ebc-4c12-8037-48cd30f3076d.bin',
    vocabLocation: '75fa56af-540e-4a56-8a9f-1317ae7a9c61.spm',
    modelFileName: 'model.pten.intgemm.alphas.bin',
    vocabFileName: 'vocab.pten.spm',
    displayName: 'Tradução — Português → Inglês',
  ),
  _TranslationModelSpec(
    id: 'mt-tiny-enes',
    modelLocation: '50fbae09-5219-4393-ad75-28b23f44a17d.bin',
    vocabLocation: 'e9c774ba-69ff-4951-8783-895aeeb05439.spm',
    modelFileName: 'model.enes.intgemm.alphas.bin',
    vocabFileName: 'vocab.enes.spm',
    displayName: 'Tradução — Inglês → Espanhol',
  ),
  _TranslationModelSpec(
    id: 'mt-tiny-esen',
    modelLocation: '9ee26e91-9b52-44ba-8d30-c0230dd587b2.bin',
    vocabLocation: 'cab5e093-7b55-47ea-a247-9747cc0109e3.spm',
    modelFileName: 'model.esen.intgemm.alphas.bin',
    vocabFileName: 'vocab.esen.spm',
    displayName: 'Tradução — Espanhol → Inglês',
  ),
];

Future<void> main(List<String> args) async {
  final outIdx = args.indexOf('--out');
  final outDir = Directory(outIdx >= 0 && outIdx + 1 < args.length
      ? args[outIdx + 1]
      : p.join(Directory.systemTemp.path, 'omnitranslator-mirror'));
  outDir.createSync(recursive: true);

  final piperRootIdx = args.indexOf('--piper-root');
  final piperRoot = piperRootIdx >= 0 && piperRootIdx + 1 < args.length
      ? args[piperRootIdx + 1]
      : p.join(Platform.environment['APPDATA']!, 'omnitranslator', 'models');

  final workDir = Directory(p.join(outDir.path, '.work'))..createSync(recursive: true);
  final results = <_MirrorResult>[];

  results.add(await _mirrorWhisper(
      tag: 'tiny', url: _whisperTinyUrl, workDir: workDir, outDir: outDir));
  results.add(await _mirrorWhisper(
      tag: 'base', url: _whisperBaseUrl, workDir: workDir, outDir: outDir));
  results.add(await _mirrorRawFile(
      id: 'silero-vad',
      url: _sileroVadUrl,
      destFileName: 'silero_vad.onnx',
      outDir: outDir));
  for (final spec in _translationModels) {
    results.add(await _mirrorTranslationModel(spec: spec, workDir: workDir, outDir: outDir));
  }
  results.add(await _mirrorEspeakNgData(
      piperRoot: piperRoot, workDir: workDir, outDir: outDir));
  for (final (id, dir, lang) in [
    ('piper-android-en', 'piper-en', 'en'),
    ('piper-android-pt-br', 'piper-pt-br', 'pt'),
    ('piper-android-es', 'piper-es', 'es'),
  ]) {
    results.add(await _mirrorPiperVoice(
        id: id,
        sourceDir: p.join(piperRoot, dir),
        lang: lang,
        workDir: workDir,
        outDir: outDir));
  }

  workDir.deleteSync(recursive: true);

  stdout.writeln('\n=== Assets prontos em ${outDir.path} ===');
  for (final r in results) {
    stdout.writeln('${r.fileName}  ${r.sizeBytes} bytes  sha256=${r.sha256}');
  }

  stdout.writeln('\n=== ModelEntry (colar em ModelCatalog.android(), '
      'preencher REPLACE_WITH_RELEASE_URL após publicar a Release) ===\n');
  for (final r in results) {
    stdout.writeln(r.toModelEntrySource());
  }
}

class _MirrorResult {
  final String id;
  final String fileName;
  final int sizeBytes;
  final String sha256;
  final String kind;
  final List<String> expects;
  final String displayName;
  final String? lang;
  final List<String> dependsOn;
  _MirrorResult({
    required this.id,
    required this.fileName,
    required this.sizeBytes,
    required this.sha256,
    required this.kind,
    required this.expects,
    required this.displayName,
    this.lang,
    this.dependsOn = const [],
  });

  String toModelEntrySource() {
    final expectsSrc = expects.map((e) => "'$e'").join(', ');
    final dependsSrc =
        dependsOn.isEmpty ? '' : "\n      dependsOn: [${dependsOn.map((e) => "'$e'").join(', ')}],";
    final langSrc = lang == null ? '' : "\n      lang: Lang.$lang,";
    return '''
    ModelEntry(
      id: '$id',
      kind: '$kind',
      url: 'REPLACE_WITH_RELEASE_URL/$fileName',
      sizeMb: ${(sizeBytes / 1e6).ceil()},
      expects: [$expectsSrc],
      displayName: '$displayName',
      sha256: '$sha256',$langSrc$dependsSrc
    ),''';
  }
}

/// Todo arquivo que vai entrar num `.tar.gz` (baixado ou copiado) precisa de
/// mtime fixo: o `tar` grava o mtime de CADA ENTRADA no próprio arquivo
/// (campo separado do timestamp do cabeçalho gzip que `_zeroGzipTimestamp`
/// já zera) — um download feito "agora" tem mtime "agora", e o mesmo
/// conteúdo produz um `.tar.gz` diferente a cada execução. Achado desta
/// sessão: `mt-tiny-*` (baixados frescos a cada run) continuavam mudando de
/// hash mesmo depois do fix do timestamp do gzip, enquanto whisper/piper
/// (mtime estável — extraídos do mesmo .tar.bz2 ou copiados de arquivos já
/// em disco) já tinham ficado deterministas.
final _fixedMtime = DateTime.utc(2024, 1, 1);

void _normalizeMtime(File f) => f.setLastModifiedSync(_fixedMtime);

Future<void> _downloadTo(String url, File dest) async {
  stdout.writeln('baixando $url ...');
  final req = http.Request('GET', Uri.parse(url));
  final resp = await http.Client().send(req);
  if (resp.statusCode != 200) {
    throw StateError('GET $url -> HTTP ${resp.statusCode}');
  }
  final sink = dest.openWrite();
  await resp.stream.pipe(sink);
  await sink.close();
  _normalizeMtime(dest);
}

Future<ProcessResult> _tar(List<String> args, {String? workingDirectory}) async {
  final r = await Process.run('tar', args, workingDirectory: workingDirectory);
  if (r.exitCode != 0) {
    throw StateError('tar ${args.join(' ')} falhou: ${r.stderr}');
  }
  // -czf grava o timestamp de criação no cabeçalho gzip (bytes 4-7, campo
  // MTIME) — o mesmo conteúdo produz um .tar.gz DIFERENTE (hash diferente) a
  // cada execução, mesmo com os arquivos-fonte idênticos e sem tocar em
  // --mtime do tar (achado desta sessão: silero_vad.onnx, baixado cru sem
  // passar por tar, ficou byte-idêntico entre duas execuções; todo .tar.gz
  // gerado por -czf mudou). Zera o campo pra tornar o build reproduzível —
  // "reproduzível" (§12.1) não vale nada se o hash muda a cada rerun.
  final czfIdx = args.indexOf('-czf');
  if (czfIdx >= 0 && czfIdx + 1 < args.length) {
    _zeroGzipTimestamp(File(args[czfIdx + 1]));
  }
  return r;
}

void _zeroGzipTimestamp(File gzFile) {
  final bytes = gzFile.readAsBytesSync();
  if (bytes.length < 8 || bytes[0] != 0x1f || bytes[1] != 0x8b) {
    throw StateError('${gzFile.path} não parece ser um gzip válido');
  }
  for (var i = 4; i <= 7; i++) {
    bytes[i] = 0;
  }
  gzFile.writeAsBytesSync(bytes);
}

String _sha256Of(File f) => sha256.convert(f.readAsBytesSync()).toString();

Future<_MirrorResult> _mirrorWhisper({
  required String tag, // tiny | base
  required String url,
  required Directory workDir,
  required Directory outDir,
}) async {
  final archive = File(p.join(workDir.path, 'whisper-$tag.tar.bz2'));
  if (!archive.existsSync()) {
    await _downloadTo(url, archive);
  }
  final extractDir = Directory(p.join(workDir.path, 'whisper-$tag-extract'))
    ..createSync(recursive: true);
  await _tar(['-xjf', archive.path, '-C', extractDir.path]);
  final srcDir = Directory(p.join(extractDir.path, 'sherpa-onnx-whisper-$tag'));

  final flatDir = Directory(p.join(workDir.path, 'whisper-$tag-flat'))
    ..createSync(recursive: true);
  final files = [
    '$tag-encoder.int8.onnx',
    '$tag-decoder.int8.onnx',
    '$tag-tokens.txt',
  ];
  for (final f in files) {
    _normalizeMtime(File(p.join(srcDir.path, f)).copySync(p.join(flatDir.path, f)));
  }

  final outFile = File(p.join(outDir.path, 'whisper-android-$tag.tar.gz'));
  await _tar(['-czf', outFile.path, ...files], workingDirectory: flatDir.path);

  return _MirrorResult(
    id: 'whisper-android-$tag',
    fileName: p.basename(outFile.path),
    sizeBytes: outFile.lengthSync(),
    sha256: _sha256Of(outFile),
    kind: 'targz',
    expects: files,
    displayName:
        tag == 'tiny' ? 'Reconhecimento de fala — Rápido' : 'Reconhecimento de fala — Melhor',
  );
}

Future<_MirrorResult> _mirrorRawFile({
  required String id,
  required String url,
  required String destFileName,
  required Directory outDir,
}) async {
  final outFile = File(p.join(outDir.path, destFileName));
  await _downloadTo(url, outFile);
  return _MirrorResult(
    id: id,
    fileName: destFileName,
    sizeBytes: outFile.lengthSync(),
    sha256: _sha256Of(outFile),
    kind: 'file',
    expects: [destFileName],
    displayName: 'Segmentação de fala (VAD)',
  );
}

Future<_MirrorResult> _mirrorTranslationModel({
  required _TranslationModelSpec spec,
  required Directory workDir,
  required Directory outDir,
}) async {
  final flatDir = Directory(p.join(workDir.path, spec.id))..createSync(recursive: true);
  final modelFile = File(p.join(flatDir.path, spec.modelFileName));
  final vocabFile = File(p.join(flatDir.path, spec.vocabFileName));
  await _downloadTo('$_remoteSettingsCdn${spec.modelLocation}', modelFile);
  await _downloadTo('$_remoteSettingsCdn${spec.vocabLocation}', vocabFile);

  final outFile = File(p.join(outDir.path, '${spec.id}.tar.gz'));
  await _tar(['-czf', outFile.path, spec.modelFileName, spec.vocabFileName],
      workingDirectory: flatDir.path);

  return _MirrorResult(
    id: spec.id,
    fileName: p.basename(outFile.path),
    sizeBytes: outFile.lengthSync(),
    sha256: _sha256Of(outFile),
    kind: 'targz',
    expects: [spec.modelFileName, spec.vocabFileName],
    displayName: spec.displayName,
  );
}

/// `espeak-ng-data` é byte-idêntico entre as vozes Piper en/pt/es (confirmado
/// no AT2.md §8 e reverificado nesta sessão, `diff -rq` nas 3 pastas
/// instaladas) — espelhado como pacote único e compartilhado via
/// `ModelEntry.dependsOn`, em vez de triplicado dentro de cada voz.
Future<_MirrorResult> _mirrorEspeakNgData({
  required String piperRoot,
  required Directory workDir,
  required Directory outDir,
}) async {
  final srcDir = Directory(p.join(piperRoot, 'piper-en', 'espeak-ng-data'));
  if (!srcDir.existsSync()) {
    throw StateError('espeak-ng-data não encontrado em ${srcDir.path}');
  }
  // Empacota o CONTEÚDO do diretório (sem o wrapper `espeak-ng-data/`): a
  // extração genérica do ModelManager (`_moveContentsUp`) já achata um único
  // diretório de embrulho — empacotar com o wrapper faz os 355 arquivos
  // caírem soltos no destDir da entrada em vez de dentro de um subdiretório
  // `espeak-ng-data`, quebrando `expects`. Achado ao rodar
  // `ModelManager.download('espeak-ng-data')` de verdade contra a Release.
  final outFile = File(p.join(outDir.path, 'espeak-ng-data.tar.gz'));
  await _tar(['-czf', outFile.path, '-C', srcDir.path, '.']);
  return _MirrorResult(
    id: 'espeak-ng-data',
    fileName: p.basename(outFile.path),
    sizeBytes: outFile.lengthSync(),
    sha256: _sha256Of(outFile),
    kind: 'targz',
    // `en_dict` como marcador de completude — o destDir da própria entrada É
    // o payload (sem subdiretório), então `AndroidSynthesizer` referencia
    // `models.pathOf('espeak-ng-data')` direto como dataDir, ao contrário do
    // desktop (onde `espeak-ng-data` vem embutido dentro do destDir de cada
    // voz).
    expects: ['en_dict'],
    displayName: 'Dados de fonética (compartilhado entre vozes)',
  );
}

Future<_MirrorResult> _mirrorPiperVoice({
  required String id,
  required String sourceDir,
  required String lang,
  required Directory workDir,
  required Directory outDir,
}) async {
  final dir = Directory(sourceDir);
  if (!dir.existsSync()) {
    throw StateError('Voz não encontrada em $sourceDir');
  }
  final onnxFile = dir
      .listSync()
      .whereType<File>()
      .firstWhere((f) => f.path.endsWith('.onnx') && !f.path.endsWith('.onnx.json'));
  final onnxName = p.basename(onnxFile.path);
  final tokensFile = File(p.join(sourceDir, 'tokens.txt'));
  if (!tokensFile.existsSync()) {
    throw StateError('tokens.txt ausente em $sourceDir');
  }

  final flatDir = Directory(p.join(workDir.path, 'piper-$lang-flat'))..createSync(recursive: true);
  _normalizeMtime(onnxFile.copySync(p.join(flatDir.path, onnxName)));
  _normalizeMtime(tokensFile.copySync(p.join(flatDir.path, 'tokens.txt')));

  final outFile = File(p.join(outDir.path, '$id.tar.gz'));
  await _tar(['-czf', outFile.path, onnxName, 'tokens.txt'], workingDirectory: flatDir.path);

  return _MirrorResult(
    id: id,
    fileName: p.basename(outFile.path),
    sizeBytes: outFile.lengthSync(),
    sha256: _sha256Of(outFile),
    kind: 'targz',
    expects: [onnxName, 'tokens.txt'],
    displayName: 'Voz — ${{'en': 'Inglês', 'pt': 'Português (BR)', 'es': 'Espanhol'}[lang]}',
    lang: lang,
    dependsOn: const ['espeak-ng-data'],
  );
}
