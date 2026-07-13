import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/retry.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:dubbing_engine/src/translation_catalog.dart';

enum ModelState { missing, downloading, ready, corrupted }

/// Repete um download com resume ([attempt], tipicamente
/// `_downloadWithResume`) até [maxAttempts] vezes se ele lançar uma exceção
/// (erro de rede, HTTP intermitente etc.), aguardando [retryDelay] entre
/// tentativas. Cada nova tentativa reaproveita o arquivo parcial já
/// baixado (resume), então repetir é barato.
Stream<double> downloadWithRetry(
  Stream<double> Function() attempt, {
  int maxAttempts = defaultMaxAttempts,
  Duration Function(int attempt) retryDelay = defaultRetryDelay,
}) async* {
  for (int i = 1; i <= maxAttempts; i++) {
    try {
      // await for (e não yield*): erros do stream delegado por yield* vão
      // direto ao listener sem passar pelo catch desta função.
      await for (final progress in attempt()) {
        yield progress;
      }
      return;
    } catch (_) {
      if (i == maxAttempts) rethrow;
      await Future.delayed(retryDelay(i));
    }
  }
}

class ModelEntry {
  final String id;
  final String kind;
  final String url;
  final int sizeMb;
  final List<String> expects;
  final String displayName;

  /// SHA-256 esperado do primeiro arquivo em [expects]. Quando presente,
  /// o download é validado contra ele; null desativa a verificação.
  final String? sha256;

  /// Idioma da voz, para vozes piper (usado para agrupar a tela de Modelos
  /// por idioma). null para modelos que não são vozes (whisper, spleeter,
  /// diarização, gender-tagging).
  final Lang? lang;
  const ModelEntry({
    required this.id,
    required this.kind,
    required this.url,
    required this.sizeMb,
    required this.expects,
    required this.displayName,
    this.sha256,
    this.lang,
  });
}

enum ModelPlatform { windows, android }

/// Quais modelos existem numa plataforma, e quais são os escolhidos por padrão.
///
/// O mesmo ID não pode significar `.bin` no Windows e ONNX no Android, e o
/// pipeline não pode mais decidir isso com IDs hardcoded (era o que o estágio
/// `prepare` fazia). Cada plataforma monta o seu catálogo; o `ModelManager`
/// carrega um.
class ModelCatalog {
  final ModelPlatform platform;
  final List<ModelEntry> entries;

  /// Modelo de ASR por preset.
  final Map<Preset, String> asrModelIds;

  /// Voz padrão por idioma de destino.
  final Map<Lang, String> defaultVoiceIds;

  /// Separação de voz/trilha. Null quando a plataforma não separa — é assim
  /// que o Android M1 (voice-over puro) expressa a ausência, e por isso o
  /// `prepare` não exige o modelo lá.
  final String? separatorModelId;

  const ModelCatalog({
    required this.platform,
    required this.entries,
    required this.asrModelIds,
    required this.defaultVoiceIds,
    this.separatorModelId,
  });

  static ModelCatalog windows() => ModelCatalog(
        platform: ModelPlatform.windows,
        entries: ModelManager._windowsEntries,
        asrModelIds: whisperModelId,
        defaultVoiceIds: piperModelId,
        separatorModelId: spleeterModelId,
      );

  // ModelCatalog.android() entra quando o AT-2 fixar os nomes e URLs reais dos
  // assets ONNX do sherpa. A spec proíbe inferi-los (§6.1).

  ModelEntry? entryOf(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }
}

class ModelManager {
  final String modelsRoot;
  final Tools tools;
  final ModelCatalog catalog;

  ModelManager(this.modelsRoot, this.tools, {ModelCatalog? catalog})
      : catalog = catalog ?? ModelCatalog.windows();

  /// Compatibilidade: o manifest do Windows. Código novo deve usar
  /// `catalog.entries`, que é por plataforma.
  static List<ModelEntry> get manifest => ModelCatalog.windows().entries;

  static List<ModelEntry> get _windowsEntries => [
    ModelEntry(
      id: 'whisper-small-q5_1',
      kind: 'file',
      url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin',
      sizeMb: 190,
      expects: ['ggml-small-q5_1.bin'],
      displayName: 'Reconhecimento de fala — Melhor',
    ),
    ModelEntry(
      id: 'whisper-base-q5_1',
      kind: 'file',
      url: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin',
      sizeMb: 60,
      expects: ['ggml-base-q5_1.bin'],
      displayName: 'Reconhecimento de fala — Rápido',
    ),
    ModelEntry(
      id: 'spleeter-2stems-fp16',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/source-separation-models/sherpa-onnx-spleeter-2stems-fp16.tar.bz2',
      sizeMb: 40,
      expects: ['vocals.fp16.onnx', 'accompaniment.fp16.onnx'],
      displayName: 'Separação de voz e música',
    ),
    ModelEntry(
      id: 'piper-pt-br',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-faber-medium.tar.bz2',
      sizeMb: 65,
      expects: ['pt_BR-faber-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz — Português (BR)',
      lang: Lang.pt,
    ),
    ModelEntry(
      id: 'piper-es',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_ES-sharvard-medium.tar.bz2',
      sizeMb: 65,
      expects: ['es_ES-sharvard-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz — Espanhol',
      lang: Lang.es,
    ),
    ModelEntry(
      id: 'piper-en',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium.tar.bz2',
      sizeMb: 65,
      expects: ['en_US-lessac-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz — Inglês',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-pt-br-edresson',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-edresson-low.tar.bz2',
      sizeMb: 64,
      expects: ['pt_BR-edresson-low.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Português (BR)',
      lang: Lang.pt,
    ),
    ModelEntry(
      id: 'piper-en-libritts',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-libritts_r-medium.tar.bz2',
      sizeMb: 79,
      expects: ['en_US-libritts_r-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Vozes extras — Inglês (multi)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-es-davefx',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_ES-davefx-medium.tar.bz2',
      sizeMb: 65,
      expects: ['es_ES-davefx-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Espanhol',
      lang: Lang.es,
    ),
    ModelEntry(
      id: 'piper-pt-br-dii',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-dii-high.tar.bz2',
      sizeMb: 64,
      expects: ['pt_BR-dii-high.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz feminina — Português (BR)',
      lang: Lang.pt,
    ),
    ModelEntry(
      id: 'piper-en-hfc-female',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-hfc_female-medium.tar.bz2',
      sizeMb: 64,
      expects: ['en_US-hfc_female-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz feminina — Inglês',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-hfc-male',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-hfc_male-medium.tar.bz2',
      sizeMb: 64,
      expects: ['en_US-hfc_male-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz masculina — Inglês',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-pt-br-cadu',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-cadu-medium.tar.bz2',
      sizeMb: 64,
      expects: ['pt_BR-cadu-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Cadu (masculina) — Português (BR)',
      lang: Lang.pt,
    ),
    ModelEntry(
      id: 'piper-pt-br-jeff',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-jeff-medium.tar.bz2',
      sizeMb: 64,
      expects: ['pt_BR-jeff-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Jeff (masculina) — Português (BR)',
      lang: Lang.pt,
    ),
    ModelEntry(
      id: 'piper-pt-br-miro',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-miro-high.tar.bz2',
      sizeMb: 64,
      expects: ['pt_BR-miro-high.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Miro — Português (BR)',
      lang: Lang.pt,
    ),
    ModelEntry(
      id: 'piper-es-daniela',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_AR-daniela-high.tar.bz2',
      sizeMb: 110,
      expects: ['es_AR-daniela-high.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Daniela (feminina) — Espanhol (AR)',
      lang: Lang.es,
    ),
    ModelEntry(
      id: 'piper-es-claude',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_MX-claude-high.tar.bz2',
      sizeMb: 64,
      expects: ['es_MX-claude-high.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Claude — Espanhol (MX)',
      lang: Lang.es,
    ),
    ModelEntry(
      id: 'piper-es-ald',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_MX-ald-medium.tar.bz2',
      sizeMb: 64,
      expects: ['es_MX-ald-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Ald — Espanhol (MX)',
      lang: Lang.es,
    ),
    ModelEntry(
      id: 'piper-en-amy',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-amy-medium.tar.bz2',
      sizeMb: 64,
      expects: ['en_US-amy-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Amy (feminina) — Inglês',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-ryan',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-ryan-medium.tar.bz2',
      sizeMb: 64,
      expects: ['en_US-ryan-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Ryan (masculina) — Inglês',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-kristin',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-kristin-medium.tar.bz2',
      sizeMb: 64,
      expects: ['en_US-kristin-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Kristin (feminina) — Inglês',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-joe',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-joe-medium.tar.bz2',
      sizeMb: 64,
      expects: ['en_US-joe-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz Joe (masculina) — Inglês',
      lang: Lang.en,
    ),

    // ── Vozes novas (línguas-alvo adicionais: de/fr/pl/cs; e mais vozes
    // para en/es/pt) — geradas por tool/gen_voice_manifest.dart a partir do
    // catálogo rhasspy/piper-voices, com cada URL validada via HEAD contra
    // o release tts-models do sherpa-onnx. Búlgaro (bg) não tem nenhuma voz
    // piper mirrorada nesse release (confirmado por HEAD 404 + ausência na
    // documentação oficial) — por isso bg permanece só-origem, sem entrada
    // de voz aqui e com isDubTarget:false em models.dart.
    ModelEntry(
      id: 'piper-de-thorsten',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-thorsten-medium.tar.bz2',
      sizeMb: 68,
      expects: ['de_DE-thorsten-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz — Alemão (Thorsten)',
      lang: Lang.de,
    ),
    ModelEntry(
      id: 'piper-de-thorsten-emotional',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-thorsten_emotional-medium.tar.bz2',
      sizeMb: 81,
      expects: ['de_DE-thorsten_emotional-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Alemão (Thorsten, variações emocionais)',
      lang: Lang.de,
    ),
    ModelEntry(
      id: 'piper-de-eva-k',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-eva_k-x_low.tar.bz2',
      sizeMb: 27,
      expects: ['de_DE-eva_k-x_low.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Alemão (Eva K, feminina)',
      lang: Lang.de,
    ),
    ModelEntry(
      id: 'piper-de-karlsson',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-karlsson-low.tar.bz2',
      sizeMb: 68,
      expects: ['de_DE-karlsson-low.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Alemão (Karlsson, masculina)',
      lang: Lang.de,
    ),
    ModelEntry(
      id: 'piper-de-kerstin',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-kerstin-low.tar.bz2',
      sizeMb: 68,
      expects: ['de_DE-kerstin-low.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Alemão (Kerstin, feminina)',
      lang: Lang.de,
    ),
    ModelEntry(
      id: 'piper-de-pavoque',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-pavoque-low.tar.bz2',
      sizeMb: 68,
      expects: ['de_DE-pavoque-low.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Alemão (Pavoque, masculina)',
      lang: Lang.de,
    ),
    ModelEntry(
      id: 'piper-de-ramona',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-de_DE-ramona-low.tar.bz2',
      sizeMb: 68,
      expects: ['de_DE-ramona-low.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Alemão (Ramona, feminina)',
      lang: Lang.de,
    ),
    ModelEntry(
      id: 'piper-fr-siwis',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-fr_FR-siwis-medium.tar.bz2',
      sizeMb: 68,
      expects: ['fr_FR-siwis-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz — Francês (Siwis, feminina)',
      lang: Lang.fr,
    ),
    ModelEntry(
      id: 'piper-fr-gilles',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-fr_FR-gilles-low.tar.bz2',
      sizeMb: 68,
      expects: ['fr_FR-gilles-low.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Francês (Gilles, masculina)',
      lang: Lang.fr,
    ),
    ModelEntry(
      id: 'piper-fr-tom',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-fr_FR-tom-medium.tar.bz2',
      sizeMb: 68,
      expects: ['fr_FR-tom-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Francês (Tom, masculina)',
      lang: Lang.fr,
    ),
    ModelEntry(
      id: 'piper-fr-upmc',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-fr_FR-upmc-medium.tar.bz2',
      sizeMb: 81,
      expects: ['fr_FR-upmc-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Vozes extras — Francês (UPMC, multi)',
      lang: Lang.fr,
    ),
    ModelEntry(
      id: 'piper-pl-gosia',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pl_PL-gosia-medium.tar.bz2',
      sizeMb: 68,
      expects: ['pl_PL-gosia-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz — Polonês (Gosia, feminina)',
      lang: Lang.pl,
    ),
    ModelEntry(
      id: 'piper-pl-bass',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pl_PL-bass-high.tar.bz2',
      sizeMb: 116,
      expects: ['pl_PL-bass-high.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Polonês (Bass, masculina)',
      lang: Lang.pl,
    ),
    ModelEntry(
      id: 'piper-pl-darkman',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pl_PL-darkman-medium.tar.bz2',
      sizeMb: 68,
      expects: ['pl_PL-darkman-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Polonês (Darkman, masculina)',
      lang: Lang.pl,
    ),
    ModelEntry(
      id: 'piper-pl-mc-speech',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pl_PL-mc_speech-medium.tar.bz2',
      sizeMb: 68,
      expects: ['pl_PL-mc_speech-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Polonês (MC Speech)',
      lang: Lang.pl,
    ),
    ModelEntry(
      id: 'piper-cs-jirka',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-cs_CZ-jirka-medium.tar.bz2',
      sizeMb: 68,
      expects: ['cs_CZ-jirka-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz — Tcheco (Jirka, masculina)',
      lang: Lang.cs,
    ),
    ModelEntry(
      id: 'piper-pt-pt-tugao',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_PT-tugao-medium.tar.bz2',
      sizeMb: 68,
      expects: ['pt_PT-tugao-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Português (PT) (Tugão)',
      lang: Lang.pt,
    ),
    ModelEntry(
      id: 'piper-es-carlfm',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_ES-carlfm-x_low.tar.bz2',
      sizeMb: 27,
      expects: ['es_ES-carlfm-x_low.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Espanhol (CarlFM, masculina)',
      lang: Lang.es,
    ),
    ModelEntry(
      id: 'piper-en-bryce',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-bryce-medium.tar.bz2',
      sizeMb: 68,
      expects: ['en_US-bryce-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (Bryce, masculina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-danny',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-danny-low.tar.bz2',
      sizeMb: 68,
      expects: ['en_US-danny-low.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (Danny, masculina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-john',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-john-medium.tar.bz2',
      sizeMb: 68,
      expects: ['en_US-john-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (John, masculina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-kathleen',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-kathleen-low.tar.bz2',
      sizeMb: 68,
      expects: ['en_US-kathleen-low.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (Kathleen, feminina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-kusal',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-kusal-medium.tar.bz2',
      sizeMb: 68,
      expects: ['en_US-kusal-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (Kusal, masculina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-ljspeech',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-ljspeech-medium.tar.bz2',
      sizeMb: 68,
      expects: ['en_US-ljspeech-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (LJSpeech, feminina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-norman',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-norman-medium.tar.bz2',
      sizeMb: 68,
      expects: ['en_US-norman-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (Norman, masculina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-reza-ibrahim',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-reza_ibrahim-medium.tar.bz2',
      sizeMb: 68,
      expects: ['en_US-reza_ibrahim-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (Reza Ibrahim, masculina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-sam',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-sam-medium.tar.bz2',
      sizeMb: 68,
      expects: ['en_US-sam-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (Sam)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-arctic',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-arctic-medium.tar.bz2',
      sizeMb: 81,
      expects: ['en_US-arctic-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Vozes extras — Inglês (ARCTIC, multi)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-l2arctic',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-l2arctic-medium.tar.bz2',
      sizeMb: 81,
      expects: ['en_US-l2arctic-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Vozes extras — Inglês (L2-ARCTIC, multi, sotaques)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-libritts-high',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-libritts-high.tar.bz2',
      sizeMb: 132,
      expects: ['en_US-libritts-high.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Vozes extras — Inglês (LibriTTS high, multi)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-gb-alan',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_GB-alan-medium.tar.bz2',
      sizeMb: 68,
      expects: ['en_GB-alan-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz — Inglês (GB, Alan, masculina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-gb-alba',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_GB-alba-medium.tar.bz2',
      sizeMb: 68,
      expects: ['en_GB-alba-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (GB, Alba, feminina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-gb-cori',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_GB-cori-medium.tar.bz2',
      sizeMb: 68,
      expects: ['en_GB-cori-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (GB, Cori, feminina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-gb-jenny-dioco',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_GB-jenny_dioco-medium.tar.bz2',
      sizeMb: 68,
      expects: ['en_GB-jenny_dioco-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (GB, Jenny, feminina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-gb-northern-male',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_GB-northern_english_male-medium.tar.bz2',
      sizeMb: 68,
      expects: ['en_GB-northern_english_male-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (GB, sotaque norte, masculina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-gb-southern-female',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_GB-southern_english_female-low.tar.bz2',
      sizeMb: 68,
      expects: ['en_GB-southern_english_female-low.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Voz extra — Inglês (GB, sotaque sul, feminina)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-gb-aru',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_GB-aru-medium.tar.bz2',
      sizeMb: 81,
      expects: ['en_GB-aru-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Vozes extras — Inglês (GB, ARU, multi)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-gb-semaine',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_GB-semaine-medium.tar.bz2',
      sizeMb: 81,
      expects: ['en_GB-semaine-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Vozes extras — Inglês (GB, SEMAINE, multi)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'piper-en-gb-vctk',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_GB-vctk-medium.tar.bz2',
      sizeMb: 81,
      expects: ['en_GB-vctk-medium.onnx', 'tokens.txt', 'espeak-ng-data'],
      displayName: 'Vozes extras — Inglês (GB, VCTK, multi)',
      lang: Lang.en,
    ),
    ModelEntry(
      id: 'gender-tagging',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/audio-tagging-models/sherpa-onnx-ced-tiny-audio-tagging-2024-04-19.tar.bz2',
      sizeMb: 27,
      expects: ['model.int8.onnx', 'class_labels_indices.csv'],
      displayName: 'Detecção de sexo/idade por voz',
    ),
    ModelEntry(
      id: 'diarization-segmentation',
      kind: 'tarbz2',
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2',
      sizeMb: 7,
      expects: ['model.onnx'],
      displayName: 'Detecção de falantes — segmentação',
    ),
    ModelEntry(
      id: 'diarization-embedding',
      kind: 'file',
      // O tag "speaker-recongition-models" tem esse typo no repositório real.
      url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx',
      sizeMb: 39,
      expects: ['nemo_en_titanet_small.onnx'],
      displayName: 'Detecção de falantes — vozes',
    ),
  ];

  String pathOf(String id, [String? file]) {
    final base = p.join(modelsRoot, id);
    if (file != null) return p.join(base, file);
    return base;
  }

  ModelState stateOf(String id) {
    final entry = manifest.firstWhere((e) => e.id == id);
    final base = pathOf(id);
    if (!Directory(base).existsSync()) return ModelState.missing;
    bool complete = true;
    for (final expected in entry.expects) {
      final f = p.join(base, expected);
      if (!File(f).existsSync() && !Directory(f).existsSync()) {
        complete = false;
        break;
      }
    }
    if (!complete) {
      // Um .part indica download interrompido (retomável), não corrupção.
      final hasPart = Directory(base)
          .listSync()
          .whereType<File>()
          .any((f) => f.path.endsWith('.part'));
      return hasPart ? ModelState.downloading : ModelState.corrupted;
    }
    final shaFile = p.join(base, '.sha256');
    if (!File(shaFile).existsSync()) return ModelState.corrupted;
    return ModelState.ready;
  }

  /// [maxAttempts]/[retryDelay] controlam o retry automático do download
  /// HTTP (erros de rede, HTTP intermitente) — cada nova tentativa retoma
  /// de onde o arquivo parcial parou, então é barato repetir.
  Stream<double> download(
    String id, {
    int maxAttempts = defaultMaxAttempts,
    Duration Function(int attempt) retryDelay = defaultRetryDelay,
  }) async* {
    final entry = manifest.firstWhere((e) => e.id == id);
    final destDir = pathOf(id);
    Directory(destDir).createSync(recursive: true);

    if (entry.kind == 'file') {
      final destFile = p.join(destDir, entry.expects.first);
      final partFile = '$destFile.part';
      yield* downloadWithRetry(() => _downloadWithResume(entry.url, partFile),
          maxAttempts: maxAttempts, retryDelay: retryDelay);
      File(partFile).renameSync(destFile);
      await _verifyAndWriteSha256(entry, destDir, destFile);
    } else if (entry.kind == 'tarbz2') {
      final archiveFile = p.join(destDir, 'model.tar.bz2');
      final partFile = '$archiveFile.part';
      yield* downloadWithRetry(() => _downloadWithResume(entry.url, partFile),
          maxAttempts: maxAttempts, retryDelay: retryDelay);
      File(partFile).renameSync(archiveFile);
      // Extrai num subdiretório do próprio destino: mesmo volume (rename
      // não cruza volumes) e sem colisão com sobras de outros modelos.
      final extractDir = p.join(destDir, '.extract');
      if (Directory(extractDir).existsSync()) {
        Directory(extractDir).deleteSync(recursive: true);
      }
      Directory(extractDir).createSync();
      try {
        final result = await runTool('tar', [
          '-xjf', archiveFile,
          '-C', extractDir,
        ], timeout: toolTimeout);
        if (result.exitCode != 0) {
          throw StateError('Extraction failed for $id: ${result.stderrTail}');
        }
        _moveContentsUp(extractDir, destDir);
        await _verifyAndWriteSha256(entry, destDir, p.join(destDir, entry.expects.first));
      } on ProcessException {
        throw StateError(
            'Não foi possível executar "tar" para extrair o modelo $id. '
            'O tar.exe vem com o Windows 10+; verifique se está no PATH.');
      } finally {
        if (Directory(extractDir).existsSync()) {
          Directory(extractDir).deleteSync(recursive: true);
        }
      }
      File(archiveFile).deleteSync();
    }
    yield 1.0;
  }

  Future<void> _verifyAndWriteSha256(ModelEntry entry, String destDir, String file) async {
    // Isolate próprio: hashear um arquivo de ~200 MB é pesado demais para
    // rodar no isolate da UI.
    final hash = await Isolate.run(() {
      final bytes = File(file).readAsBytesSync();
      return sha256.convert(bytes).toString();
    });
    if (entry.sha256 != null && hash != entry.sha256) {
      File(file).deleteSync();
      throw StateError(
          'Modelo ${entry.id} baixado com hash inesperado ($hash). '
          'O download pode estar corrompido; tente novamente.');
    }
    File(p.join(destDir, '.sha256')).writeAsStringSync(hash);
  }

  /// Baixa [url] para [partFile], retomando de onde parou se o arquivo já
  /// existe. Emite o progresso (0..1) quando o tamanho total é conhecido.
  Stream<double> _downloadWithResume(String url, String partFile) async* {
    int startByte = 0;
    if (File(partFile).existsSync()) {
      startByte = File(partFile).lengthSync();
    }
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      if (startByte > 0) {
        request.headers['Range'] = 'bytes=$startByte-';
      }
      final response = await client.send(request);
      var mode = FileMode.append;
      if (startByte > 0 && response.statusCode == 200) {
        // Servidor não suporta Range: recomeça do zero em vez de appendar.
        startByte = 0;
        mode = FileMode.write;
      } else if (startByte > 0 && response.statusCode == 416) {
        // Range além do fim: o .part pode estar completo ou corrompido;
        // apaga e recomeça para garantir consistência.
        File(partFile).deleteSync();
        yield* _downloadWithResume(url, partFile);
        return;
      } else if (response.statusCode != 200 && response.statusCode != 206) {
        throw StateError('Download falhou com HTTP ${response.statusCode} para $url');
      }
      final contentLength = response.contentLength;
      final total = contentLength != null ? contentLength + startByte : null;
      final sink = File(partFile).openWrite(mode: mode);
      try {
        int received = startByte;
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total != null && total > 0) {
            yield (received / total).clamp(0.0, 1.0);
          }
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }
  }

  void _moveContentsUp(String srcDir, String destDir) {
    final entries = Directory(srcDir).listSync();
    if (entries.length == 1 && entries.first is Directory) {
      final subDir = entries.first as Directory;
      for (final entry in subDir.listSync()) {
        final dest = p.join(destDir, p.basename(entry.path));
        if (entry is File) {
          File(entry.path).renameSync(dest);
        } else if (entry is Directory) {
          Directory(entry.path).renameSync(dest);
        }
      }
    } else {
      for (final entry in entries) {
        final dest = p.join(destDir, p.basename(entry.path));
        if (entry is File) {
          File(entry.path).renameSync(dest);
        } else if (entry is Directory) {
          Directory(entry.path).renameSync(dest);
        }
      }
    }
  }

  Future<void> delete(String id) async {
    final dir = Directory(pathOf(id));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  Future<void> ensureTranslationModels(Lang from, Lang to, CancellationToken token, {RunToolFn? runToolOverride}) async {
    // Rede: o download dos modelos de tradução merece retry.
    final exec = runToolOverride ?? runToolWithRetry;
    // Ids únicos: alguns pares compartilham modelo (ex.: hr-en/sr-en/bs-en
    // são todos 'hbs-eng-tiny') — baixar uma vez basta.
    final ids = <String>{
      for (final (f, t) in translationPath(from, to)) directTranslationModelId(f, t)!,
    };
    for (final id in ids) {
      final r = await exec(tools.translateLocally, ['-d', id],
          token: token, timeout: toolTimeout);
      if (r.exitCode != 0) {
        throw PipelineException(PipelineStage.translate,
            'Falha ao baixar o modelo de tradução $id (código ${r.exitCode}). '
            'Verifique a conexão com a internet.');
      }
    }
  }
}
