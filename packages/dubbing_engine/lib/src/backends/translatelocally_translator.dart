import 'dart:convert';
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/translation_catalog.dart';

// Sérvio cirílico → latino. O modelo hbs-eng-tiny só entende sérvio em
// script latino — testado empiricamente: o mesmo texto em cirílico produz
// traduções sem sentido ("Мачка спава на каучу." → "I'm on it."), enquanto
// em latino traduz corretamente. O alfabeto cirílico sérvio (Vuk Karadžić)
// tem correspondência 1:1 com o latino, então a conversão é sem perdas.
// Caracteres fora do mapa (texto já em latino, pontuação, outros idiomas)
// passam intactos — seguro de aplicar mesmo que o whisper já transcreva em
// latino.
const _serbianCyrillicDigraphs = {'Љ': 'Lj', 'Њ': 'Nj', 'Џ': 'Dž'};
const _serbianCyrillicSingles = {
  'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'ђ': 'đ', 'е': 'e',
  'ж': 'ž', 'з': 'z', 'и': 'i', 'ј': 'j', 'к': 'k', 'л': 'l', 'м': 'm',
  'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'ћ': 'ć',
  'у': 'u', 'ф': 'f', 'х': 'h', 'ц': 'c', 'ч': 'č', 'ш': 'š',
  'А': 'A', 'Б': 'B', 'В': 'V', 'Г': 'G', 'Д': 'D', 'Ђ': 'Đ', 'Е': 'E',
  'Ж': 'Ž', 'З': 'Z', 'И': 'I', 'Ј': 'J', 'К': 'K', 'Л': 'L', 'М': 'M',
  'Н': 'N', 'О': 'O', 'П': 'P', 'Р': 'R', 'С': 'S', 'Т': 'T', 'Ћ': 'Ć',
  'У': 'U', 'Ф': 'F', 'Х': 'H', 'Ц': 'C', 'Ч': 'Č', 'Ш': 'Š',
};

String _serbianCyrillicToLatin(String text) {
  final buf = StringBuffer();
  for (final ch in text.split('')) {
    buf.write(_serbianCyrillicDigraphs[ch] ?? _serbianCyrillicSingles[ch] ?? ch);
  }
  return buf.toString();
}

class TranslateLocallyTranslator implements Translator {
  final Tools tools;
  final ModelManager models;
  TranslateLocallyTranslator(this.tools, this.models);

  @override
  Future<List<String>> translate(
      List<String> sentences, Lang from, Lang to, CancellationToken token,
      {RunToolStdinFn? runToolOverride, RunToolFn? downloadOverride}) async {
    if (from == to) return sentences;
    // Offline-first: tenta traduzir direto com os modelos já instalados.
    // Só baixa modelos (rede) se a tradução falhar — assim um job com
    // modelos presentes funciona sem internet.
    try {
      return await _translatePair(sentences, from, to, token, runToolOverride: runToolOverride);
    } on PipelineException {
      await models.ensureTranslationModels(from, to, token, runToolOverride: downloadOverride);
      return _translatePair(sentences, from, to, token, runToolOverride: runToolOverride);
    }
  }

  Future<List<String>> _translatePair(
      List<String> sentences, Lang from, Lang to, CancellationToken token, {RunToolStdinFn? runToolOverride}) async {
    var current = sentences;
    for (final (f, t) in translationPath(from, to)) {
      current = await _runTranslate(current, f, t, token, runToolOverride: runToolOverride);
    }
    return current;
  }

  Future<List<String>> _runTranslate(
      List<String> sentences, Lang from, Lang to, CancellationToken token, {RunToolStdinFn? runToolOverride}) async {
    final exec = runToolOverride ?? runToolWithStdin;
    final modelId = directTranslationModelId(from, to)!;
    var prepared = sentences.map((s) => s.replaceAll(RegExp(r'[\n\r]'), ' '));
    if (from == Lang.sr) {
      prepared = prepared.map(_serbianCyrillicToLatin);
    }
    final input = prepared.join('\n');
    // O translateLocally usa UTF-8 na entrada/saída padrão (stdin/stdout) —
    // ao contrário do I/O por arquivo (-i/-o), que usa o encoding local do
    // sistema e corrompe acentos/cirílico/grego. NUNCA usar allowMalformed:
    // os U+FFFD resultantes viravam sílabas faladas pelo TTS no meio de
    // toda palavra acentuada.
    final result = await exec(
        tools.translateLocally, ['-m', modelId], utf8.encode('$input\n'),
        token: token);
    if (result.exitCode != 0) throw PipelineException(PipelineStage.translate, 'translateLocally falhou com código ${result.exitCode}');
    var content = result.stdout;
    // translateLocally termina a saída com um newline final; remove só esse.
    if (content.endsWith('\n')) {
      content = content.substring(0, content.length - 1);
      if (content.endsWith('\r')) content = content.substring(0, content.length - 1);
    }
    final lines = content.split(RegExp(r'\r?\n'));
    if (lines.length != sentences.length) throw PipelineException(PipelineStage.translate, 'Tradutor retornou ${lines.length} linhas para ${sentences.length} frases');
    return lines;
  }
}
