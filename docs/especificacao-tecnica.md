# OmniTranslator — Especificação Técnica v1

Este documento especifica a implementação do OmniTranslator em nível executável: comandos literais, URLs exatas, assinaturas de código, algoritmos com constantes definidas e critérios de aceite mecânicos. Ele cobre em **micro-detalhe** a Fase 0 (spikes) e a Fase 1 (MVP desktop Windows — dublagem de arquivo de vídeo), e a Fase 2 (tempo real) em detalhe médio. O Android possui especificação normativa própria em [especificacao-android.md](especificacao-android.md).

Documento-pai: [plano-de-desenvolvimento.md](plano-de-desenvolvimento.md).

## 1. Objetivo e regras para o implementador

O OmniTranslator dubla vídeos de um idioma para outro **100% localmente** (sem nuvem). Idiomas suportados no MVP: inglês (`en`), português (`pt`) e espanhol (`es`), nas 6 direções. O MVP é um app Flutter para Windows que recebe um arquivo de vídeo, e produz: (a) um vídeo com a faixa de áudio dublada (mantendo a original como faixa secundária) e (b) legendas SRT no idioma original e no traduzido.

> **Nota (pós-MVP):** o suporte a idiomas foi expandido para 23 línguas (7 idiomas-alvo de dublagem: en/pt/es/de/fr/pl/cs; as demais só como origem). O `enum Lang` (§5) deixou de ser um enum simples e virou um *enhanced enum* com metadados (`code`, `label`, `iso639_2`, `isDubTarget`, `whisperCode`); os pares de tradução passaram a ser uma tabela declarativa em `packages/dubbing_engine/lib/src/translation_catalog.dart` (com pivô generalizado via inglês); e o manifest de vozes em `model_manager.dart` cresceu para 64 entradas. Os trechos de código abaixo (§5, §P6, §10) permanecem como registro histórico do que foi implementado no MVP — para o estado atual, use esses arquivos-fonte como referência, não este documento.

**Regras de ouro — leia antes de escrever qualquer código:**

1. **Não troque ferramentas, modelos ou URLs pinados nesta spec.** Eles foram verificados. Se algo estiver fora do ar, pare e registre o problema em `docs/decisoes.md`; não substitua por outra coisa por conta própria.
2. **Se a spec não define algo, escolha a opção mais simples** e registre a decisão (1 linha) em `docs/decisoes.md`.
3. **Nunca use FFI customizado nem compile C/C++.** Todo componente pesado do desktop é subprocesso CLI ou o pacote Dart `sherpa_onnx` (binário pré-compilado via pub.dev).
4. **Nunca trunque fala dublada** para caber no tempo. A ordem de recursos é: acelerar via TTS → acelerar via `atempo` → aceitar estouro com warning (ver P7).
   **Exceção única (2026-07-12, decisão D-b):** a cauda que ultrapassa o **fim do vídeo** não tem para onde ir — o `amix=duration=first` do P8 amarra a saída à duração do áudio original. Ali o pipeline (a) aperta o último run até o teto `tailSpeedMax` para fazer a fala caber, e (b) corta o que ainda sobrar, **medindo e reportando** (`truncatedTailMs` no `sync_report.json`). Corte acima de `tailTruncationCapMs` é falha de qualidade, não sucesso. Em nenhum outro ponto do pipeline se trunca fala.
5. Todo passo do pipeline valida sua saída (arquivo existe e não está vazio, contagem de linhas bate etc.) e falha com `PipelineException` descritiva — nunca prossiga com dado inválido.
6. Texto de UI em pt-BR; identificadores de código, comentários e commits em inglês.

## 2. Glossário

| Termo | Definição |
|---|---|
| **Segmento** | Trecho contíguo de fala com `start`/`end` no tempo do vídeo e um texto. |
| **Janela** | Intervalo `[start, end]` do segmento original, onde a fala dublada deve caber. |
| **Folga** | Silêncio entre o fim de um segmento e o início do próximo; pode ser parcialmente invadida pela dublagem. |
| **Pivô** | Tradução em dois saltos usando inglês no meio (pt→en→es), porque os modelos Marian tiny são pareados com inglês. |
| **Stem** | Faixa isolada pela separação de fontes: `vocals` (voz) e `accompaniment` (música/efeitos). |
| **Ducking** | Abaixar automaticamente o volume do áudio original enquanto a voz dublada fala (modo fallback sem separação). |
| **Voice-over mode** | Modo degradado onde a separação de fontes falhou: dublagem é mixada por cima do áudio original com ducking (estilo "lektor"). |
| **Preset** | Conjunto de modelos: `fast` (whisper base) ou `best` (whisper small). |

## 3. Layout do repositório

```
omnitranslator/
├── app/                              # App Flutter (flutter create --platforms=windows app)
│   ├── lib/
│   │   ├── main.dart
│   │   └── src/
│   │       ├── state/app_state.dart          # ChangeNotifier global
│   │       ├── screens/home_screen.dart
│   │       ├── screens/progress_screen.dart
│   │       └── screens/models_screen.dart
│   └── pubspec.yaml
├── packages/
│   └── dubbing_engine/               # Pacote Dart puro (sem Flutter) — todo o pipeline
│       ├── lib/
│       │   ├── dubbing_engine.dart   # exports públicos
│       │   └── src/
│       │       ├── models.dart               # contratos de dados (seção 5)
│       │       ├── constants.dart            # constantes do pipeline (apêndice E)
│       │       ├── pipeline.dart             # orquestração (seção 9)
│       │       ├── model_manager.dart        # download/validação de modelos (seção 7)
│       │       ├── wav.dart                  # leitura/escrita WAV (seção 6.3)
│       │       ├── tools/
│       │       │   ├── tool_locator.dart     # resolve caminhos de tools/win (seção 6.2)
│       │       │   └── process_runner.dart   # wrapper de subprocesso (seção 6.1)
│       │       ├── backends/
│       │       │   ├── interfaces.dart       # Separator, Transcriber, Translator, Synthesizer
│       │       │   ├── sherpa_separator.dart # CLI sherpa-onnx (P2)
│       │       │   ├── whisper_transcriber.dart      # CLI whisper-cli (P3)
│       │       │   ├── translatelocally_translator.dart # CLI translateLocally (P5)
│       │       │   └── piper_synthesizer.dart        # pacote sherpa_onnx (P6)
│       │       └── steps/
│       │           ├── demux.dart            # P1
│       │           ├── segmenter.dart        # P4
│       │           ├── fitter.dart           # P7
│       │           ├── mixer.dart            # P8
│       │           ├── muxer.dart            # P9
│       │           └── subtitles.dart        # SRT
│       ├── test/                     # testes unitários (seção 12)
│       ├── tool/integration_test.dart# teste de integração (seção 12.2)
│       └── pubspec.yaml
├── tools/
│   └── win/                          # binários externos (NÃO commitar; ver setup 4.2)
│       ├── ffmpeg.exe
│       ├── ffprobe.exe
│       ├── whisper-cli.exe           # + DLLs que vierem no zip
│       ├── translateLocally/         # pasta inteira extraída do zip (exe + DLLs Qt)
│       └── sherpa/                   # sherpa-onnx-offline-source-separation.exe + DLLs
├── docs/
│   ├── plano-de-desenvolvimento.md
│   ├── especificacao-tecnica.md      # este documento
│   ├── decisoes.md                   # log de decisões do implementador
│   └── spikes/                       # relatórios S1..S5 (seção 11)
└── .gitignore                        # ignora tools/win/**, *.wav, workdirs
```

Interfaces em `backends/interfaces.dart` — o pipeline SÓ conhece estas interfaces (a Fase 3 trocará as implementações CLI por FFI sem tocar no pipeline):

```dart
abstract class Separator {
  /// Returns null if separation is unavailable (caller enters voice-over mode).
  Future<({String vocalsWav, String accompanimentWav})?> separate(
      String inputWav, String workDir, CancellationToken token);
}

abstract class Transcriber {
  Future<List<TranscriptSegment>> transcribe(
      String wav16kMono, Lang sourceLang, CancellationToken token);
}

abstract class Translator {
  /// Translates line i of [sentences] to line i of the result. Same length guaranteed.
  Future<List<String>> translate(
      List<String> sentences, Lang from, Lang to, CancellationToken token);
}

abstract class Synthesizer {
  /// Returns mono float32 samples and their sample rate.
  ({Float32List samples, int sampleRate}) synthesize(String text, {double speed = 1.0});
  void dispose();
}
```

## 4. Setup do ambiente

### 4.1 Pré-requisitos

- Windows 10/11 x64, ~10 GB livres em disco, 8 GB de RAM.
- Flutter SDK stable (canal `stable`, ≥ 3.24) com suporte desktop Windows habilitado: `flutter config --enable-windows-desktop`. Verificar com `flutter doctor`.
- Git.

### 4.2 Download dos binários externos (uma vez, manual — PowerShell)

Executar na raiz do repositório. Estes binários NÃO são commitados (`.gitignore` cobre `tools/win/**`).

```powershell
New-Item -ItemType Directory -Force tools\win, tools\win\sherpa, tools\win\translateLocally

# 1) FFmpeg (build LGPL da BtbN)
curl.exe -L -o ffmpeg.zip https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-lgpl.zip
tar -xf ffmpeg.zip
Copy-Item ffmpeg-master-latest-win64-lgpl\bin\ffmpeg.exe,ffmpeg-master-latest-win64-lgpl\bin\ffprobe.exe tools\win\

# 2) whisper.cpp (binário oficial Windows x64)
curl.exe -L -o whisper.zip https://github.com/ggml-org/whisper.cpp/releases/latest/download/whisper-bin-x64.zip
Expand-Archive whisper.zip -DestinationPath whisper-bin
Copy-Item whisper-bin\* tools\win\    # whisper-cli.exe + DLLs (copiar tudo)

# 3) translateLocally (zip Windows da página de releases)
#    Baixar manualmente de https://github.com/XapaJIaMnu/translateLocally/releases
#    (ou https://translatelocally.com) e extrair a PASTA INTEIRA em tools\win\translateLocally\
#    O exe precisa das DLLs Qt que vêm junto — não copiar só o .exe.

# 4) sherpa-onnx (separação de fontes) — baixar da página de releases
#    https://github.com/k2-fsa/sherpa-onnx/releases o asset da versão mais recente
#    com nome no padrão: sherpa-onnx-v<versão>-win-x64-shared.tar.bz2
tar -xjf sherpa-onnx-v*-win-x64-shared.tar.bz2
#    Copiar bin\sherpa-onnx-offline-source-separation.exe e TODAS as .dll de bin\ para tools\win\sherpa\
```

Validação do setup (todos devem imprimir versão/uso e sair com código 0 ou 1, nunca "não encontrado"):

```powershell
tools\win\ffmpeg.exe -version
tools\win\whisper-cli.exe --help
tools\win\translateLocally\translateLocally.exe --help
tools\win\sherpa\sherpa-onnx-offline-source-separation.exe --help
```

Se o nome de um asset de release mudar, procurar na mesma página o asset equivalente para Windows x64 — mas registrar em `docs/decisoes.md`.

### 4.3 Criação dos projetos Dart/Flutter

```powershell
flutter create --platforms=windows --project-name omnitranslator_app app
dart create -t package packages/dubbing_engine
```

`packages/dubbing_engine/pubspec.yaml` — dependências:

```yaml
environment:
  sdk: ^3.4.0
dependencies:
  sherpa_onnx: ^1.12.0   # usar a versão estável mais recente do pub.dev
  path: ^1.9.0
  http: ^1.2.0
  crypto: ^3.0.0
dev_dependencies:
  test: ^1.25.0
  lints: ^4.0.0
```

`app/pubspec.yaml` — adicionar às dependências geradas:

```yaml
dependencies:
  dubbing_engine:
    path: ../packages/dubbing_engine
  provider: ^6.1.0
  file_picker: ^8.0.0
```

## 5. Contratos de dados (`packages/dubbing_engine/lib/src/models.dart`)

Transcrever exatamente estas classes (com `==`/`toString` onde útil; sem pacotes de codegen):

```dart
enum Lang { en, pt, es }

extension LangCodes on Lang {
  /// whisper-cli -l code
  String get whisperCode => name;                       // en, pt, es
  /// ISO 639-2 for ffmpeg track metadata
  String get iso639_2 => switch (this) { Lang.en => 'eng', Lang.pt => 'por', Lang.es => 'spa' };
}

enum Preset { fast, best }

/// One transcription unit as produced by whisper (P3) or by the segmenter (P4).
class TranscriptSegment {
  final Duration start;
  final Duration end;
  final String text;
  TranscriptSegment(this.start, this.end, this.text);
}

/// Full state of one dubbing unit as it flows through P4..P8.
class DubbingSegment {
  final int id;                 // sequential from 0
  final Duration start;
  final Duration end;
  final String sourceText;
  String translatedText = '';
  Float32List? fittedAudio;     // mono, 44100 Hz, after P7
  double speedUsed = 1.0;       // VITS speed applied
  double atempoUsed = 1.0;      // ffmpeg atempo applied
  Duration overflow = Duration.zero; // how far past the allowed window it ends
  DubbingSegment(this.id, this.start, this.end, this.sourceText);
}

class DubbingJobConfig {
  final String inputVideo;      // absolute path
  final Lang sourceLang;
  final Lang targetLang;        // must differ from sourceLang
  final Preset preset;
  final bool keepOriginalTrack; // default true
  final bool generateSrt;       // default true
  final String workDir;         // %TEMP%/omnitranslator/<jobId>
  final String outputPath;      // default: <input dir>/<input name>_dub_<targetLang>.mp4
  const DubbingJobConfig({...}); // all fields required except defaults noted
}

enum PipelineStage { demux, separate, transcribe, segment, translate, synthesize, fit, mix, mux }

class PipelineEvent {
  final PipelineStage stage;
  final double progress;        // 0.0..1.0 within the stage
  final String message;         // human-readable, pt-BR
  const PipelineEvent(this.stage, this.progress, this.message);
}

class PipelineException implements Exception {
  final PipelineStage stage;
  final String message;
  final Object? cause;
  PipelineException(this.stage, this.message, [this.cause]);
}

class CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Result of a finished job.
class DubbingResult {
  final String outputVideo;
  final String? srtSource;      // path or null if generateSrt=false
  final String? srtTarget;
  final bool voiceOverMode;     // true if separation fell back to ducking
  final int segmentsWithOverflow;
  final Duration elapsed;
  const DubbingResult({...});
}
```

## 6. Infraestrutura comum

### 6.1 `tools/process_runner.dart`

```dart
class ToolResult {
  final int exitCode;
  final String stdout;
  final String stderrTail; // last 50 lines
}

/// Runs an external tool. Throws ProcessCancelledException if token fires
/// (the process is killed with Process.kill()). Never throws on non-zero
/// exit — caller decides. [timeout] default: 30 minutes.
Future<ToolResult> runTool(
  String exePath,
  List<String> args, {
  String? workingDirectory,
  Duration timeout = const Duration(minutes: 30),
  CancellationToken? token,
});
```

Comportamento obrigatório: iniciar com `Process.start`; drenar stdout/stderr continuamente (evita deadlock de buffer cheio); a cada 200 ms verificar `token.isCancelled` e, se cancelado, `process.kill()` e lançar; no timeout, matar e retornar exit code -1 com `stderrTail` explicando. Logar (print ou logger simples) a linha de comando completa antes de executar.

### 6.2 `tools/tool_locator.dart`

Resolve os caminhos dos executáveis. Ordem de busca: (1) variável de ambiente `OMNITRANSLATOR_TOOLS_DIR`; (2) `<raiz do repo>/tools/win/` — localizada subindo diretórios a partir de `Platform.script`/`Directory.current` até achar uma pasta contendo `tools/win/ffmpeg.exe`. Expor:

```dart
class Tools {
  final String ffmpeg, ffprobe, whisperCli, translateLocally, sherpaSourceSeparation;
  static Tools locate(); // throws StateError listing what is missing
}
```

### 6.3 `wav.dart`

Sem dependências externas; só WAV canônico com header de 44 bytes.

```dart
class WavData {
  final Float32List samples;   // interleaved if channels==2
  final int sampleRate;
  final int channels;
  Duration get duration;
}
WavData readWav(String path);            // supports PCM16 (format=1) and float32 (format=3)
void writeWavPcm16(String path, WavData data); // clamps [-1,1], scales to int16
Float32List upsample2x(Float32List mono);      // linear interp: out[2i]=in[i]; out[2i+1]=avg(in[i],in[i+1])
Float32List stereoToMono(Float32List interleaved);
```

Header WAV (little-endian): bytes 0–3 `RIFF`; 4–7 uint32 = 36 + tamanho dos dados; 8–11 `WAVE`; 12–15 `fmt `; 16–19 uint32 = 16; 20–21 uint16 formato (1=PCM16, 3=float32); 22–23 uint16 canais; 24–27 uint32 sample rate; 28–31 uint32 byte rate (= rate × canais × bytesPorAmostra); 32–33 uint16 block align (= canais × bytesPorAmostra); 34–35 uint16 bits por amostra (16 ou 32); 36–39 `data`; 40–43 uint32 tamanho dos dados; depois os dados. Ao LER, aceitar chunks extras entre `fmt ` e `data` (pular chunks desconhecidos lendo o nome de 4 bytes + uint32 de tamanho — o ffmpeg às vezes insere `LIST`).

`upsample2x` é usado para converter a saída do Piper (22050 Hz) para 44100 Hz (fator exato 2×). Se o sample rate do TTS não for 22050, usar fallback: gravar WAV temporário e converter com `ffmpeg -i in.wav -ar 44100 out.wav`.

## 7. Gerenciador de modelos (`model_manager.dart`)

Diretório de modelos: `%APPDATA%\omnitranslator\models\<id>\` (obter via `Platform.environment['APPDATA']`).

Manifest hardcoded (apêndice C tem o JSON completo). Entradas:

| id | Tipo | URL | Tamanho aprox. | Arquivo(s) esperado(s) após instalação |
|---|---|---|---|---|
| `whisper-small-q5_1` | arquivo único | `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin` | 190 MB | `ggml-small-q5_1.bin` |
| `whisper-base-q5_1` | arquivo único | `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin` | 60 MB | `ggml-base-q5_1.bin` |
| `spleeter-2stems-fp16` | tar.bz2 | `https://github.com/k2-fsa/sherpa-onnx/releases/download/source-separation-models/sherpa-onnx-spleeter-2stems-fp16.tar.bz2` | 40 MB | `vocals.fp16.onnx`, `accompaniment.fp16.onnx` |
| `piper-pt-br` | tar.bz2 | `https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-faber-medium.tar.bz2` | 65 MB | `pt_BR-faber-medium.onnx`, `tokens.txt`, `espeak-ng-data/` |
| `piper-es` | tar.bz2 | `https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_ES-sharvard-medium.tar.bz2` | 65 MB | `es_ES-sharvard-medium.onnx`, `tokens.txt`, `espeak-ng-data/` |
| `piper-en` | tar.bz2 | `https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium.tar.bz2` | 65 MB | `en_US-lessac-medium.onnx`, `tokens.txt`, `espeak-ng-data/` |

Observações:
- Os tar.bz2 extraem para uma subpasta com o nome do pacote; mover o conteúdo para a raiz de `models\<id>\` após extrair.
- Extração: `tar.exe -xjf <arquivo> -C <destino>` (tar nativo do Windows, via `runTool`).
- **Modelos de tradução NÃO passam por aqui**: são gerenciados pelo próprio translateLocally com `translateLocally -d <id>` (ver P5). O model manager apenas expõe um método `ensureTranslationModels(Lang a, Lang b)` que roda os `-d` necessários.

API:

```dart
enum ModelState { missing, downloading, ready, corrupted }

class ModelManager {
  ModelManager(this.modelsRoot, this.tools);
  ModelState stateOf(String id);                 // checks expected files exist and .sha256 matches
  Stream<double> download(String id);            // progress 0..1; resume via HTTP Range if partial file exists
  Future<void> delete(String id);
  Future<void> ensureTranslationModels(Lang from, Lang to, CancellationToken token);
  String pathOf(String id, [String? file]);      // absolute path helper
}
```

Download: `http` streaming para `<id>\<arquivo>.part`; se `.part` existe, retomar com header `Range: bytes=<size>-`; ao concluir, renomear, calcular sha256 (`crypto`) e gravar em `<arquivo>.sha256`. Nas verificações seguintes, `ready` = arquivos esperados existem E sha256 bate. Se não bater → `corrupted` (UI oferece re-download).

## 8. Pipeline de dublagem de arquivo (P1–P9)

Todos os arquivos intermediários vivem no `workDir` do job (tabela completa no apêndice D). Threads para ferramentas CLI: `max(2, Platform.numberOfProcessors - 2)`.

### P1 — Demux (`steps/demux.dart`)

- **Entrada**: `config.inputVideo` (mp4/mkv/mov/webm).
- **Comandos**:
  ```
  ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 <inputVideo>
  ffmpeg -y -i <inputVideo> -vn -ac 2 -ar 44100 -c:a pcm_s16le <workDir>/audio_full.wav
  ```
- **Saída**: `audio_full.wav` (estéreo 44.1 kHz PCM16) + `videoDuration` (parsear o double impresso pelo ffprobe; ex.: `312.416000`).
- **Validação**: exit 0 em ambos; `audio_full.wav` existe com tamanho > 44 bytes; duração do wav (via header) dentro de ±2 s de `videoDuration`.
- **Erros típicos**: vídeo sem faixa de áudio (ffmpeg exit ≠ 0 com "does not contain any stream") → `PipelineException(demux, 'O vídeo não tem faixa de áudio')`.

### P2 — Separação de fontes (`backends/sherpa_separator.dart`)

- **Entrada**: `audio_full.wav`.
- **Comando**:
  ```
  sherpa-onnx-offline-source-separation.exe
    --spleeter-vocals=<models>/spleeter-2stems-fp16/vocals.fp16.onnx
    --spleeter-accompaniment=<models>/spleeter-2stems-fp16/accompaniment.fp16.onnx
    --num-threads=<N> --provider=cpu
    --input-wav=<workDir>/audio_full.wav
    --output-vocals-wav=<workDir>/vocals.wav
    --output-accompaniment-wav=<workDir>/accompaniment.wav
  ```
- **Saída**: `vocals.wav` + `accompaniment.wav`.
- **Fallback obrigatório (voice-over mode)**: se o exe não existir, o modelo estiver `missing`, exit ≠ 0, ou qualquer saída não for gerada → retornar `null` (interface `Separator`), logar warning, e o pipeline segue com `voiceOverMode = true`: P3 usa `audio_full.wav` como entrada e P8 usa ducking. **Nunca abortar o job por falha de separação.**

### P3 — Transcrição (`backends/whisper_transcriber.dart`)

- **Entrada**: `vocals.wav` (ou `audio_full.wav` em voice-over mode); `config.sourceLang`; modelo conforme preset (`best`→`whisper-small-q5_1`, `fast`→`whisper-base-q5_1`).
- **Comandos**:
  ```
  ffmpeg -y -i <entrada>.wav -ac 1 -ar 16000 -c:a pcm_s16le <workDir>/asr_in.wav
  whisper-cli.exe -m <models>/<preset>.bin -f <workDir>/asr_in.wav -l <sourceLang> -oj -of <workDir>/transcript -t <N>
  ```
- **Saída**: `transcript.json`. Schema relevante (apêndice A tem exemplo completo):
  ```json
  { "transcription": [ { "offsets": { "from": 0, "to": 5240 }, "text": " Hello world." } ] }
  ```
  `offsets` em **milissegundos**. Converter cada item em `TranscriptSegment(Duration(milliseconds: from), Duration(milliseconds: to), text.trim())`.
- **Validação**: JSON parseável; lista `transcription` não vazia (se vazia → `PipelineException(transcribe, 'Nenhuma fala detectada no vídeo')`); todo segmento com `to > from`.

### P4 — Segmentação (`steps/segmenter.dart`)

Transforma a lista bruta do whisper em unidades de dublagem. Função pura, 100% testável:

```dart
List<DubbingSegment> buildDubbingSegments(List<TranscriptSegment> raw);
```

Constantes (em `constants.dart`): `mergeMaxPause = 600ms`, `mergeMaxChars = 220`, `mergeMaxDur = 12s`.

```
// Passo 1 — normalizar e filtrar
for seg in raw:
  text = seg.text colapsando espaços múltiplos e aparando pontas
  descartar se: vazio, OU só símbolos musicais (♪, ♫), OU casa com regex ^\[.*\]$ (ex.: "[Music]", "[Applause]")

// Passo 2 — merge de segmentos consecutivos
units = []; cur = null
for seg in filtrados:
  if cur == null: cur = seg
  else if (seg.start - cur.end) < mergeMaxPause
       && (cur.text.length + 1 + seg.text.length) < mergeMaxChars
       && (seg.end - cur.start) < mergeMaxDur:
    cur = TranscriptSegment(cur.start, seg.end, cur.text + ' ' + seg.text)
  else: units.add(cur); cur = seg
if cur != null: units.add(cur)

// Passo 3 — quebrar unidades multi-frase
// splitSentences: divide após . ! ? … quando seguidos de espaço+letra maiúscula (regex),
// preservando a pontuação na frase anterior. Abreviações não tratadas no MVP (aceitável).
result = []
for u in units:
  parts = splitSentences(u.text)
  if parts.length == 1: result.add(u)
  else:
    // distribuir a duração proporcionalmente ao nº de caracteres, mantendo contiguidade
    total = u.end - u.start; charsTotal = soma(parts[i].length)
    t = u.start
    for p in parts:
      dur = total * (p.length / charsTotal)
      result.add(segment(t, t + dur, p)); t += dur

// IDs sequenciais a partir de 0, ordenados por start
```

### P5 — Tradução (`backends/translatelocally_translator.dart`)

- **Modelos**: antes do primeiro uso de cada direção, rodar `translateLocally -d <id>` (via `ModelManager.ensureTranslationModels`). IDs esperados: `en-pt-tiny`, `pt-en-tiny`, `en-es-tiny`, `es-en-tiny`. **Confirmar os IDs exatos com `translateLocally -a`** (lista os disponíveis online); se um par não existir com esse nome, usar o ID que o `-a` listar para o mesmo par (pode ser um modelo OPUS-MT, ex. sufixo `-base`) e registrar em `docs/decisoes.md`. Feito no spike S2.
- **Protocolo batch**: escrever uma frase por linha em `<workDir>/mt_src.txt` (UTF-8 **sem BOM**; substituir qualquer `\n`/`\r` interno do texto por espaço). Rodar:
  ```
  translateLocally.exe -m <src-dst-tiny> -i <workDir>/mt_src.txt -o <workDir>/mt_dst.txt
  ```
- **Pivô** (pt↔es): duas invocações — `pt-en-tiny` gera `mt_pivot.txt`, depois `en-es-tiny` gera `mt_dst.txt` (e vice-versa).
- **Validação**: `mt_dst.txt` tem exatamente o mesmo nº de linhas de `mt_src.txt` — senão `PipelineException(translate, 'Tradutor retornou N linhas para M frases')`. Linha traduzida vazia → manter o texto original naquele segmento e logar warning.

### P6 — Síntese TTS (`backends/piper_synthesizer.dart`)

Usa o pacote Dart `sherpa_onnx`. Voz por idioma destino: `pt`→`piper-pt-br`, `es`→`piper-es`, `en`→`piper-en`. Speaker id (`sid`): 0 (constante `defaultSid`; o modelo es_ES-sharvard tem 2 falantes — 0 e 1; confirmar no spike S3 qual é a voz preferida e fixar).

```dart
final tts = OfflineTts(OfflineTtsConfig(
  model: OfflineTtsModelConfig(
    vits: OfflineTtsVitsModelConfig(
      model: '<models>/piper-pt-br/pt_BR-faber-medium.onnx',
      tokens: '<models>/piper-pt-br/tokens.txt',
      dataDir: '<models>/piper-pt-br/espeak-ng-data',
    ),
    numThreads: 2,
    provider: 'cpu',
  ),
));
final audio = tts.generate(text: segment.translatedText, sid: 0, speed: 1.0);
// audio.samples: Float32List mono; audio.sampleRate: 22050
```

Criar o `OfflineTts` **uma vez por job** (não por segmento) e chamar `dispose()`/`free()` ao final. P6 e P7 rodam num único loop por segmento (ver P7). A cada segmento, emitir `PipelineEvent(synthesize, (i+1)/total, 'Sintetizando fala ${i+1}/$total')`.

### P7 — Ajuste de duração (`steps/fitter.dart`) — algoritmo central

Constantes: `overflowFrac = 0.8`, `overflowCap = 1500ms`, `vitsSpeedMax = 1.35`, `atempoMax = 1.25`, `minTarget = 400ms`.

```
para cada segmento i (com next = segmento i+1 ou null):
  alvo    = max(end - start, minTarget)
  folga   = next != null ? max(next.start - end, 0) : max(videoEnd - end, 0)
  permitido = alvo + min(folga * overflowFrac, overflowCap)

  audio = synth.synthesize(translatedText, speed: 1.0)
  dur   = audio.samples.length / audio.sampleRate  (segundos)

  se dur > permitido:
    speed = clamp(dur / permitido, 1.0, vitsSpeedMax)
    audio = synth.synthesize(translatedText, speed: speed)   // re-síntese: VITS acelera sem mudar pitch
    dur   = recalcular; registrar speedUsed = speed

  se dur > permitido:
    fator = min(dur / permitido, atempoMax)
    // via ffmpeg: gravar audio em <workDir>/seg_<id>_tts.wav (writeWavPcm16),
    // ffmpeg -y -i seg_<id>_tts.wav -filter:a atempo=<fator> seg_<id>_fit.wav
    // reler com readWav; registrar atempoUsed = fator
    dur = recalcular

  se dur > permitido:
    overflow = dur - permitido; logar warning  // NUNCA truncar o áudio

  fittedAudio = upsample2x(audio.samples)      // 22050 → 44100 (assert sampleRate == 22050)
```

Formatar `atempo` com 4 casas decimais (`1.1834`). Ao final, emitir `PipelineEvent(fit, 1.0, 'X segmentos acelerados, Y com estouro')`.

**`overflow` e `segmentsWithOverflow` são campos mortos hoje** — `DubbingSegment.overflow` (`models.dart:96`) e `DubbingResult.segmentsWithOverflow` estão declarados e **nunca são escritos**. Portanto o "Y com estouro" acima não tem fonte de dados, e o formulário de aceite não tem como preencher a coluna "Overflow". Isso é corrigido junto com a D-b.

**Deadline do fim do vídeo (D-b).** O cursor de `applyPlanToSegment` (`fitter.dart:198-207`) é monotônico e o atraso acumula ao longo do vídeo — é isso que produz a cauda excedente. `planDubSchedule` passa a receber `videoDurationSec` e a tratar o fim do vídeo como deadline do último run, com o mesmo mecanismo já usado para `maxDubDriftSeconds`, podendo subir até `tailSpeedMax` (acima do `maxTotalSpeed`/`atempoMax` normais) para a fala caber. Só o resíduo é cortado, e ele é medido.

### P8 — Mixagem (`steps/mixer.dart`)

**Etapa A — montar a faixa de voz dublada em Dart** (`buildDubTrack`):

```
buffer = Float32List(round(videoDuration_s * 44100))   // mono
para cada segmento com fittedAudio:
  off = round(start_s * 44100)
  para j em 0..fittedAudio.length-1:
    if off+j < buffer.length: buffer[off+j] += fittedAudio[j]
clamp de cada amostra em [-1.0, 1.0]
writeWavPcm16('<workDir>/dub_voice.wav', mono 44100)
```

**Etapa B — mix final via ffmpeg**:

Com separação (modo normal):
```
ffmpeg -y -i <workDir>/accompaniment.wav -i <workDir>/dub_voice.wav
  -filter_complex "[0:a][1:a]amix=inputs=2:duration=first:normalize=0,loudnorm=I=-16:TP=-1.5:LRA=11[out]"
  -map "[out]" -ac 2 -ar 44100 -c:a pcm_s16le <workDir>/dubbed.wav
```

Sem separação (`voiceOverMode`) — ducking do áudio original guiado pela voz dublada:
```
ffmpeg -y -i <workDir>/audio_full.wav -i <workDir>/dub_voice.wav
  -filter_complex "[0:a][1:a]sidechaincompress=threshold=0.02:ratio=12:attack=20:release=400[bg];[bg][1:a]amix=inputs=2:duration=first:normalize=0,loudnorm=I=-16:TP=-1.5:LRA=11[out]"
  -map "[out]" -ac 2 -ar 44100 -c:a pcm_s16le <workDir>/dubbed.wav
```

Nota: `sidechaincompress` consome a 2ª entrada como sidechain; por isso `dub_voice` aparece duas vezes (uma como sidechain, outra no `amix`). **Validação**: `dubbed.wav` existe e sua duração (header) = `videoDuration` ± 0.5 s.

**Sobre o `duration=first` (decisão D-b, 2026-07-12).** `first` é o **input 0** — `audio_full.wav` (ou `accompaniment.wav`), que tem exatamente a duração do vídeo. Portanto o `amix` amarra a saída à duração do vídeo e **descarta qualquer cauda de dublagem** que a ultrapasse. Isso contradizia frontalmente o `buildDubTrack`, que estende o buffer justamente para preservar essa cauda (`mixer.dart:16-24`, com comentário explícito) — as duas funções do mesmo arquivo se anulavam, e a última fala era cortada sem erro nem warning.

A validação acima (`= videoDuration ± 0.5 s`) é, portanto, **intencional e mantida**. O que muda é que ela deixa de ser acidental: o P7 passa a garantir que a dublagem já cabe (deadline do fim do vídeo), e o resíduo cortado é medido em `truncatedTailMs`. Não usar `duration=longest` nem `-shortest`.

### P9 — Mux (`steps/muxer.dart`) + legendas (`steps/subtitles.dart`)

```
ffmpeg -y -i <inputVideo> -i <workDir>/dubbed.wav
  -map 0:v:0 -map 1:a:0 [-map 0:a:0]        # o 3º map só se keepOriginalTrack
  -c:v copy -c:a aac -b:a 192k
  -metadata:s:a:0 language=<targetLang.iso639_2>
  [-metadata:s:a:1 language=<sourceLang.iso639_2>]
  -disposition:a:0 default
  <outputPath>
```

Se o container de saída for `.mp4` e o vídeo de entrada tiver codec incompatível com cópia (ffmpeg exit ≠ 0), refazer com `-c:v libx264 -preset veryfast -crf 20` e logar warning.

**SRT** (`generateSrt`): dois arquivos ao lado do vídeo de saída — `<nome>.<srcLang>.srt` (sourceText) e `<nome>.<targetLang>.srt` (translatedText), um bloco por `DubbingSegment`:

```
1
00:01:01,500 --> 00:01:03,250
Texto do segmento

```

Timestamp `HH:MM:SS,mmm` (vírgula antes dos milissegundos; campos com zero à esquerda). Blocos separados por linha em branco; índice começa em 1.

## 9. Orquestração (`pipeline.dart`)

```dart
Stream<PipelineEvent> runDubbingJob(
  DubbingJobConfig config,
  CancellationToken token, {
  required Tools tools,
  required ModelManager models,
  void Function(DubbingResult)? onDone,
});
```

- Gerar `jobId` = timestamp `yyyyMMdd_HHmmss`; `workDir = %TEMP%\omnitranslator\<jobId>\` (criar).
- Ordem: P1 → P2 → P3 → P4 → P5 → (P6+P7 em loop único) → P8 → P9. Entre cada passo, verificar `token.isCancelled` → lançar `PipelineException` com mensagem "Cancelado pelo usuário".
- Pré-checagem antes do P1: modelos necessários `ready` (whisper do preset, piper do idioma destino, spleeter é opcional) e `ensureTranslationModels` ok; senão, falhar imediatamente com mensagem listando o que falta.
- Cada passo emite ao iniciar `PipelineEvent(stage, 0.0, '<descrição pt-BR>')` e ao concluir `(stage, 1.0, ...)`; passos com loop emitem progresso incremental.
- **Sucesso**: apagar `workDir`. **Falha**: preservar `workDir` e incluir o caminho na mensagem da exceção (debug).
- Medir `elapsed` total e preencher `DubbingResult`.

## 10. UI Flutter (MVP) — `app/`

Estado global: `AppState extends ChangeNotifier` (via `provider`), com: lista de modelos e estados, job atual (config, stream subscription, eventos acumulados, resultado/erro), token de cancelamento.

**Tela 1 — Home (`home_screen.dart`)**
- Botão "Escolher vídeo" (`file_picker`, extensões: mp4, mkv, mov, webm) + label com o caminho escolhido.
- Dropdown "Idioma do vídeo" e "Dublar para": valores `en/pt/es` exibidos como "Inglês/Português/Espanhol". Validação: origem ≠ destino (senão botão desabilitado).
- Radio "Qualidade": `Rápido` / `Melhor` (default Melhor).
- Checkboxes: "Manter áudio original como segunda faixa" (default on), "Gerar legendas SRT" (default on).
- Botão primário "Dublar": desabilitado se faltam modelos (mostrar aviso com link para a tela Modelos) ou não há vídeo. Ao clicar: monta `DubbingJobConfig`, navega para Progresso (`Navigator.push`).
- Botão secundário "Modelos" → Tela 3.

**Tela 2 — Progresso (`progress_screen.dart`)**
- Lista vertical dos 9 estágios com nome pt-BR (Extraindo áudio / Separando voz da trilha / Transcrevendo / Segmentando / Traduzindo / Sintetizando vozes / Ajustando tempo / Mixando / Gerando vídeo), cada um com ícone: pendente ○, em andamento (spinner + barra com `progress`), concluído ✓, falhou ✗.
- Área de log colapsável (mensagens dos eventos).
- Botão "Cancelar" → `token.cancel()` + confirmação.
- Ao terminar: sucesso → mostrar caminho do arquivo + botão "Abrir pasta" (`explorer /select,<path>` via `Process.run`); erro → mensagem da exceção + caminho do workDir preservado.

**Tela 3 — Modelos (`models_screen.dart`)**
- Uma linha por entrada do manifest: nome amigável, tamanho, estado (`ausente/baixando (x%)/pronto/corrompido`), botão Baixar/Cancelar/Apagar. Barra de progresso alimentada pelo `Stream<double>` do `ModelManager`.
- Seção "Tradução": botões "Baixar modelos en↔pt / en↔es" que rodam `ensureTranslationModels`.

## 11. Fase 0 — Spikes de validação (S1–S5)

Cada spike gera um relatório curto em `docs/spikes/S<n>.md` com: comandos executados, tempos medidos, resultado do critério de aceite (PASSOU/FALHOU) e observações. Os spikes usam os binários de `tools/win/` diretamente no terminal — **sem escrever código de produção** (exceto S3, que usa um script Dart mínimo). Se um spike FALHAR, parar e reavaliar a spec antes de seguir para a Fase 1.

### S1 — whisper-cli transcreve pt/es/en com JSON parseável
1. Obter um vídeo/áudio real de ≥60 s com fala clara para CADA idioma (ex.: trecho de telejornal). Extrair wav: `ffmpeg -y -i amostra_pt.mp4 -ac 1 -ar 16000 -c:a pcm_s16le s1_pt.wav` (idem es/en).
2. Baixar os modelos manualmente (mesmas URLs do manifest, seção 7).
3. `whisper-cli.exe -m ggml-small-q5_1.bin -f s1_pt.wav -l pt -oj -of s1_pt -t 6` (idem es/en; medir tempo com `Measure-Command`).
4. **Aceite**: os 3 `.json` parseiam; `transcription` não vazia; `offsets.from < offsets.to` em todos os itens e não-decrescentes entre itens; texto legível (avaliação subjetiva registrada); tempo de processamento < 1× a duração do áudio.

### S2 — translateLocally cobre os 4 pares
1. `translateLocally.exe -a` → colar a saída no relatório; identificar os IDs reais dos pares en→pt, pt→en, en→es, es→en (esperado: `en-pt-tiny` etc.; se diferente, **atualizar a constante dos IDs na spec/código** e registrar em `docs/decisoes.md`).
2. `translateLocally.exe -d <id>` para os 4.
3. Criar `s2_en.txt` com estas 5 frases (uma por linha): `The weather is beautiful today.` / `I would like a cup of coffee.` / `The train leaves at seven in the morning.` / `She bought three books yesterday.` / `We are going to the beach this weekend.` Traduzir en→pt e en→es; criar 5 frases pt e traduzir pt→en→es (pivô manual em dois comandos).
4. **Aceite**: cada saída tem exatamente 5 linhas; traduções compreensíveis (registrar no relatório); tempo total < 10 s por lote.

### S3 — Piper via Dart com controle de `speed`
1. Criar `packages/dubbing_engine/tool/spike_s3.dart`: carrega `OfflineTts` (snippet da seção P6) e sintetiza 3 frases fixas por idioma (pt/es/en) em speeds 1.0, 1.2 e 1.35, gravando `s3_<lang>_<speed>.wav`.
2. **Aceite**: 27 wavs tocáveis; para cada frase, `dur(speed s) ≈ dur(1.0)/s` com tolerância ±10%; qualidade audível sem distorção nas 3 velocidades (registrar); síntese < 0.5× tempo real.

### S4 — Separação de fontes num trecho real
1. Trecho de 60 s de filme/série com fala + música (`ffmpeg -y -ss 300 -t 60 -i filme.mp4 -ac 2 -ar 44100 -c:a pcm_s16le s4_in.wav`).
2. Rodar o comando pinado do P2. Medir tempo.
3. **Aceite**: exit 0; `vocals.wav` com a voz claramente dominante e `accompaniment.wav` com a música sem voz inteligível (subjetivo, registrar); tempo < 2× a duração do trecho.

### S5 — atempo sem artefato
1. Pegar um wav do S3 (speed 1.0) e rodar `ffmpeg -y -i s3_pt_1.0.wav -filter:a atempo=1.2500 s5_out.wav`.
2. **Aceite**: `dur(s5_out) = dur(entrada)/1.25` ±2%; sem artefatos perceptíveis ao ouvir (registrar).

## 12. Testes

### 12.1 Testes unitários (`packages/dubbing_engine/test/`)

Rodar com `dart test`. Não dependem de binários externos nem de modelos. Casos obrigatórios (valores esperados calculados pelas fórmulas da spec):

**`segmenter_test.dart`**
- Merge + split: entrada `[(0ms, 2000ms, "Olá mundo."), (2300ms, 4000ms, "Tudo bem?")]` → pausa 300 ms < 600 → funde; split por pontuação → 2 segmentos: `(0, 2105ms, "Olá mundo.")` e `(2105ms, 4000ms, "Tudo bem?")` (proporção 10/19 e 9/19 dos caracteres sobre 4000 ms).
- Sem merge: mesma entrada com o 2º segmento começando em 2900 ms (pausa 900 ms) → 2 segmentos inalterados.
- Filtro: `[(0,1000,"[Music]"), (1000,2000,"♪"), (2000,3000,"  ")]` → lista vazia.
- Limite de chars: dois segmentos cujos textos somados ≥ 220 chars não fundem.

**`fitter_test.dart`** (função pura `computeAllowed(Duration target, Duration slack)` e clamps)
- `computeAllowed(3s, 1s)` = 3.8 s (3 + min(0.8, 1.5)).
- `computeAllowed(3s, 3s)` = 4.5 s (3 + min(2.4→1.5)).
- `computeAllowed(200ms, 0)` = 400 ms (aplica `minTarget`).
- `clampSpeed(4.5/3.8)` = 1.1842…; `clampSpeed(3.0)` = 1.35; `clampAtempo(2.0)` = 1.25.

**`subtitles_test.dart`**
- Segmento `(61500ms, 63250ms, "Olá!")`, índice 1 → bloco exato `"1\r?\n00:01:01,500 --> 00:01:03,250\r?\nOlá!\r?\n\r?\n"` (fixar `\n` na implementação).
- Hora > 1h: `(3661000ms, …)` → `01:01:01,000`.

**`mixer_test.dart`**
- Buffer de 1 s @44100 → length 44100.
- Dois segmentos no mesmo offset com amostras 0.5 e 0.7 → amostra final 1.0 (clamp de 1.2).
- Segmento que ultrapassa o fim do buffer → não lança, amostras excedentes descartadas.

**`wav_test.dart`**
- Roundtrip: escrever PCM16 mono 44100 com amostras conhecidas `[0.0, 0.5, -0.5, 1.0, -1.0]`, reler → valores iguais com erro ≤ 1/32768.
- `upsample2x([1.0, 0.0])` → `[1.0, 0.5, 0.0, 0.0]` (última interpola com a própria última amostra).

### 12.2 Teste de integração (`packages/dubbing_engine/tool/integration_test.dart`)

Pré-requisito: `tools/win/` completo + modelos `whisper-base-q5_1`, `piper-en`, `piper-pt-br` instalados + modelos de tradução en↔pt baixados. Executar: `dart run tool/integration_test.dart`. O script:

1. **Gera a própria fixture** (nada de vídeo commitado): sintetiza com Piper-en as 5 frases do S2, concatena com 1 s de silêncio entre elas (mixer), grava `fixture_speech.wav`; monta o vídeo:
   `ffmpeg -y -f lavfi -i color=c=blue:s=640x360:d=<dur+2> -i fixture_speech.wav -c:v libx264 -preset veryfast -c:a aac -shortest fixture.mp4`.
2. Roda `runDubbingJob` com `sourceLang=en, targetLang=pt, preset=fast`.
3. **Asserts** (imprimir PASS/FAIL por item; exit code ≠ 0 se algum falhar):
   - job termina sem exceção;
   - arquivo de saída existe;
   - `ffprobe -v error -show_entries stream=codec_type -of csv <saida>` mostra 1 stream de vídeo e 2 de áudio;
   - duração do container (ffprobe) = duração da fixture ±0.5 s;
   - os 2 `.srt` existem, parseiam e têm ≥3 blocos cada;
   - nenhum log de fala truncada (não existe truncamento no código — assert de sanidade nos overflows: `overflow` reportado é permitido, mas contado).

## 13. Critérios de aceite do MVP (Fase 1)

Executar manualmente e registrar em `docs/aceite-mvp.md` (tabela por caso):

1. Dublar 3 vídeos reais de ~5 min (conteúdo com fala predominante) cobrindo as 6 direções entre en/pt/es (cada vídeo em 2 direções).
2. Para cada job medir e exigir:
   - tempo total < 2× a duração do vídeo (preset `best`, máquina de desenvolvimento, CPU ≥8 threads);
   - pico de RAM do processo < 4 GB (Gerenciador de Tarefas ou `Get-Process`);
   - vídeo de saída abre no VLC com 2 faixas de áudio alternáveis e a dublada como padrão;
   - falas dubladas começam dentro de ±300 ms do início da fala original (verificação por amostragem de 10 falas/vídeo no VLC);
   - nenhuma fala cortada no meio; nº de blocos SRT == nº de segmentos;
   - no modo separação: música/efeitos audíveis na faixa dublada; no voice-over: original audível baixo sob a dublagem;
   - loudness consistente (sem estouros audíveis; `loudnorm` aplicado).
3. Cancelamento: cancelar um job no meio do P6 → app responsivo, sem processo órfão (`Get-Process ffmpeg,whisper-cli` vazio), workDir preservado.

## 14. Fase 2 — Tempo real no desktop (detalhe médio)

> Especificar em micro-detalhe SOMENTE após o MVP aceito. Esta seção fixa a arquitetura e os riscos.

**Fluxo**: `AudioTap → StreamingAsr → IncrementalTranslator → StreamingSynth → DubScheduler/DelayedPlayer`, com atraso alvo configurável `D = 3 s` (faixa 2–5 s na UI).

- **AudioTap**: subprocesso `ffmpeg -i <arquivo|URL> -f s16le -ac 1 -ar 16000 -` lendo PCM do stdout em chunks de ~4800 amostras (300 ms). Funciona para arquivo local, HTTP(S) e HLS.
- **StreamingAsr**: `OnlineRecognizer` do pacote `sherpa_onnx` com modelos **Kroko ASR** (HF `Banafo/Kroko-ASR`, en/es/pt) + endpoint detection do próprio recognizer para fechar frases. *Risco aberto: nomes exatos dos arquivos por idioma no repo HF — verificar no início da fase.* Fallback: VAD Silero + whisper base em janelas.
- **IncrementalTranslator**: processo `translateLocally -m <id>` persistente com stdin/stdout em pipe; enviar frase fechada + `\n`, ler linha de resposta. Pivô = dois processos encadeados.
- **StreamingSynth**: Piper (mesmo backend do MVP), fila de frases; sintetiza durante o buffer de atraso.
- **DelayedPlayer**: vídeo no player `media_kit` com volume da faixa original reduzido (ducking fixo, ex. 20%) e início atrasado em `D`; falas dubladas agendadas em `timestamp_original + D` e tocadas num output de áudio separado; sincronia por polling da posição do player (200 ms). *Risco aberto: media_kit não expõe tap de PCM — por isso o áudio para ASR vem do AudioTap (2ª decodificação do mesmo arquivo/URL), o que é aceitável para arquivo/HTTP.*
- **Aceite da fase**: latência fim-a-fim medida ≤ D+1 s; 10 min de reprodução sem drift > 200 ms; uso de CPU sustentável (< 80% em máquina de referência).

## 15. Fases 3–4 — Android e além

A implementação Android é definida em [especificacao-android.md](especificacao-android.md). Resumo não normativo:

- Windows e Android permanecem no mesmo repositório/app Flutter e compartilham `dubbing_engine`.
- Antes do port, o engine recebe `DubbingRuntime`, áudio intermediário em disco, leitura por janela, writer WAV sequencial e checkpoints retomáveis.
- Android M1 cobre arquivo local en/pt/es, Whisper tiny/base ONNX, tradução local, Piper fixo, voice-over com ducking e SRT.
- Tradução en↔pt é gate obrigatório. O slimt só suporta a arquitetura `tiny`, então o Android usa os pares `enpt`/`pten` **tiny** (Mozilla, MPL-2.0); o desktop mantém `base-memory`. Fallback, se o tiny reprovar em qualidade: bergamot-translator completo via NDK, com time-box.
- FFmpegKitNext oficial, compilado do código-fonte em variante LGPL, atende aos filtros e ao mux; Media3 não substitui esse pipeline de áudio.
- Jobs longos rodam em foreground service direto `mediaProcessing`, com estado persistido e retomada; entrada/saída usam Storage Access Framework.
- Separação, diarização, YouTube, tempo real, `AudioPlaybackCapture` e microfone são marcos posteriores.

## 16. Licenças

| Componente | Licença | Observação |
|---|---|---|
| sherpa-onnx (runtime + pacote Dart) | Apache-2.0 | ok comercial |
| whisper.cpp + modelos Whisper | MIT | ok |
| FFmpeg (build BtbN **lgpl**) | LGPL-2.1 | usar como subprocesso (sem link estático); não usar builds GPL na distribuição |
| FFmpegKitNext/FFmpeg no Android | LGPL-3.0 por padrão | compilar do código-fonte, fixar commit/configuração e nunca habilitar `--enable-gpl` |
| translateLocally | MIT | ok |
| slimt ou bergamot-translator no Android | conferir a licença do commit fixado | registrar código, patches, dependências nativas e notices antes do release |
| Modelos Bergamot/Firefox Translations | CC-BY-SA 4.0 (maioria) | ok com atribuição; conferir por modelo no `-a` |
| Modelos OPUS-MT | CC-BY 4.0 | ok com atribuição |
| Piper (engine) | MIT | vozes têm cartões próprios — **conferir `MODEL_CARD` dentro de cada pacote de voz** antes de distribuir |
| Silero VAD | MIT | ok |
| Spleeter (modelos) | MIT (Deezer) | ok |
| Kroko ASR (modelos comunitários) | CC-BY-SA | Fase 2; tiers pagos existem — usar só os gratuitos |
| **NLLB** | CC-BY-**NC** | **NÃO usar** (proíbe uso comercial) |

Tela "Sobre" do app deve listar as atribuições acima.

## 17. Apêndices

### A — Exemplo real de saída do `whisper-cli -oj` (`transcript.json`)

```json
{
  "systeminfo": "...",
  "model": { "type": "small", "multilingual": true },
  "params": { "model": "ggml-small-q5_1.bin", "language": "pt" },
  "result": { "language": "pt" },
  "transcription": [
    {
      "timestamps": { "from": "00:00:00,000", "to": "00:00:04,380" },
      "offsets": { "from": 0, "to": 4380 },
      "text": " Bom dia, sejam bem-vindos ao programa."
    },
    {
      "timestamps": { "from": "00:00:04,380", "to": "00:00:07,900" },
      "offsets": { "from": 4380, "to": 7900 },
      "text": " Hoje vamos falar sobre tecnologia."
    }
  ]
}
```

Usar somente `transcription[].offsets` (ms) e `text`. Campos extras devem ser ignorados sem erro.

### B — Exemplo de SRT gerado

```
1
00:00:00,000 --> 00:00:04,380
Bom dia, sejam bem-vindos ao programa.

2
00:00:04,380 --> 00:00:07,900
Hoje vamos falar sobre tecnologia.

```

### C — Manifest de modelos (conteúdo do mapa hardcoded em `model_manager.dart`)

```json
[
  { "id": "whisper-small-q5_1", "kind": "file",
    "url": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin",
    "sizeMb": 190, "expects": ["ggml-small-q5_1.bin"], "displayName": "Reconhecimento de fala — Melhor" },
  { "id": "whisper-base-q5_1", "kind": "file",
    "url": "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin",
    "sizeMb": 60, "expects": ["ggml-base-q5_1.bin"], "displayName": "Reconhecimento de fala — Rápido" },
  { "id": "spleeter-2stems-fp16", "kind": "tarbz2",
    "url": "https://github.com/k2-fsa/sherpa-onnx/releases/download/source-separation-models/sherpa-onnx-spleeter-2stems-fp16.tar.bz2",
    "sizeMb": 40, "expects": ["vocals.fp16.onnx", "accompaniment.fp16.onnx"], "displayName": "Separação de voz e música" },
  { "id": "piper-pt-br", "kind": "tarbz2",
    "url": "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-pt_BR-faber-medium.tar.bz2",
    "sizeMb": 65, "expects": ["pt_BR-faber-medium.onnx", "tokens.txt", "espeak-ng-data"], "displayName": "Voz — Português (BR)" },
  { "id": "piper-es", "kind": "tarbz2",
    "url": "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-es_ES-sharvard-medium.tar.bz2",
    "sizeMb": 65, "expects": ["es_ES-sharvard-medium.onnx", "tokens.txt", "espeak-ng-data"], "displayName": "Voz — Espanhol" },
  { "id": "piper-en", "kind": "tarbz2",
    "url": "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium.tar.bz2",
    "sizeMb": 65, "expects": ["en_US-lessac-medium.onnx", "tokens.txt", "espeak-ng-data"], "displayName": "Voz — Inglês" }
]
```

### D — Arquivos do workdir (`%TEMP%\omnitranslator\<jobId>\`)

| Arquivo | Criado por | Conteúdo |
|---|---|---|
| `audio_full.wav` | P1 | áudio original, estéreo 44.1 kHz PCM16 |
| `vocals.wav` / `accompaniment.wav` | P2 | stems (ausentes em voice-over mode) |
| `asr_in.wav` | P3 | voz em 16 kHz mono |
| `transcript.json` | P3 | saída do whisper-cli |
| `mt_src.txt` / `mt_pivot.txt` / `mt_dst.txt` | P5 | frases, 1/linha, UTF-8 sem BOM |
| `seg_<id>_tts.wav` / `seg_<id>_fit.wav` | P7 | só para segmentos que precisaram de atempo |
| `dub_voice.wav` | P8-A | faixa de voz dublada montada, mono 44.1 kHz |
| `dubbed.wav` | P8-B | mix final, estéreo 44.1 kHz |

### E — Constantes do pipeline (`constants.dart`)

| Constante | Valor | Usada em |
|---|---|---|
| `mergeMaxPause` | 600 ms | P4 |
| `mergeMaxChars` | 220 | P4 |
| `mergeMaxDur` | 12 s | P4 |
| `minTarget` | 400 ms | P7 |
| `overflowFrac` | 0.8 | P7 |
| `overflowCap` | 1500 ms | P7 |
| `vitsSpeedMax` | 1.35 | P7 |
| `atempoMax` | 1.25 | P7 |
| `defaultSid` | 0 | P6 |
| `ttsSampleRate` | 22050 Hz | P6/P7 |
| `mixSampleRate` | 44100 Hz | P1/P8 |
| `asrSampleRate` | 16000 Hz | P3 |
| `loudnorm` | I=-16, TP=-1.5, LRA=11 | P8 |
| `aacBitrate` | 192k | P9 |
| `toolTimeout` | 30 min | runTool |
| `realtimeDelayDefault` | 3 s | Fase 2 |
