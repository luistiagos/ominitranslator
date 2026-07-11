import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/steps/gender_detect.dart';
import 'package:test/test.dart';

const _sr = 16000;

Float32List _sine(double freqHz, double seconds, {double amplitude = 0.5}) {
  final n = (_sr * seconds).round();
  final out = Float32List(n);
  for (int i = 0; i < n; i++) {
    out[i] = amplitude * math.sin(2 * math.pi * freqHz * i / _sr);
  }
  return out;
}

Float32List _noise(double seconds, {double amplitude = 0.5}) {
  final rng = math.Random(42);
  final n = (_sr * seconds).round();
  final out = Float32List(n);
  for (int i = 0; i < n; i++) {
    out[i] = amplitude * (rng.nextDouble() * 2 - 1);
  }
  return out;
}

void main() {
  group('estimateFrameF0', () {
    test('finds the fundamental of a sine wave', () {
      final frame = Float32List.sublistView(_sine(150, 0.04), 0, 640);
      final f0 = estimateFrameF0(frame, _sr);
      expect(f0, isNotNull);
      expect(f0!, closeTo(150, 8));
    });

    test('rejects silence', () {
      expect(estimateFrameF0(Float32List(640), _sr), isNull);
    });

    test('rejects white noise (no periodicity)', () {
      final frame = Float32List.sublistView(_noise(0.04), 0, 640);
      expect(estimateFrameF0(frame, _sr), isNull);
    });
  });

  group('classifyF0', () {
    test('thresholds', () {
      expect(classifyF0(120), VoiceGender.male);
      expect(classifyF0(220), VoiceGender.female);
      expect(classifyF0(165), VoiceGender.unknown); // faixa ambígua
      expect(classifyF0(null), VoiceGender.unknown);
    });
  });

  group('classifyAge', () {
    test('thresholds', () {
      expect(classifyAge(120), AgeBand.adult);
      expect(classifyAge(220), AgeBand.adult);
      expect(classifyAge(300), AgeBand.child);
      expect(classifyAge(null), AgeBand.unknown);
    });
  });

  group('profileFromTagScores', () {
    test('male speech wins', () {
      final p = profileFromTagScores({tagMaleSpeech: 0.3, tagFemaleSpeech: 0.1});
      expect(p, SpeakerProfile(VoiceGender.male, AgeBand.adult));
    });

    test('female speech wins', () {
      final p = profileFromTagScores({tagFemaleSpeech: 0.4, tagMaleSpeech: 0.2});
      expect(p, SpeakerProfile(VoiceGender.female, AgeBand.adult));
    });

    test('child speech wins', () {
      final p = profileFromTagScores(
          {tagChildSpeech: 0.5, tagMaleSpeech: 0.1, tagFemaleSpeech: 0.1});
      expect(p, SpeakerProfile(VoiceGender.unknown, AgeBand.child));
    });

    test('weak scores fall back to the pitch profile', () {
      const fallback = SpeakerProfile(VoiceGender.male, AgeBand.adult);
      final p = profileFromTagScores({tagMaleSpeech: 0.01}, fallback: fallback);
      expect(p, fallback);
    });

    test('empty scores fall back', () {
      expect(profileFromTagScores({}), SpeakerProfile.unknown);
    });
  });

  group('detectSpeakerProfiles', () {
    test('classifies pitch into gender and age bands', () {
      // 2 s de "voz" de cada falante, concatenadas:
      // 120 Hz (homem), 220 Hz (mulher), 300 Hz (criança).
      final male = _sine(120, 2.0);
      final female = _sine(220, 2.0);
      final child = _sine(300, 2.0);
      final samples = Float32List(male.length + female.length + child.length)
        ..setAll(0, male)
        ..setAll(male.length, female)
        ..setAll(male.length + female.length, child);
      final turns = const [
        SpeakerTurn(0.0, 2.0, 10),
        SpeakerTurn(2.0, 4.0, 20),
        SpeakerTurn(4.0, 6.0, 30),
      ];
      final profiles = detectSpeakerProfiles(samples, _sr, turns);
      expect(profiles, {
        10: SpeakerProfile(VoiceGender.male, AgeBand.adult),
        20: SpeakerProfile(VoiceGender.female, AgeBand.adult),
        // Criança: sexo indeterminado por definição.
        30: SpeakerProfile(VoiceGender.unknown, AgeBand.child),
      });
    });

    test('noisy speaker is fully unknown', () {
      final samples = _noise(2.0);
      final profiles =
          detectSpeakerProfiles(samples, _sr, const [SpeakerTurn(0.0, 2.0, 1)]);
      expect(profiles, {1: SpeakerProfile.unknown});
    });

    test('too little voiced audio is fully unknown', () {
      // 100 ms só: menos que o mínimo de frames voiced exigido.
      final samples = _sine(120, 0.1);
      final profiles =
          detectSpeakerProfiles(samples, _sr, const [SpeakerTurn(0.0, 0.1, 1)]);
      expect(profiles, {1: SpeakerProfile.unknown});
    });
  });
}
