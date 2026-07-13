// Inventário de bibliotecas nativas de um APK/AAB (§16.2, decisão D-d: sem CI).
//
// Sem uma CI, este é o gate: lista toda `.so` por ABI, com tamanho, SHA-256 e
// origem (o diretório `lib/<abi>/` de onde veio), e FALHA se aparecer uma ABI
// não autorizada. O release do Android M1 é só arm64-v8a (§13.2); o debug pode
// ter x86_64.
//
// Não descompacta com libs externas — lê o ZIP (APK/AAB são ZIPs) na unha, o
// suficiente para enumerar entradas e extrair cada `.so` para hashear.
//
// Uso:
//   dart run tool/check_native_libs.dart <app.apk|app.aab> [--allow x86_64]
//
// Saída: uma linha por `.so` e um veredito. Exit != 0 se houver ABI proibida.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const _releaseAbis = {'arm64-v8a'};

void main(List<String> args) {
  final positional = <String>[];
  final allowed = {..._releaseAbis};
  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--allow' && i + 1 < args.length) {
      allowed.add(args[++i]);
    } else {
      positional.add(args[i]);
    }
  }
  if (positional.isEmpty) {
    stderr.writeln('uso: dart run tool/check_native_libs.dart '
        '<app.apk|app.aab> [--allow <abi>]');
    exit(2);
  }

  final file = File(positional.first);
  if (!file.existsSync()) {
    stderr.writeln('arquivo não encontrado: ${positional.first}');
    exit(2);
  }

  final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());

  // APK: lib/<abi>/x.so   AAB: base/lib/<abi>/x.so
  final soRe = RegExp(r'(?:^|/)lib/([^/]+)/([^/]+\.so)$');
  final rows = <({String abi, String name, int size, String sha})>[];
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final m = soRe.firstMatch(entry.name);
    if (m == null) continue;
    final bytes = entry.content as List<int>;
    rows.add((
      abi: m.group(1)!,
      name: m.group(2)!,
      size: bytes.length,
      sha: sha256.convert(bytes).toString(),
    ));
  }

  rows.sort((a, b) =>
      a.abi != b.abi ? a.abi.compareTo(b.abi) : a.name.compareTo(b.name));

  stdout.writeln('Inventário de nativos — ${p.basename(file.path)}');
  stdout.writeln('ABIs permitidas: ${allowed.join(', ')}\n');
  stdout.writeln('${'ABI'.padRight(14)} ${'lib'.padRight(34)} '
      '${'tamanho'.padLeft(11)}  sha256');

  final abisSeen = <String>{};
  var totalBytes = 0;
  for (final r in rows) {
    abisSeen.add(r.abi);
    totalBytes += r.size;
    final flag = allowed.contains(r.abi) ? '' : '  <-- ABI PROIBIDA';
    stdout.writeln('${r.abi.padRight(14)} ${r.name.padRight(34)} '
        '${_fmt(r.size).padLeft(11)}  ${r.sha.substring(0, 16)}...$flag');
  }

  final forbidden = abisSeen.difference(allowed);
  stdout.writeln('\n${rows.length} .so em ${abisSeen.length} ABI(s), '
      'total ${_fmt(totalBytes)}');

  // Também escreve o inventário como JSON ao lado do artefato, para anexar ao
  // formulário de aceite (§19.2 / aceite-android.md).
  final jsonPath = '${file.path}.natives.json';
  File(jsonPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'artifact': p.basename(file.path),
    'allowedAbis': allowed.toList()..sort(),
    'libs': [
      for (final r in rows)
        {'abi': r.abi, 'name': r.name, 'size': r.size, 'sha256': r.sha}
    ],
  }));
  stdout.writeln('inventário: $jsonPath');

  if (forbidden.isNotEmpty) {
    stderr.writeln('\nFALHA: ABI não autorizada no artefato: '
        '${forbidden.join(', ')}');
    exit(1);
  }
  if (rows.isEmpty) {
    stderr.writeln('\nAVISO: nenhuma .so encontrada — o artefato é o esperado?');
    exit(1);
  }
  stdout.writeln('\nOK: todas as .so estão em ABIs permitidas.');
}

String _fmt(int bytes) {
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(1)} KB';
  return '$bytes B';
}
