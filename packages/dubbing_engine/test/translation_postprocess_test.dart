import 'package:dubbing_engine/src/steps/translation_postprocess.dart';
import 'package:test/test.dart';

void main() {
  group('dedupRepeatedTail — casos reais do AT-1 (moto g86, pt→en tiny)', () {
    // Pares (saída degenerada do slimt, frase esperada após o corte),
    // colhidos de docs/spikes-android/at1-suite/out_pten.txt.
    const realCases = <(String, String)>[
      (
        'I would like a cup of coffee. I would like a cup of coffee.',
        'I would like a cup of coffee.'
      ),
      (
        'She speaks four languages fluently. She speaks four languages fluently.',
        'She speaks four languages fluently.'
      ),
      (
        'My grandmother taught me how to cook. I taught me how to cook.',
        'My grandmother taught me how to cook.'
      ),
      (
        'Can you help me to carry these boxes? can you help me to carry these',
        'Can you help me to carry these boxes?'
      ),
      (
        'I lost my keys somewhere in the park. I lost my keys somewhere',
        'I lost my keys somewhere in the park.'
      ),
      (
        "I usually wake up at six o'clock. I wake up at six o",
        "I usually wake up at six o'clock."
      ),
      (
        'We planted a tree in the yard. we planted a tree in the',
        'We planted a tree in the yard.'
      ),
      (
        'He plays guitar in a local band. He plays guitar in a local band.',
        'He plays guitar in a local band.'
      ),
      (
        "I can't find my glasses anywhere. I can't find my glasses",
        "I can't find my glasses anywhere."
      ),
      (
        'The farmer wakes up before dawn. The farmer wakes up before da',
        'The farmer wakes up before dawn.'
      ),
      (
        "I don't understand this math problem. I don't understand this math",
        "I don't understand this math problem."
      ),
      (
        'The cat jumped on the kitchen table. The cat jumped on the kitchen table.',
        'The cat jumped on the kitchen table.'
      ),
      (
        'The store closes early on Sundays. The store closes early on Sunday',
        'The store closes early on Sundays.'
      ),
      (
        'I left my coat on the bus this morning. I left my coat on the',
        'I left my coat on the bus this morning.'
      ),
      (
        'I always drink tea before bedtime. I always drink tea.',
        'I always drink tea before bedtime.'
      ),
    ];

    for (final (input, expected) in realCases) {
      test('corta o eco: "${expected.substring(0, 25)}…"', () {
        expect(dedupRepeatedTail(input), expected);
      });
    }

    // Ecos PARAFRASEADOS ou curtos demais para o 4-gram — pegos pelas regras
    // de eco-de-sentença e fragmento final repetitivo. Também casos reais.
    const paraphrasedEchoes = <(String, String)>[
      (
        "I'm afraid of spiders and snakes. I'm afraid of",
        "I'm afraid of spiders and snakes."
      ),
      (
        "I promise I'll call you when I get here. I'll call",
        "I promise I'll call you when I get here."
      ),
      (
        'The printer ran out of ink again. The printer was left without ink',
        'The printer ran out of ink again.'
      ),
      (
        'Could you tell me where the station is???? Can you tell me',
        'Could you tell me where the station is?'
      ),
    ];
    for (final (input, expected) in paraphrasedEchoes) {
      test('eco parafraseado: "${expected.substring(0, 25)}…"', () {
        expect(dedupRepeatedTail(input), expected);
      });
    }

    test('sentença-eco no meio é removida (prefixo de sentença anterior)', () {
      expect(
        dedupRepeatedTail(
            'She smiled and waved from the window. She smiled. He walked away.'),
        'She smiled and waved from the window. He walked away.',
      );
    });

    test('pontuação metralhada é colapsada', () {
      expect(dedupRepeatedTail('Where is it????'), 'Where is it?');
      expect(dedupRepeatedTail('Ontem, comprou três livros......'),
          'Ontem, comprou três livros.');
      // Reticências legítimas (3 pontos) ficam.
      expect(dedupRepeatedTail('Well... maybe.'), 'Well... maybe.');
    });

    test('eco severo (loop no meio) é cortado, mesmo sem recuperação perfeita', () {
      // "dia sim, dia não": o modelo tiny já errava ANTES do loop — nenhum
      // decodificador salvaria. O dedup corta o loop; a frase fica curta mas
      // sem eco (o TTS não repete).
      const severe =
          'I water the plants day out day, day out, I revel in the plants day out. Day, I re';
      final out = dedupRepeatedTail(severe);
      expect(out.length, lessThan(severe.length));
      // Sem 4-gram repetido na saída:
      final words = out
          .toLowerCase()
          .replaceAll(RegExp(r'''[.,!?"'”“’]'''), '')
          .split(RegExp(r'\s+'));
      final grams = <String>{};
      for (int i = 0; i + 4 <= words.length; i++) {
        expect(grams.add(words.sublist(i, i + 4).join(' ')), isTrue,
            reason: 'saída ainda tem 4-gram repetido');
      }
    });
  });

  group('dedupRepeatedTail — não pode tocar em frase limpa', () {
    const clean = <String>[
      'The weather is beautiful today.',
      'The train leaves at 7 a.m.',
      'She bought three books yesterday.',
      'The bridge was built more than a hundred years ago.',
      // Repetições CURTAS legítimas (não formam 4-gram): ficam intactas.
      'It was a very, very long day.',
      'He said no, no, no — never again.',
      // Frase longa sem repetição:
      'The bus was so full I had to stay on my feet until the very last stop of the line.',
    ];
    for (final s in clean) {
      test('intocada: "${s.substring(0, 20)}…"', () {
        expect(dedupRepeatedTail(s), s);
      });
    }

    test('vazia e curtas não quebram', () {
      expect(dedupRepeatedTail(''), '');
      expect(dedupRepeatedTail('Oi.'), 'Oi.');
      expect(dedupRepeatedTail('   spaced   '), 'spaced');
    });
  });

  test('dedupRepeatedTails aplica ao lote preservando a ordem e o tamanho', () {
    final out = dedupRepeatedTails([
      'The weather is beautiful today.',
      'I would like a cup of coffee. I would like a cup of coffee.',
      '',
    ]);
    expect(out, [
      'The weather is beautiful today.',
      'I would like a cup of coffee.',
      '',
    ]);
  });
}
