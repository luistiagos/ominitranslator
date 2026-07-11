// Gera entradas ModelEntry para vozes piper novas, a partir do catálogo
// oficial rhasspy/piper-voices, restrito às línguas-alvo do app e validando
// cada URL do release sherpa-onnx (HEAD, sem hits na API do GitHub — que
// tem rate limit agressivo para requisições anônimas).
//
// Uso:
//   dart run tool/gen_voice_manifest.dart [--voices-json <url|caminho>]
//   dart run tool/gen_voice_manifest.dart --deep <key>
//
// A saída (stdout) é colada manualmente no manifest em model_manager.dart
// depois de revisada — este script não escreve no manifest sozinho.
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:dubbing_engine/src/model_manager.dart';

/// Locales do voices.json cobertos pelas línguas-alvo atuais (en/es/pt já
/// tinham vozes; de/fr/pl/cs/bg são novas). Ajuste ao adicionar mais alvos.
const _targetLocales = {
  'en_GB', 'en_US',
  'es_AR', 'es_ES', 'es_MX',
  'pt_BR', 'pt_PT',
  'de_DE', 'fr_FR', 'pl_PL', 'cs_CZ', 'bg_BG',
};

/// Ordem de preferência de qualidade quando uma voz tem mais de uma.
const _qualityRank = ['medium', 'high', 'low', 'x_low'];

const _sherpaBaseUrl =
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-';

const _diacriticMap = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o',
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u',
  'ç': 'c', 'ñ': 'n', 'ß': 'ss',
};

String _stripDiacritics(String s) {
  final buf = StringBuffer();
  for (final ch in s.split('')) {
    buf.write(_diacriticMap[ch] ?? ch);
  }
  return buf.toString();
}

Future<void> main(List<String> args) async {
  final deepIdx = args.indexOf('--deep');
  if (deepIdx >= 0 && deepIdx + 1 < args.length) {
    await _deepInspect(args[deepIdx + 1]);
    return;
  }

  final jsonIdx = args.indexOf('--voices-json');
  final voicesJsonSource = jsonIdx >= 0 && jsonIdx + 1 < args.length
      ? args[jsonIdx + 1]
      : 'https://huggingface.co/rhasspy/piper-voices/resolve/main/voices.json';

  stderr.writeln('Lendo voices.json de $voicesJsonSource ...');
  final raw = voicesJsonSource.startsWith('http')
      ? (await http.get(Uri.parse(voicesJsonSource))).body
      : File(voicesJsonSource).readAsStringSync();
  final data = jsonDecode(raw) as Map<String, dynamic>;

  // Chaves (locale-name-quality) já presentes no manifest atual — não
  // duplicar vozes já baixáveis sob outro id.
  final existingKeys = <String>{};
  for (final e in ModelManager.manifest) {
    final m = RegExp(r'vits-piper-(.+)\.tar\.bz2$').firstMatch(e.url);
    if (m != null) existingKeys.add(m.group(1)!);
  }
  stderr.writeln('${existingKeys.length} vozes já no manifest (excluídas).');

  // Agrupa por (locale, nome), escolhendo a melhor qualidade disponível.
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final entry in data.values) {
    final v = entry as Map<String, dynamic>;
    final locale = (v['language'] as Map<String, dynamic>)['code'] as String;
    if (!_targetLocales.contains(locale)) continue;
    final name = v['name'] as String;
    groups.putIfAbsent('$locale-$name', () => []).add(v);
  }

  final candidates = <({
    String key,
    String locale,
    String name,
    int numSpeakers,
  })>[];
  for (final group in groups.entries) {
    group.value.sort((a, b) =>
        _qualityRank.indexOf(a['quality']).compareTo(_qualityRank.indexOf(b['quality'])));
    final best = group.value.first;
    final key = best['key'] as String;
    if (existingKeys.contains(key)) continue;
    final locale = (best['language'] as Map<String, dynamic>)['code'] as String;
    candidates.add((
      key: key,
      locale: locale,
      name: best['name'] as String,
      numSpeakers: (best['num_speakers'] as num).toInt(),
    ));
  }
  stderr.writeln('${candidates.length} vozes candidatas (após dedupe/exclusão).');

  final client = http.Client();
  final accepted = <({String key, String locale, String name, int numSpeakers, int sizeMb})>[];
  final dropped = <String>[];
  try {
    for (final c in candidates) {
      final direct = await _headSize(client, '$_sherpaBaseUrl${c.key}.tar.bz2');
      if (direct != null) {
        accepted.add((key: c.key, locale: c.locale, name: c.name, numSpeakers: c.numSpeakers, sizeMb: direct));
        stderr.writeln('OK   ${c.key} ($direct MB)');
        continue;
      }
      // Fallback: variante ASCII (nomes com diacríticos, ex.: pt_PT-tugão).
      final asciiKey = _stripDiacritics(c.key);
      if (asciiKey != c.key) {
        final asciiSize = await _headSize(client, '$_sherpaBaseUrl$asciiKey.tar.bz2');
        if (asciiSize != null) {
          accepted.add((key: asciiKey, locale: c.locale, name: c.name, numSpeakers: c.numSpeakers, sizeMb: asciiSize));
          stderr.writeln('OK   ${c.key} -> ASCII $asciiKey ($asciiSize MB)');
          continue;
        }
      }
      dropped.add(c.key);
      stderr.writeln('DROP ${c.key} (404 direto e ASCII)');
    }
  } finally {
    client.close();
  }

  stderr.writeln('\n${accepted.length} vozes validadas, ${dropped.length} descartadas.');
  if (dropped.isNotEmpty) {
    stderr.writeln('Descartadas: ${dropped.join(', ')}');
  }

  // Emite ModelEntry Dart, prontos para colar no manifest.
  for (final v in accepted) {
    final slug = v.key.replaceAll('_', '-').toLowerCase();
    final id = 'piper-$slug';
    final speakerNote = v.numSpeakers > 1 ? ' (multi, ${v.numSpeakers} vozes)' : '';
    print('    ModelEntry(');
    print("      id: '$id',");
    print("      kind: 'tarbz2',");
    print("      url: '$_sherpaBaseUrl${v.key}.tar.bz2',");
    print('      sizeMb: ${v.sizeMb},');
    print("      expects: ['${v.key}.onnx', 'tokens.txt', 'espeak-ng-data'],");
    print("      displayName: 'Voz — ${v.locale} ${v.name}$speakerNote',");
    print('    ),');
  }
}

Future<int?> _headSize(http.Client client, String url) async {
  try {
    final resp = await client.head(Uri.parse(url));
    if (resp.statusCode != 200) return null;
    final len = int.tryParse(resp.headers['content-length'] ?? '');
    if (len == null) return null;
    return (len / 1e6).ceil();
  } catch (_) {
    return null;
  }
}

/// Baixa um tarball e lista seu conteúdo, para conferir os nomes reais dos
/// arquivos internos (ex.: vozes com diacríticos no nome, onde o .onnx
/// interno pode não bater com o padrão `<key>.onnx`).
Future<void> _deepInspect(String key) async {
  final url = '$_sherpaBaseUrl$key.tar.bz2';
  stderr.writeln('Baixando $url ...');
  final safeName = 'gen_voice_deep_$key.tar.bz2'.replaceAll(RegExp('[<>:"|?*]'), '_');
  final tmp = File('${Directory.systemTemp.path}\\$safeName');
  final resp = await http.get(Uri.parse(url));
  if (resp.statusCode != 200) {
    stderr.writeln('HTTP ${resp.statusCode} para $url');
    exitCode = 1;
    return;
  }
  tmp.writeAsBytesSync(resp.bodyBytes);
  final result = await Process.run('tar', ['-tjf', tmp.path]);
  stdout.write(result.stdout);
  if (result.exitCode != 0) stderr.write(result.stderr);
  tmp.deleteSync();
}
