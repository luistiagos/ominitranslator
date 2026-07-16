import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive_io.dart';
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

  /// IDs de outras entradas do catálogo que devem estar prontas junto com
  /// esta — ex.: um `espeak-ng-data` compartilhado por várias vozes Piper,
  /// baixado/extraído uma única vez para seu próprio diretório em vez de
  /// duplicado dentro do pacote de cada voz. Vazio por padrão: não muda o
  /// comportamento de nenhuma entrada existente. Ver [ModelCatalog.resolveRequiredIds].
  final List<String> dependsOn;

  const ModelEntry({
    required this.id,
    required this.kind,
    required this.url,
    required this.sizeMb,
    required this.expects,
    required this.displayName,
    this.sha256,
    this.lang,
    this.dependsOn = const [],
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

  /// IDs reservados do §6.1 da spec Android. Todo asset é espelhado como
  /// `.tar.gz` (ou arquivo cru, pro `silero-vad`) na Release
  /// `android-models-v1` do próprio repositório (§6.1.1/D-c) — nunca aponta
  /// direto pro k2-fsa/sherpa-onnx ou pro Remote Settings da Mozilla.
  /// Gerado por `tool/mirror_models.dart`; URLs/hashes verificados contra o
  /// upstream ao vivo em 2026-07-15 (ver `docs/spikes-android/AT2.md` §6/§8
  /// e `docs/decisoes.md`) — não inferidos.
  static ModelCatalog android() => ModelCatalog(
        platform: ModelPlatform.android,
        entries: ModelManager._androidEntries,
        asrModelIds: const {
          Preset.fast: 'whisper-android-tiny',
          Preset.best: 'whisper-android-base',
        },
        defaultVoiceIds: const {
          Lang.en: 'piper-android-en',
          Lang.pt: 'piper-android-pt-br',
          Lang.es: 'piper-android-es',
        },
        // Android M1 é voice-over puro (regra do marco) — sem separação de
        // voz/música, então nenhum modelo de separação entra no catálogo.
        separatorModelId: null,
      );

  ModelEntry? entryOf(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Expande [ids] para incluir as dependências transitivas declaradas via
  /// [ModelEntry.dependsOn] (ex.: o `espeak-ng-data` compartilhado de uma
  /// voz Piper), deduplicado e sem alterar a ordem relativa dos originais.
  /// IDs sem entrada no catálogo são preservados no resultado (a checagem de
  /// prontidão de quem chama já sinaliza isso via `stateOf`), só não são
  /// expandidos. Seguro contra ciclo em `dependsOn`.
  ///
  /// Uso pretendido: `models.catalog.resolveRequiredIds([asrId, targetVoiceId])`
  /// no lugar da lista de IDs pronta, para que a checagem de prontidão e a UI
  /// de download cubram as dependências automaticamente.
  List<String> resolveRequiredIds(List<String> ids) {
    final result = <String>[];
    final seen = <String>{};
    void add(String id) {
      if (!seen.add(id)) return;
      result.add(id);
      final entry = entryOf(id);
      if (entry == null) return;
      for (final dep in entry.dependsOn) {
        add(dep);
      }
    }
    for (final id in ids) {
      add(id);
    }
    return result;
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

  static const _androidReleaseBase =
      'https://github.com/luistiagos/ominitranslator/releases/download/android-models-v1/';

  static List<ModelEntry> get _androidEntries => [
        ModelEntry(
          id: 'whisper-android-tiny',
          kind: 'targz',
          url: '${_androidReleaseBase}whisper-android-tiny.tar.gz',
          sizeMb: 61,
          expects: ['tiny-encoder.int8.onnx', 'tiny-decoder.int8.onnx', 'tiny-tokens.txt'],
          displayName: 'Reconhecimento de fala — Rápido',
          sha256: '708ba4dbd4b558855d30f22cfb7a6c087631e3217f04e76eba2136f216f4bc4d',
        ),
        ModelEntry(
          id: 'whisper-android-base',
          kind: 'targz',
          url: '${_androidReleaseBase}whisper-android-base.tar.gz',
          sizeMb: 95,
          expects: ['base-encoder.int8.onnx', 'base-decoder.int8.onnx', 'base-tokens.txt'],
          displayName: 'Reconhecimento de fala — Melhor',
          sha256: '53a8ce1416b021681231ceb47a87ab8b1d453038d0963caf8c13c99dac5fecb6',
        ),
        ModelEntry(
          id: 'silero-vad',
          kind: 'file',
          url: '${_androidReleaseBase}silero_vad.onnx',
          sizeMb: 1,
          expects: ['silero_vad.onnx'],
          displayName: 'Segmentação de fala (VAD)',
          sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
        ),
        // Empacotado sem diretório de embrulho (achado desta sessão: a
        // extração genérica achata um único wrapper, então empacotar com
        // `espeak-ng-data/` fazia os 355 arquivos caírem soltos no destDir
        // em vez de dentro de um subdiretório — quebrava `expects`). O
        // destDir desta própria entrada É o payload; `en_dict` é só o
        // marcador de completude que `stateOf` confere.
        ModelEntry(
          id: 'espeak-ng-data',
          kind: 'targz',
          url: '${_androidReleaseBase}espeak-ng-data.tar.gz',
          sizeMb: 9,
          expects: ['en_dict'],
          displayName: 'Dados de fonética (compartilhado entre vozes)',
          sha256: '2c9f8637b5ab34659d38289d4fed674c787b060221b180e1955ef992792ae2a3',
        ),
        ModelEntry(
          id: 'piper-android-en',
          kind: 'targz',
          url: '${_androidReleaseBase}piper-android-en.tar.gz',
          sizeMb: 59,
          expects: ['en_US-lessac-medium.onnx', 'tokens.txt'],
          displayName: 'Voz — Inglês',
          sha256: '4f6da04dc725adaf1d5a92fbc3f7029e96278769a10b62f777bd1edd3b54fb2d',
          lang: Lang.en,
          dependsOn: const ['espeak-ng-data'],
        ),
        ModelEntry(
          id: 'piper-android-pt-br',
          kind: 'targz',
          url: '${_androidReleaseBase}piper-android-pt-br.tar.gz',
          sizeMb: 59,
          expects: ['pt_BR-faber-medium.onnx', 'tokens.txt'],
          displayName: 'Voz — Português (BR)',
          sha256: '11d221b098ace815b6d0169032c623621ca4ab20206b8b435058a5e0075ebfa8',
          lang: Lang.pt,
          dependsOn: const ['espeak-ng-data'],
        ),
        ModelEntry(
          id: 'piper-android-es',
          kind: 'targz',
          url: '${_androidReleaseBase}piper-android-es.tar.gz',
          sizeMb: 72,
          expects: ['es_ES-sharvard-medium.onnx', 'tokens.txt'],
          displayName: 'Voz — Espanhol',
          sha256: '5eb07560a5ec03c99418c7c611e21af7586551b8289389984a471bd7bd66a029',
          lang: Lang.es,
          dependsOn: const ['espeak-ng-data'],
        ),
        // Tradução (§10) — só en<->pt e en<->es (Android M1). model+vocab; o
        // AT-1 (§6.1) achou que `lex` degenera a saída do slimt, então o
        // pacote Android não inclui os arquivos `lex.*.s2t.bin`.
        ModelEntry(
          id: 'mt-tiny-enpt',
          kind: 'targz',
          url: '${_androidReleaseBase}mt-tiny-enpt.tar.gz',
          sizeMb: 13,
          expects: ['model.enpt.intgemm.alphas.bin', 'vocab.enpt.spm'],
          displayName: 'Tradução — Inglês → Português',
          sha256: 'c66ebb6fdaf4d8eafa62adfff55fd70c57a1e4b6efb9234199c1ec15b376e008',
        ),
        ModelEntry(
          id: 'mt-tiny-pten',
          kind: 'targz',
          url: '${_androidReleaseBase}mt-tiny-pten.tar.gz',
          sizeMb: 13,
          expects: ['model.pten.intgemm.alphas.bin', 'vocab.pten.spm'],
          displayName: 'Tradução — Português → Inglês',
          sha256: '447e46a529461d2274877eac6e16a4b01739d46e15ab55bfd27c6e0bcb36d411',
        ),
        ModelEntry(
          id: 'mt-tiny-enes',
          kind: 'targz',
          url: '${_androidReleaseBase}mt-tiny-enes.tar.gz',
          sizeMb: 13,
          expects: ['model.enes.intgemm.alphas.bin', 'vocab.enes.spm'],
          displayName: 'Tradução — Inglês → Espanhol',
          sha256: '2a8d40519a9d3efd66ce0e1c37c0e6d58b4b91e9bf9c52aad82bd3bd31f69f83',
        ),
        ModelEntry(
          id: 'mt-tiny-esen',
          kind: 'targz',
          url: '${_androidReleaseBase}mt-tiny-esen.tar.gz',
          sizeMb: 13,
          expects: ['model.esen.intgemm.alphas.bin', 'vocab.esen.spm'],
          displayName: 'Tradução — Espanhol → Inglês',
          sha256: '1c14a3f7ae2e59b27ed4a7dbc161b143e729a7ee5765023dfa60afd0c50cefec',
        ),
      ];

  String pathOf(String id, [String? file]) {
    final base = p.join(modelsRoot, id);
    if (file != null) return p.join(base, file);
    return base;
  }

  ModelState stateOf(String id) {
    final entry = catalog.entryOf(id)!;
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
    final entry = catalog.entryOf(id)!;
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
      // Verifica o ARQUIVO BAIXADO (o pacote inteiro), não um extraído
      // arbitrário: é o que o hash publicado (§6.1.1 — o mesmo "digest" que
      // o GitHub Release mostra) realmente descreve, e verificar antes de
      // extrair evita gastar tempo extraindo um download corrompido. Também
      // é o único jeito correto quando `expects.first` é um diretório (ex.:
      // `espeak-ng-data`) — hashear um diretório como se fosse arquivo
      // quebra: achado ao rodar `ModelCatalog.android()` de verdade contra a
      // Release publicada.
      await _verifyAndWriteSha256(entry, destDir, archiveFile);
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
    } else if (entry.kind == 'targz') {
      // Android (D-c): sem `tar` nativo, e o BZip2Decoder do package:archive é
      // Dart puro e lento demais — daí .tar.gz aqui em vez de .tar.bz2. A
      // extração usa extractFileToDisk, que decodifica o gzip e escreve cada
      // entrada via InputFileStream/OutputFileStream (streaming) em vez de
      // materializar o pacote inteiro num único buffer em RAM. O custo é um
      // `temp.tar` intermediário (~tamanho descomprimido) em
      // Directory.systemTemp — disco transitório em vez de RAM, de propósito.
      final archiveFile = p.join(destDir, 'model.tar.gz');
      final partFile = '$archiveFile.part';
      yield* downloadWithRetry(() => _downloadWithResume(entry.url, partFile),
          maxAttempts: maxAttempts, retryDelay: retryDelay);
      File(partFile).renameSync(archiveFile);
      // Verifica o pacote baixado inteiro antes de extrair — mesmo raciocínio
      // do ramo tarbz2 acima (o hash publicado descreve o arquivo, não um
      // extraído arbitrário; e funciona quando `expects.first` é um
      // diretório, como `espeak-ng-data`).
      await _verifyAndWriteSha256(entry, destDir, archiveFile);
      final extractDir = p.join(destDir, '.extract');
      if (Directory(extractDir).existsSync()) {
        Directory(extractDir).deleteSync(recursive: true);
      }
      Directory(extractDir).createSync();
      try {
        await extractFileToDisk(archiveFile, extractDir);
        _moveContentsUp(extractDir, destDir);
      } finally {
        if (Directory(extractDir).existsSync()) {
          Directory(extractDir).deleteSync(recursive: true);
        }
      }
      File(archiveFile).deleteSync();
    } else {
      throw StateError(
          'Modelo $id tem kind desconhecido "${entry.kind}" no catálogo '
          '(esperado: file, tarbz2 ou targz).');
    }
    yield 1.0;
  }

  Future<void> _verifyAndWriteSha256(ModelEntry entry, String destDir, String file) async {
    // Isolate próprio: hashear um arquivo de ~200 MB é pesado demais para
    // rodar no isolate da UI — e por stream, não readAsBytesSync: num device
    // low-RAM o arquivo inteiro em memória anularia parte do ganho da
    // extração streaming.
    final hash = await Isolate.run(() async {
      final digest = await sha256.bind(File(file).openRead()).first;
      return digest.toString();
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
