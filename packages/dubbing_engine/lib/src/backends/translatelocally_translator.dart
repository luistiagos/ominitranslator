import 'dart:convert';
import 'dart:io';
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:path/path.dart' as p;

class TranslateLocallyTranslator implements Translator {
  final Tools tools;
  final ModelManager models;
  TranslateLocallyTranslator(this.tools, this.models);

  @override
  Future<List<String>> translate(
      List<String> sentences, Lang from, Lang to, CancellationToken token, {RunToolFn? runToolOverride}) async {
    if (from == to) return sentences;
    // Offline-first: tenta traduzir direto com os modelos já instalados.
    // Só baixa modelos (rede) se a tradução falhar — assim um job com
    // modelos presentes funciona sem internet.
    try {
      return await _translatePair(sentences, from, to, token, runToolOverride: runToolOverride);
    } on PipelineException {
      await models.ensureTranslationModels(from, to, token, runToolOverride: runToolOverride);
      return _translatePair(sentences, from, to, token, runToolOverride: runToolOverride);
    }
  }

  Future<List<String>> _translatePair(
      List<String> sentences, Lang from, Lang to, CancellationToken token, {RunToolFn? runToolOverride}) async {
    final needsPivot = (from == Lang.pt && to == Lang.es) || (from == Lang.es && to == Lang.pt);
    if (needsPivot) {
      final pivot = await _runTranslate(sentences, from, Lang.en, token, runToolOverride: runToolOverride);
      return _runTranslate(pivot, Lang.en, to, token, runToolOverride: runToolOverride);
    }
    return _runTranslate(sentences, from, to, token, runToolOverride: runToolOverride);
  }
  Future<List<String>> _runTranslate(
      List<String> sentences, Lang from, Lang to, CancellationToken token, {RunToolFn? runToolOverride}) async {
    final exec = runToolOverride ?? runTool;
    final dir = Directory.systemTemp.path;
    final srcFile = p.join(dir, 'omnitranslator_mt_src_${from.name}_${to.name}.txt');
    final dstFile = p.join(dir, 'omnitranslator_mt_dst_${from.name}_${to.name}.txt');
    try {
      final srcContent = sentences.map((s) => s.replaceAll(RegExp(r'[\n\r]'), ' ')).join('\n');
      // O translateLocally usa o encoding LOCAL do sistema (cp1252 no
      // Windows) na entrada e na saída — verificado empiricamente: entrada
      // UTF-8 com acentos produz tradução corrompida ("fão", "aão").
      File(srcFile).writeAsBytesSync(systemEncoding.encode(srcContent));
      final result = await exec(tools.translateLocally, [
        '-m', translationModelId(from, to),
        '-i', srcFile,
        '-o', dstFile,
      ], workingDirectory: dir, token: token);
      if (result.exitCode != 0) throw PipelineException(PipelineStage.translate, 'translateLocally falhou com código ${result.exitCode}');
      if (!File(dstFile).existsSync()) throw PipelineException(PipelineStage.translate, 'Arquivo de saída não gerado');
      // Saída: cp1252 no Windows. Tenta UTF-8 estrito primeiro (cobre
      // builds que usem UTF-8 e saídas ASCII puras); bytes inválidos =
      // encoding local. NUNCA usar allowMalformed: os U+FFFD resultantes
      // viravam sílabas faladas pelo TTS no meio de toda palavra acentuada.
      final dstBytes = File(dstFile).readAsBytesSync();
      String content;
      try {
        content = utf8.decode(dstBytes);
      } on FormatException {
        content = systemEncoding.decode(dstBytes);
      }
      // translateLocally termina o arquivo com um newline final; remove só esse
      if (content.endsWith('\n')) {
        content = content.substring(0, content.length - 1);
        if (content.endsWith('\r')) content = content.substring(0, content.length - 1);
      }
      final lines = content.split(RegExp(r'\r?\n'));
      if (lines.length != sentences.length) throw PipelineException(PipelineStage.translate, 'Tradutor retornou ${lines.length} linhas para ${sentences.length} frases');
      return lines;
    } finally {
      for (final f in [srcFile, dstFile]) {
        try {
          File(f).deleteSync();
        } catch (_) {}
      }
    }
  }
}
