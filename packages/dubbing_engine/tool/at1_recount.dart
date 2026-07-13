// Reexecuta a contagem do gate AT-1 aplicando o pós-processamento de produção
// (dedupRepeatedTail) sobre as saídas reais colhidas no moto g86.
//
// Gera `out_pten_dedup.txt` ao lado das evidências — é o que o backend de
// tradução Android entregaria ao pipeline.
//
// Uso: dart run tool/at1_recount.dart
import 'dart:io';

import 'package:dubbing_engine/src/steps/translation_postprocess.dart';

bool _hasRep(String line) {
  final words = line
      .toLowerCase()
      .replaceAll(RegExp(r'''[.,!?"'”“’]'''), '')
      .split(RegExp(r'\s+'));
  final seen = <String>{};
  for (int i = 0; i + 4 <= words.length; i++) {
    if (!seen.add(words.sublist(i, i + 4).join(' '))) return true;
  }
  return false;
}

void main() {
  const dir = r'..\..\docs\spikes-android\at1-suite';
  for (final name in ['out_enpt', 'out_pten']) {
    final raw = File('$dir\\$name.txt').readAsLinesSync();
    final processed = dedupRepeatedTails(raw);
    final beforeRep = raw.where(_hasRep).length;
    final afterRep = processed.where(_hasRep).length;
    final nonEmpty = processed.where((l) => l.trim().isNotEmpty).length;
    print('$name: ${raw.length} frases | degeneradas cru=$beforeRep -> '
        'pós-dedup=$afterRep | não vazias=$nonEmpty');
    if (name == 'out_pten') {
      File('$dir\\out_pten_dedup.txt')
          .writeAsStringSync('${processed.join('\n')}\n');
      print('  evidência gravada: out_pten_dedup.txt');
    }
  }
}
