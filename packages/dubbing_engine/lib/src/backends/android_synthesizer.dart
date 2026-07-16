import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:path/path.dart' as p;
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/backends/sherpa_bindings.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';

/// Piper (VITS via sherpa-onnx), in-process via FFI — mesmo motor do
/// desktop, mas simplificado: Android M1 é voz única (regra do marco, sem
/// diarização/múltiplas vozes), então não existe o elenco por
/// falante/perfil do `PiperSynthesizer`.
///
/// `espeak-ng-data` é uma entrada COMPARTILHADA do catálogo (`dependsOn`,
/// `ModelCatalog.android()`), não embutida dentro do pacote de cada voz como
/// no desktop — o `dataDir` aponta pro destDir da própria entrada
/// `espeak-ng-data`, não pro destDir da voz.
class AndroidSynthesizer implements Synthesizer {
  final Lang targetLang;
  late final sherpa.OfflineTts _engine;
  final int _sid;

  /// [voiceModelId]/[voiceSid]: override do catálogo (M1 só tem uma voz por
  /// idioma hoje, mas o parâmetro existe para compatibilidade com a
  /// `SynthesizerFactory` e para quando o catálogo ganhar mais vozes).
  AndroidSynthesizer(this.targetLang, ModelManager models,
      {String? voiceModelId, int voiceSid = 0})
      : _sid = voiceSid {
    ensureSherpaBindings();
    final id = voiceModelId ?? models.catalog.defaultVoiceIds[targetLang];
    if (id == null) {
      throw StateError('${targetLang.label} não tem voz de dublagem disponível.');
    }
    final entry = models.catalog.entryOf(id);
    if (entry == null) {
      throw StateError('Voz $id não existe no catálogo Android.');
    }
    if (models.stateOf(id) != ModelState.ready) {
      throw StateError('Voz $id não está pronta — baixe o modelo antes de dublar.');
    }
    final modelPath = models.pathOf(id);
    final onnxFile = entry.expects.firstWhere((f) => f.endsWith('.onnx'));
    final espeakDataDir = models.pathOf('espeak-ng-data');
    _engine = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: p.join(modelPath, onnxFile),
          tokens: p.join(modelPath, 'tokens.txt'),
          dataDir: espeakDataDir,
        ),
        numThreads: 2,
        provider: 'cpu',
      ),
    ));
  }

  // Voz única (sem diarização no Android M1): nada a configurar por perfil
  // de falante.
  @override
  void configureSpeakerVoices(Map<int, SpeakerProfile> speakerProfiles) {}

  @override
  ({Float32List samples, int sampleRate}) synthesize(String text,
      {double speed = 1.0, int speaker = 0}) {
    // speaker é ignorado: Android M1 é voz única (sem diarização), todo
    // falante sai na mesma voz.
    final audio = _engine.generate(text: text, sid: _sid, speed: speed);
    return (samples: audio.samples, sampleRate: audio.sampleRate);
  }

  @override
  void dispose() => _engine.free();
}
