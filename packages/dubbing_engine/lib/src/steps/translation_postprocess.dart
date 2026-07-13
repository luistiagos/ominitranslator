/// Pós-processamento de saída de tradução automática.
///
/// O slimt decodifica guloso (beam 1, sem normalização de comprimento nem
/// penalidade de repetição), e com os modelos tiny de português ele produz um
/// padrão característico: a tradução CORRETA seguida de um eco degenerado —
/// "I would like a cup of coffee. I would like a cup of coffee."
/// (AT-1 no moto g86: 17 de 100 frases pt→en por 4-gram, mais ecos
/// parafraseados; ver docs/spikes-android/AT1.md).
///
/// Para dublagem o trade-off é assimétrico: um eco FALADO pelo TTS é
/// catastrófico; um corte de cauda é inaudível. Por isso o backend de tradução
/// que usa o slimt DEVE passar cada frase por [dedupRepeatedTail] — mesmo
/// espírito da transliteração sérvia do backend desktop: o backend conhece as
/// idiossincrasias do seu motor e as corrige antes de entregar.
///
/// Validado sobre as 100 saídas reais do aparelho
/// (`docs/spikes-android/at1-suite/`): nenhuma frase limpa é alterada.
library;

String _norm(String w) =>
    w.toLowerCase().replaceAll(RegExp(r'''[.,!?"'”“’]'''), '');

/// Corta o eco degenerado do fim de uma frase traduzida.
///
/// Quatro regras, em ordem, todas propriedades do MODO de falha (decodificação
/// gulosa que não pára no EOS), não do conteúdo:
///
/// 1. **Pontuação metralhada** — `????`/`!!`/`....` viram um sinal só (o
///    decodificador em loop cospe o mesmo token de pontuação).
/// 2. **4-gram repetido** — numa frase única de MT, uma janela de 4 palavras
///    que reaparece é degeneração, nunca linguagem legítima; corta antes da
///    repetição, recuando à última sentença completa.
/// 3. **Eco de sentença** — sentença cuja forma normalizada é prefixo de (ou
///    igual a) uma sentença anterior é o eco recomeçando; removida.
/// 4. **Fragmento final repetitivo** — o eco truncado pelo teto de comprimento
///    não termina com pontuação; se o texto após a última pontuação final tem
///    a maioria das palavras já ditas, é eco: cortado.
///
/// Frases sem esses padrões passam intocadas — inclusive repetições curtas
/// legítimas ("no, no, no"), que não disparam nenhuma das regras.
String dedupRepeatedTail(String sentence) {
  var text = sentence.trim();
  if (text.isEmpty) return text;

  // (1) pontuação metralhada
  text = text
      .replaceAll(RegExp(r'\?{2,}'), '?')
      .replaceAll(RegExp(r'!{2,}'), '!')
      .replaceAll(RegExp(r'\.{4,}'), '.');

  // (2) 4-gram repetido
  final words = text.split(RegExp(r'\s+'));
  if (words.length >= 8) {
    final seen = <String>{};
    for (int i = 0; i + 4 <= words.length; i++) {
      final gram = words.sublist(i, i + 4).map(_norm).join(' ');
      if (seen.contains(gram)) {
        var cut = words.sublist(0, i).join(' ').trim();
        final m = RegExp(r'^(.*[.!?])[^.!?]*$').firstMatch(cut);
        if (m != null && m.group(1)!.length > 10) cut = m.group(1)!;
        text = cut.trim();
        break;
      }
      seen.add(gram);
    }
  }

  // (3) eco de sentença: divide em sentenças completas + fragmento final.
  final parts = text.split(RegExp(r'(?<=[.!?])\s+'));
  if (parts.length > 1) {
    final kept = <String>[parts.first];
    for (final part in parts.skip(1)) {
      final norm = part.split(RegExp(r'\s+')).map(_norm).join(' ');
      final isEcho = norm.isNotEmpty &&
          kept.any((k) {
            final kn = k.split(RegExp(r'\s+')).map(_norm).join(' ');
            return kn == norm || kn.startsWith('$norm ');
          });
      if (!isEcho) kept.add(part);
    }
    text = kept.join(' ');
  }

  // (4) fragmento final repetitivo (sem pontuação de fechamento)
  final fragMatch = RegExp(r'^(.*[.!?])\s+([^.!?]+)$').firstMatch(text);
  if (fragMatch != null) {
    final before = fragMatch.group(1)!;
    final fragWords =
        fragMatch.group(2)!.split(RegExp(r'\s+')).map(_norm).toList();
    final saidWords = before.split(RegExp(r'\s+')).map(_norm).toSet();
    final repeated = fragWords.where(saidWords.contains).length;
    if (fragWords.isNotEmpty && repeated * 2 >= fragWords.length) {
      text = before.trim();
    }
  }

  return text.trim();
}

/// [dedupRepeatedTail] aplicado a um lote — a forma que o backend de tradução
/// consome (a interface `Translator` trabalha com listas de frases).
List<String> dedupRepeatedTails(List<String> sentences) =>
    sentences.map(dedupRepeatedTail).toList();
