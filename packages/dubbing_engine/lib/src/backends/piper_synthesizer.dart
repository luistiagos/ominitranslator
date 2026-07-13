import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/backends/sherpa_bindings.dart';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:path/path.dart' as p;

typedef VoiceSlot = ({int engine, int sid, VoiceGender gender});

/// Expande os motores TTS disponíveis em "slots" de voz `(engine, sid)`,
/// cada um com o sexo curado em [voiceSidGenders]. Cada motor contribui com
/// até [maxVoicesPerModel] vozes (modelos multi-falante têm dezenas/centenas
/// de sids; um elenco pequeno e fixo mantém as vozes consistentes).
List<VoiceSlot> buildVoiceSlots(
    List<({int numSpeakers, List<VoiceGender> sidGenders})> engines) {
  final slots = <VoiceSlot>[];
  for (int engine = 0; engine < engines.length; engine++) {
    final e = engines[engine];
    final n = e.numSpeakers <= 0 ? 1 : e.numSpeakers;
    final count = n < maxVoicesPerModel ? n : maxVoicesPerModel;
    for (int sid = 0; sid < count; sid++) {
      final gender =
          sid < e.sidGenders.length ? e.sidGenders[sid] : VoiceGender.unknown;
      slots.add((engine: engine, sid: sid, gender: gender));
    }
  }
  return slots;
}

/// Escolhe um slot de voz para cada falante, casando o sexo quando possível.
/// Falantes em ordem de índice (0 = principal); cada um pega o primeiro slot
/// livre do seu sexo; sem match, um slot livre `unknown`, senão qualquer
/// livre; esgotados os slots, reuso por módulo entre os do mesmo sexo (ou
/// todos, se não houver nenhum do sexo). Crianças usam a cadeia da voz
/// feminina (base mais aguda — melhor para o pitch-shift infantil).
/// Falantes de sexo indeterminado assumem o sexo predominante do elenco
/// detectado (num vídeo só de homens, um "unknown" não deve cair numa voz
/// feminina só porque ela era o primeiro slot livre).
/// Retorna falante → índice do slot.
Map<int, int> assignVoicesToSpeakers(
    Map<int, SpeakerProfile> speakerProfiles, List<VoiceGender> slotGenders) {
  final used = List<bool>.filled(slotGenders.length, false);
  final result = <int, int>{};
  final reuseCounter = <VoiceGender, int>{};
  final speakers = speakerProfiles.keys.toList()..sort();

  int? firstFree(bool Function(int slot) matches) {
    for (int i = 0; i < slotGenders.length; i++) {
      if (!used[i] && matches(i)) return i;
    }
    return null;
  }

  // Sexo predominante entre os falantes identificados, usado como palpite
  // para os indeterminados.
  final maleCount = speakerProfiles.values
      .where((p) => p.gender == VoiceGender.male)
      .length;
  final femaleCount = speakerProfiles.values
      .where((p) => p.gender == VoiceGender.female)
      .length;
  final modalGender = maleCount > femaleCount
      ? VoiceGender.male
      : (femaleCount > maleCount ? VoiceGender.female : VoiceGender.unknown);

  VoiceGender effectiveGender(int speaker) {
    final profile = speakerProfiles[speaker] ?? SpeakerProfile.unknown;
    if (profile.age == AgeBand.child) return VoiceGender.female;
    return profile.gender;
  }

  void assign(int speaker, VoiceGender gender) {
    int? slot;
    if (gender != VoiceGender.unknown) {
      slot = firstFree((i) => slotGenders[i] == gender);
      slot ??= firstFree((i) => slotGenders[i] == VoiceGender.unknown);
    } else {
      slot = firstFree((i) => slotGenders[i] == VoiceGender.unknown);
    }
    slot ??= firstFree((_) => true);
    if (slot != null) {
      used[slot] = true;
      result[speaker] = slot;
      return;
    }
    // Todos ocupados: reusa por módulo entre os slots do mesmo sexo,
    // ou entre todos se o sexo não tem nenhum slot.
    final pool = <int>[];
    if (gender != VoiceGender.unknown) {
      for (int i = 0; i < slotGenders.length; i++) {
        if (slotGenders[i] == gender) pool.add(i);
      }
    }
    if (pool.isEmpty) {
      pool.addAll(List.generate(slotGenders.length, (i) => i));
    }
    final counter = reuseCounter[gender] ?? 0;
    reuseCounter[gender] = counter + 1;
    result[speaker] = pool[counter % pool.length];
  }

  // Duas passadas: falantes com sexo identificado escolhem primeiro (um
  // "unknown" não pode roubar o slot feminino da única mulher do vídeo);
  // os indeterminados vêm depois, com o sexo predominante como palpite.
  for (final speaker in speakers) {
    if (effectiveGender(speaker) != VoiceGender.unknown) {
      assign(speaker, effectiveGender(speaker));
    }
  }
  for (final speaker in speakers) {
    if (effectiveGender(speaker) == VoiceGender.unknown) {
      assign(speaker, modalGender);
    }
  }
  return result;
}

class PiperSynthesizer implements Synthesizer {
  final Lang targetLang;
  final List<sherpa.OfflineTts> _engines = [];
  late final List<VoiceSlot> _slots;
  Map<int, int>? _speakerSlot;
  Set<int> _childSpeakers = const {};

  /// [voiceOverride]: voz fixa escolhida pelo usuário (modelId + sid) —
  /// todos os falantes usam essa única voz; a seleção automática por
  /// perfil é ignorada.
  PiperSynthesizer(this.targetLang, ModelManager models,
      {(String modelId, int sid)? voiceOverride}) {
    ensureSherpaBindings();
    final defaultVoiceId = models.catalog.defaultVoiceIds[targetLang];
    if (voiceOverride == null && defaultVoiceId == null) {
      throw StateError('${targetLang.label} não tem voz de dublagem disponível.');
    }
    final bank = voiceOverride != null
        ? [voiceOverride.$1]
        : (piperVoiceBank[targetLang] ?? [defaultVoiceId!]);
    final engineSpecs = <({int numSpeakers, List<VoiceGender> sidGenders})>[];
    for (final id in bank) {
      if (models.stateOf(id) != ModelState.ready) continue;
      final entry = models.catalog.entryOf(id)!;
      final modelPath = models.pathOf(id);
      final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: p.join(modelPath, entry.expects.first),
            tokens: p.join(modelPath, 'tokens.txt'),
            dataDir: p.join(modelPath, 'espeak-ng-data'),
          ),
          numThreads: 2,
          provider: 'cpu',
        ),
      ));
      _engines.add(tts);
      engineSpecs.add((
        numSpeakers: tts.numSpeakers,
        sidGenders: voiceSidGenders[id] ?? const [],
      ));
    }
    if (_engines.isEmpty) {
      throw StateError(
          'Nenhum modelo de voz instalado para ${targetLang.label}');
    }
    _slots = voiceOverride != null
        ? [(engine: 0, sid: voiceOverride.$2, gender: VoiceGender.unknown)]
        : buildVoiceSlots(engineSpecs);
  }

  /// Quantidade de vozes distintas disponíveis para o idioma alvo.
  int get voiceCount => _slots.length;

  @override
  void configureSpeakerVoices(Map<int, SpeakerProfile> speakerProfiles) {
    _speakerSlot = assignVoicesToSpeakers(
        speakerProfiles, [for (final s in _slots) s.gender]);
    _childSpeakers = {
      for (final e in speakerProfiles.entries)
        if (e.value.age == AgeBand.child) e.key,
    };
  }

  /// Falantes classificados como criança (recebem pitch-shift no fitter).
  bool isChildSpeaker(int speaker) => _childSpeakers.contains(speaker);

  @override
  ({Float32List samples, int sampleRate}) synthesize(String text,
      {double speed = 1.0, int speaker = 0}) {
    final slotIndex = _speakerSlot?[speaker] ?? (speaker % _slots.length);
    final slot = _slots[slotIndex % _slots.length];
    final audio =
        _engines[slot.engine].generate(text: text, sid: slot.sid, speed: speed);
    return (samples: audio.samples, sampleRate: audio.sampleRate);
  }

  @override
  void dispose() {
    for (final e in _engines) {
      e.free();
    }
    _engines.clear();
  }
}
