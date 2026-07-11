import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/backends/piper_synthesizer.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/steps/speaker_assign.dart';
import 'package:test/test.dart';

TranscriptSegment _seg(int startMs, int endMs, [String text = 'x']) =>
    TranscriptSegment(Duration(milliseconds: startMs), Duration(milliseconds: endMs), text);

void main() {
  group('assignSpeakers', () {
    test('empty turns keeps all speakers at 0', () {
      final result = assignSpeakers([_seg(0, 500), _seg(600, 1000)], const []);
      expect(result.map((s) => s.speaker), everyElement(0));
    });

    test('picks the turn with the largest overlap', () {
      final turns = const [
        SpeakerTurn(0.0, 2.0, 1), // 2s de fala → índice 0
        SpeakerTurn(2.0, 3.0, 2), // 1s de fala → índice 1
      ];
      // Segmento 1.8–2.9s: 0.2s de sobreposição com o falante 1,
      // 0.9s com o falante 2 → falante 2 (renumerado para 1).
      final result = assignSpeakers([_seg(1800, 2900)], turns);
      expect(result.single.speaker, 1);
    });

    test('segment without overlap gets the nearest turn', () {
      final turns = const [
        SpeakerTurn(0.0, 1.0, 5),
        SpeakerTurn(10.0, 15.0, 9), // mais tempo de fala → índice 0
      ];
      // Segmento 8.5–9.5s: sem sobreposição; mais perto do turno de 10s.
      final result = assignSpeakers([_seg(8500, 9500)], turns);
      expect(result.single.speaker, 0);
    });

    test('renumbers clusters by total airtime (0 = main speaker)', () {
      final turns = const [
        SpeakerTurn(0.0, 1.0, 42), // 1s
        SpeakerTurn(1.0, 5.0, 7), // 4s → falante principal
        SpeakerTurn(5.0, 6.0, 42), // +1s → total 2s
      ];
      final result = assignSpeakers([_seg(0, 900), _seg(1100, 4900)], turns);
      expect(result[0].speaker, 1); // cluster 42
      expect(result[1].speaker, 0); // cluster 7 (mais fala)
    });
  });

  group('pruneMinorSpeakers', () {
    test('absorbs ghost clusters into the temporally nearest major speaker', () {
      final turns = const [
        SpeakerTurn(0.0, 10.0, 1),
        SpeakerTurn(10.0, 20.0, 2),
        // Fantasma: 1s de fala (< 3s absolutos e < 8% do total).
        SpeakerTurn(20.0, 21.0, 3),
      ];
      final pruned = pruneMinorSpeakers(turns);
      expect(pruned.map((t) => t.speaker), [1, 2, 2]);
      // Tempos preservados.
      expect(pruned[2].start, 20.0);
      expect(pruned[2].end, 21.0);
    });

    test('keeps small speakers that are relatively significant', () {
      final turns = const [
        SpeakerTurn(0.0, 8.0, 1),
        // 2s absolutos, mas 20% do total (>= 8%): falante real.
        SpeakerTurn(8.0, 10.0, 2),
      ];
      final pruned = pruneMinorSpeakers(turns);
      expect(pruned.map((t) => t.speaker), [1, 2]);
    });

    test('returns turns unchanged when there are no major speakers', () {
      final turns = const [SpeakerTurn(0.0, 1.0, 1)];
      expect(pruneMinorSpeakers(turns).map((t) => t.speaker), [1]);
    });
  });

  group('assignSpeakers estabilidade', () {
    test('low-overlap segment inherits the previous speaker', () {
      final turns = const [
        SpeakerTurn(0.0, 5.0, 7),
        SpeakerTurn(5.2, 5.4, 9), // turno minúsculo colado no segmento
      ];
      // seg2 (5.5–6.5s) não sobrepõe nada; o mais próximo é o turno 9,
      // mas a continuidade com o falante anterior deve vencer.
      final result = assignSpeakers([_seg(0, 2000), _seg(5500, 6500)], turns);
      expect(result[0].speaker, 0);
      expect(result[1].speaker, 0);
    });

    test('short isolated speaker flip between equal neighbors is smoothed', () {
      final turns = const [
        SpeakerTurn(0.0, 3.0, 7),
        SpeakerTurn(3.0, 4.0, 9),
        SpeakerTurn(4.0, 10.0, 7),
      ];
      final result = assignSpeakers(
          [_seg(0, 2800), _seg(3000, 3900), _seg(4100, 6000)], turns);
      // O flip de 0.9s no meio é erro de fronteira: suavizado.
      expect(result.map((s) => s.speaker), [0, 0, 0]);
    });

    test('long middle segment keeps its own speaker (real turn change)', () {
      final turns = const [
        SpeakerTurn(0.0, 5.0, 7),
        SpeakerTurn(5.0, 9.0, 9),
        SpeakerTurn(9.0, 14.0, 7),
      ];
      final result = assignSpeakers(
          [_seg(0, 4500), _seg(5000, 8500), _seg(9500, 13000)], turns);
      expect(result.map((s) => s.speaker), [0, 1, 0]);
    });
  });

  group('buildVoiceSlots', () {
    test('single-speaker engines contribute one slot each, with gender', () {
      final slots = buildVoiceSlots([
        (numSpeakers: 1, sidGenders: [VoiceGender.male]),
        (numSpeakers: 1, sidGenders: [VoiceGender.female]),
      ]);
      expect(slots, [
        (engine: 0, sid: 0, gender: VoiceGender.male),
        (engine: 1, sid: 0, gender: VoiceGender.female),
      ]);
    });

    test('multi-speaker engines are capped at maxVoicesPerModel', () {
      final slots = buildVoiceSlots([
        (numSpeakers: 904, sidGenders: const <VoiceGender>[]),
      ]);
      expect(slots.length, 4);
      expect(slots.map((s) => s.engine), everyElement(0));
      expect(slots.map((s) => s.sid), [0, 1, 2, 3]);
      expect(slots.map((s) => s.gender), everyElement(VoiceGender.unknown));
    });

    test('numSpeakers <= 0 is treated as single voice', () {
      final slots = buildVoiceSlots([
        (numSpeakers: 0, sidGenders: const <VoiceGender>[]),
      ]);
      expect(slots, [(engine: 0, sid: 0, gender: VoiceGender.unknown)]);
    });

    test('sids beyond the curated gender list are unknown', () {
      final slots = buildVoiceSlots([
        (numSpeakers: 3, sidGenders: [VoiceGender.female]),
      ]);
      expect(slots.map((s) => s.gender),
          [VoiceGender.female, VoiceGender.unknown, VoiceGender.unknown]);
    });
  });

  group('assignVoicesToSpeakers', () {
    SpeakerProfile adult(VoiceGender g) => SpeakerProfile(g, AgeBand.adult);
    const child = SpeakerProfile(VoiceGender.unknown, AgeBand.child);

    test('matches speakers to slots of the same gender', () {
      final slots = [VoiceGender.male, VoiceGender.female];
      final result = assignVoicesToSpeakers(
          {0: adult(VoiceGender.female), 1: adult(VoiceGender.male)}, slots);
      expect(result, {0: 1, 1: 0});
    });

    test('unknown speaker gender takes the first free slot', () {
      final slots = [VoiceGender.male, VoiceGender.female];
      final result = assignVoicesToSpeakers(
          {0: adult(VoiceGender.unknown), 1: adult(VoiceGender.female)}, slots);
      expect(result, {0: 0, 1: 1});
    });

    test('falls back to unknown slot when gender has no free slot', () {
      final slots = [VoiceGender.male, VoiceGender.unknown];
      final result = assignVoicesToSpeakers(
          {0: adult(VoiceGender.female), 1: adult(VoiceGender.male)}, slots);
      expect(result, {0: 1, 1: 0});
    });

    test('reuses slots of the same gender when exhausted', () {
      final slots = [VoiceGender.male, VoiceGender.female];
      final result = assignVoicesToSpeakers({
        0: adult(VoiceGender.male),
        1: adult(VoiceGender.female),
        2: adult(VoiceGender.male),
        3: adult(VoiceGender.male),
      }, slots);
      expect(result[0], 0);
      expect(result[1], 1);
      // Esgotados: masculinos reusam apenas o slot masculino.
      expect(result[2], 0);
      expect(result[3], 0);
    });

    test('main speaker gets priority over later speakers', () {
      final slots = [VoiceGender.female];
      final result = assignVoicesToSpeakers(
          {1: adult(VoiceGender.female), 0: adult(VoiceGender.female)}, slots);
      expect(result[0], 0); // falante 0 pega o único slot livre
      expect(result[1], 0); // reuso
    });

    test('child prefers a female slot (higher base pitch for the shift)', () {
      final slots = [VoiceGender.male, VoiceGender.female];
      final result =
          assignVoicesToSpeakers({0: child, 1: adult(VoiceGender.male)}, slots);
      expect(result, {0: 1, 1: 0});
    });

    test('unknown speaker in an all-male cast avoids the female slot', () {
      // Banco pt-BR: faber (M), dii (F), edresson (M). Um falante unknown
      // não deve cair na voz feminina só porque ela é o primeiro slot livre.
      final slots = [VoiceGender.male, VoiceGender.female, VoiceGender.male];
      final result = assignVoicesToSpeakers(
          {0: adult(VoiceGender.male), 1: adult(VoiceGender.unknown)}, slots);
      expect(result, {0: 0, 1: 2});
    });

    test('unknown speaker does not steal an identified speaker\'s gender slot', () {
      final slots = [VoiceGender.male, VoiceGender.female];
      // O unknown (índice 0, processado "antes" na ordem) não pode roubar
      // o slot feminino da falante identificada.
      final result = assignVoicesToSpeakers(
          {0: adult(VoiceGender.unknown), 1: adult(VoiceGender.female)}, slots);
      expect(result[1], 1);
      expect(result[0], 0);
    });
  });
}
