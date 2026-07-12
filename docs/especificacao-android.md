# OmniTranslator Android — Especificação Técnica v2

> **Status:** especificação para implementação futura; nenhum item descrito neste documento está implementado no app principal ainda.
>
> **v2 (2026-07-12)** — incorpora a auditoria de [revisao-especificacao-android.md](revisao-especificacao-android.md) e as decisões D-a…D-d de [decisoes.md](decisoes.md). Mudanças que invertem trabalho previsto na v1:
> - **§10** — o slimt só suporta a arquitetura `tiny`; o caminho "rodar slimt com os hiperparâmetros do `base-memory`" era impossível e saiu. O AT-1 passa a fechar em horas com os modelos tiny públicos, e o fallback bergamot-via-NDK vira exceção com time-box.
> - **§16.1** — o gate de 16 KB virou **AT-0**, o primeiro item executável, em vez de ser descoberto na fase D4.
> - **§8/P3** — Silero VAD substitui "janelas de 30 s com dedup de overlap", algoritmo que a v1 exigia mas não fornecia.
> - **§7.4** — a cauda da última fala é resolvida; a v1 herdava, sem perceber, um bug que existe hoje no desktop.
> - **§5.7–5.9, §6.0** — os contratos que a v1 declarava normativos mas não definia.
>
> **Documento-base:** esta especificação complementa [especificacao-tecnica.md](especificacao-tecnica.md). Quando houver divergência sobre Android, este documento prevalece. A especificação desktop continua prevalecendo para Windows.
>
> **Objetivo editorial:** as decisões, interfaces, ordem de trabalho e critérios de aceite abaixo são deliberadamente explícitos para que a implementação possa ser executada por um agente menor, sem precisar redesenhar a solução.

## 1. Objetivo do primeiro marco Android

Entregar no mesmo app Flutter do Windows uma versão Android capaz de:

1. importar um arquivo de vídeo local;
2. reconhecer fala localmente em inglês (`en`), português (`pt`) ou espanhol (`es`);
3. traduzir localmente entre os três idiomas, nas seis direções;
4. sintetizar uma voz Piper fixa no idioma de destino;
5. ajustar a duração das falas sem truncá-las;
6. aplicar voice-over com ducking sobre o áudio original;
7. gerar um vídeo dublado e dois arquivos SRT;
8. continuar processando com a tela apagada ou com outra Activity em primeiro plano;
9. funcionar sem rede depois que os modelos necessários forem baixados.

O primeiro marco é chamado neste documento de **Android M1**.

### 1.1 Incluído no Android M1

- arquivo de vídeo local;
- idiomas en/pt/es;
- presets `rápido` e `melhor`;
- Whisper tiny/base em formato ONNX via sherpa-onnx;
- tradução slimt ou bergamot-translator, decidida pelo gate AT-1;
- uma voz Piper selecionada pelo usuário;
- voice-over com ducking;
- legendas SRT de origem e destino;
- retomada a partir do último estágio concluído;
- notificação persistente com progresso e ação de cancelar;
- AAB para Google Play e APK arm64 para instalação direta.

### 1.2 Explicitamente fora do Android M1

- download de YouTube;
- separação de voz e música;
- diarização e escolha automática de voz por falante;
- múltiplas vozes numa mesma dublagem;
- player embutido e dublagem em tempo real;
- captura de áudio de outros apps;
- captura por microfone;
- iOS;
- suporte de release a `armeabi-v7a`, `x86` ou `x86_64`.

Esses recursos não devem ser adicionados “aproveitando a implementação”. Eles têm marcos próprios na seção 18.

## 2. Regras obrigatórias

1. **Um único repositório:** Windows e Android vivem em `omnitranslator`; o app Android será gerado em `app/android/`.
2. **Uma única fonte do engine:** `packages/dubbing_engine` é usado diretamente pelo app; não criar cópia ou dependência Git para o próprio repositório.
3. **Sem executáveis Android:** Android não pode depender de `Process.start`, `.exe`, `cmd`, `explorer`, `tar` do sistema ou caminhos `tools/win`.
4. **Sem modelo no APK/AAB:** modelos são baixados sob demanda e validados por SHA-256.
5. **Português bloqueia release:** Android M1 não pode ser marcado como concluído sem en→pt e pt→en aprovados no dispositivo.
6. **Sem GPL no binário distribuído:** FFmpegKitNext deve ser compilado em variante LGPL, sem `--enable-gpl` e sem bibliotecas GPL.
7. **Sem buffers proporcionais à duração total:** nenhuma etapa nova pode alocar um `Float32List`, `Int16List` ou `Uint8List` que represente o áudio inteiro do vídeo, exceto janelas com limite explícito.
8. **Sem escrita direta em URI:** o engine trabalha apenas com paths locais; a casca Android importa uma URI para o workdir e exporta os resultados ao final.
9. **Todo estágio valida saída:** existência, tamanho mínimo e formato básico devem ser verificados antes de gravar checkpoint de sucesso.
10. **Cancelamento cooperativo:** loops Dart, sherpa, tradução e FFmpeg devem observar o mesmo `CancellationToken`.

## 3. Estado atual e consequências para o port

### 3.1 Partes reutilizáveis

- contratos de dados de `models.dart`;
- segmentação, agendamento e regras de não truncamento;
- SRT;
- catálogo de idiomas e caminhos de tradução;
- Piper pelo pacote `sherpa_onnx`;
- testes unitários da lógica pura;
- factories já existentes em `runDubbingJob` como ponto inicial da injeção.

### 3.2 Acoplamentos que precisam ser removidos antes do Android

| Acoplamento atual | Problema no Android | Tratamento obrigatório |
|---|---|---|
| `Tools.locate()` procura `tools/win` | não existem `.exe` executáveis | mover para `DesktopRuntime` |
| `runTool(exePath, args)` recebe path de executável | Android executa biblioteca in-process | trocar por `MediaToolRunner` tipado |
| `ModelManager` chama `tar` | Android não fornece `tar` para o app | injetar `ArchiveExtractor` |
| `ModelManager.ensureTranslationModels` chama translateLocally | translateLocally é desktop | mover instalação de modelos para o backend de tradução |
| `main.dart` usa `APPDATA` | variável Windows | usar `path_provider` na casca Flutter |
| UI usa `cmd`/`explorer` | APIs Windows | usar intents/SAF no Android |
| `pipeline.dart` importa backends concretos | impede runtime Android limpo | receber `DubbingRuntime` obrigatório |
| áudios naturais ficam numa lista | memória cresce com o vídeo | persistir WAV por segmento |
| `DubbingSegment.fittedAudio` guarda `Float32List` | mantém todas as falas em RAM | guardar path e metadados |
| `buildDubTrack` cria buffer do vídeo inteiro | ~635 MB por hora só para mono float32 | escrever PCM16 sequencialmente |
| `readWav` lê o arquivo inteiro | ASR/trim podem estourar RAM | introduzir leitura por janela |

O port Android não começa pelos backends. Primeiro deve ser concluída a refatoração de portabilidade e memória da seção 7.

## 4. Arquitetura alvo

```text
app/lib (UI compartilhada)
│
├── bootstrap desktop ── DesktopRuntime ── executáveis Windows
│
└── bootstrap Android ── AndroidRuntime
                         ├── SherpaWhisperTranscriber
                         ├── AndroidTranslator (slimt ou bergamot)
                         ├── PiperSynthesizer compartilhado
                         ├── VoiceOverSeparator (implementa Separator)
                         ├── FFmpegKitNextRunner
                         ├── DartArchiveExtractor
                         └── AndroidDiskSpaceProbe
                                  │
                                  ▼
packages/dubbing_engine
├── pipeline e contratos independentes de plataforma
├── áudio intermediário em disco
├── checkpoints por estágio
└── lógica pura testável na VM
```

### 4.1 Dependências permitidas por camada

| Camada | Pode conhecer | Não pode conhecer |
|---|---|---|
| engine/core | Dart, paths locais, interfaces, modelos | Android SDK, MethodChannel, URI, `.exe` |
| desktop runtime | executáveis e paths Windows | Android SDK |
| Android runtime Dart | sherpa, FFI, runner FFmpeg, paths app-specific | `APPDATA`, `cmd`, `explorer` |
| plugin/casca Kotlin | SAF, Service, StatFs, notificações, FlutterEngine | regras de tradução/segmentação |
| UI compartilhada | estado do job e capacidades expostas | detalhes de FFmpeg, slimt ou NDK |

## 5. Contratos públicos novos

Os nomes abaixo são normativos. O implementador pode separar os arquivos de forma diferente apenas se mantiver as assinaturas e responsabilidades.

### 5.1 `DubbingRuntime`

Local sugerido: `packages/dubbing_engine/lib/src/runtime/dubbing_runtime.dart`.

```dart
typedef SeparatorFactory = Separator Function();
typedef DiarizerFactory = Diarizer Function({int? speakerCount});
typedef TranscriberFactory = Transcriber Function(Preset preset);
typedef TranslatorFactory = Translator Function();
typedef SynthesizerFactory = Synthesizer Function(
  Lang targetLang, {
  String? voiceModelId,
  int voiceSid,
});
typedef DownloaderFactory = MediaDownloader Function();

class DubbingRuntime {
  final SeparatorFactory createSeparator;
  final DiarizerFactory? createDiarizer;
  final TranscriberFactory createTranscriber;
  final TranslatorFactory createTranslator;
  final SynthesizerFactory createSynthesizer;
  final DownloaderFactory? createDownloader;   // null no Android M1 (sem YouTube)
  final MediaToolRunner mediaTools;
  final DiskSpaceProbe diskSpace;
  final JobCheckpointStore checkpoints;
  final ModelManager models;                   // única fonte de verdade

  const DubbingRuntime({
    required this.createSeparator,
    this.createDiarizer,
    required this.createTranscriber,
    required this.createTranslator,
    required this.createSynthesizer,
    this.createDownloader,
    required this.mediaTools,
    required this.diskSpace,
    required this.checkpoints,
    required this.models,
  });
}
```

`runDubbingJob` passa a exigir `runtime` e deixa de importar backends concretos:

```dart
Stream<PipelineEvent> runDubbingJob(
  DubbingJobConfig config,
  CancellationToken token, {
  required DubbingRuntime runtime,
  void Function(DubbingResult)? onDone,
});
```

`ModelManager` **entra no `DubbingRuntime`** e sai da assinatura de `runDubbingJob`. Os backends concretos precisam dele (`WhisperTranscriber(tools, models, preset)`, `TranslateLocallyTranslator(tools, models)`) e o capturam por closure a partir da mesma instância — se ele também viesse por parâmetro, existiriam dois caminhos para o mesmo objeto, sem garantia de serem a mesma instância. É exatamente o "caminho divergente" que esta seção quer evitar.

Não manter simultaneamente as factories antigas e `DubbingRuntime` depois da migração dos testes. Um único mecanismo evita caminhos divergentes.

#### `MediaDownloader` (ausência de YouTube no Android)

O `pipeline.dart` importa hoje `steps/youtube.dart` e tem um estágio `download` condicionado a `config.youtubeUrl != null`. A regra #3 proíbe executáveis no Android e o M1 exclui YouTube — mas a ausência precisa ser **expressa**, não improvisada:

```dart
abstract interface class MediaDownloader {
  Future<String> download(DubbingJobConfig config, String workDir, CancellationToken token);
}
```

- `createDownloader` é nulo no `AndroidRuntime`.
- Se `config.youtubeUrl != null` e `createDownloader == null`, o pipeline lança
  `PipelineException(PipelineStage.download, 'YouTube não é suportado nesta plataforma')`.
- `pipeline.dart` deixa de importar `steps/youtube.dart`; o downloader vira um backend desktop como os demais.

### 5.2 `MediaToolRunner`

Local sugerido: `packages/dubbing_engine/lib/src/runtime/media_tool_runner.dart`.

```dart
enum MediaTool { ffmpeg, ffprobe }

abstract interface class MediaToolRunner {
  Future<ToolResult> run(
    MediaTool tool,
    List<String> args, {
    String? workingDirectory,
    Duration timeout = toolTimeout,
    CancellationToken? token,
    void Function(double progress)? onProgress,
  });
}
```

- `DesktopMediaToolRunner` resolve `MediaTool` para os paths em `Tools` e chama o runner atual.
- `FFmpegKitNextRunner` converte os mesmos argumentos para uma sessão FFmpegKitNext.
- O engine nunca decide a implementação examinando strings como `exePath.contains('ffmpeg')`.

### 5.3 `ArchiveExtractor`

```dart
abstract interface class ArchiveExtractor {
  Future<void> extractTarBz2(
    String archivePath,
    String destinationDir, {
    CancellationToken? token,
    void Function(double progress)? onProgress,
  });
}
```

- Desktop pode manter `tar` inicialmente atrás de `DesktopArchiveExtractor`.
- Android usa `package:archive`/`archive_io` com streams de arquivo.
- Antes de materializar cada entrada, normalizar o path e rejeitar saída fora de `destinationDir`.
- A extração deve ocorrer em `.extract`, validar `expects` e só então mover para o diretório final.

### 5.4 `DiskSpaceProbe`

```dart
abstract interface class DiskSpaceProbe {
  Future<int?> freeBytes(String path);
}
```

- Desktop encapsula `GetDiskFreeSpaceExW` existente.
- Android chama `StatFs` por MethodChannel; não criar binding libc próprio.

O `freeBytesForPath` atual (`disk_space.dart:19`) é **síncrono** e retorna `null` em qualquer plataforma que não seja Windows (linha 20) — ou seja, no Android o gate de espaço do pipeline morreria em silêncio. A migração para `Future` é obrigatória, e **toca a UI**: há 4 usos síncronos em `home_screen.dart` (`:337`, `:358`, `:374`, `:397`), todos chamados de dentro de `build()`. Eles passam a ler um valor cacheado no `AppState`, recalculado quando o path muda — não fazer I/O de disco dentro de `build()`.

### 5.5 Instalação de modelos de tradução

O método `ModelManager.ensureTranslationModels` deve ser removido. A interface `Translator` passa a declarar preparação:

```dart
abstract class Translator {
  Future<void> ensureReady(
    Lang from,
    Lang to,
    CancellationToken token,
  );

  Future<List<String>> translate(
    List<String> sentences,
    Lang from,
    Lang to,
    CancellationToken token,
  );
}
```

O pipeline chama `ensureReady` antes de `translate`. Cada backend conhece seu formato e sua fonte de modelos.

### 5.6 Áudio de segmento em disco

Em `DubbingSegment`, substituir:

```dart
Float32List? fittedAudio;
```

por:

```dart
String? naturalAudioPath;
String? fittedAudioPath;
int? fittedSampleRate;
int? fittedSampleCount;
```

`naturalAudioPath` pode ser apagado após o fitted ser validado. `fittedAudioPath` só é apagado depois de `dub_voice.wav` ser concluído e checkpointado.

### 5.7 `JobCheckpointStore`

Local sugerido: `packages/dubbing_engine/lib/src/runtime/job_checkpoint_store.dart`.

O engine só conhece paths locais (regra #8), então **uma única implementação concreta serve as duas plataformas**. A interface existe para os testes poderem usar um fake em memória, não para haver variante Android.

```dart
enum JobState {
  created, importing, imported, demuxed, transcribed, segmented,
  translated, synthesized, fitted, mixed, completedPendingExport, exported,
  cancelled, failed,
}

class JobCheckpoint {
  final int schemaVersion;             // 1
  final String jobId;
  final JobState state;
  final String configFingerprint;      // ver abaixo
  final double progress;
  final Map<String, String> artifacts; // nome lógico -> path relativo ao workDir
  final List<String> warnings;
  final String? lastError;
  final DateTime createdAt;
  final DateTime updatedAt;
}

abstract interface class JobCheckpointStore {
  Future<JobCheckpoint?> load(String jobId);
  Future<void> save(JobCheckpoint checkpoint);   // escrita atômica (§9.2)
  Future<List<JobCheckpoint>> listRecoverable(); // estados não terminais
  Future<void> delete(String jobId);
}

class FileJobCheckpointStore implements JobCheckpointStore {
  FileJobCheckpointStore(String jobsRoot);
}
```

- `configFingerprint` = SHA-256 de (`DubbingJobConfig` normalizado + `inputSize` + `inputLastModified` + `schemaVersion`). É o que implementa a regra da §9.4 "não reutilizar resultado se config, input size ou versão do schema divergirem".
- `save` grava o `job.json` da §9.3 usando o protocolo `.part` → flush → validar parse → rename da §9.2.
- **Validação de estágio (regra #9):** cada estágio declara os artefatos que produz e os valida — existência, tamanho mínimo e formato básico (header RIFF, JSON parseável) — **antes** de `save` registrar o estado de sucesso. Um `.part` nunca conta como etapa concluída.
- Retomada: carregar o checkpoint, revalidar os `artifacts` do estado salvo; se algum falhar, recuar para o último estado cujos artefatos ainda validem.

### 5.8 `CancellationToken` — generalização

O `CancellationToken` atual (`models.dart:173-186`) guarda uma `List<Process>` e só sabe matar subprocessos do sistema operacional. No Android não há `Process`: o FFmpegKitNext precisa de `cancel(sessionId)` e os loops de sherpa precisam de um flag cooperativo. Do jeito que está, **a regra obrigatória #10 é impossível de cumprir**.

```dart
class CancellationRegistration {
  void dispose();   // remove o callback (evitar vazamento em jobs longos)
}

class CancellationToken {
  bool get isCancelled;
  void cancel();                                    // dispara todos os callbacks
  void throwIfCancelled(PipelineStage stage);       // atalho p/ PipelineException
  CancellationRegistration addCancellable(void Function() onCancel);
}
```

- `addProcess(Process p)` deixa de ser API do core e vira açúcar do runtime desktop sobre `addCancellable(p.kill)`, com `dispose()` quando o processo termina.
- `FFmpegKitNextRunner` registra `addCancellable(() => FFmpegKitConfig.cancel(sessionId))`.
- Loops de VAD, ASR e TTS checam `isCancelled` **entre janelas e entre segmentos** — não há como interromper uma inferência em andamento, então a granularidade de cancelamento é a janela.
- `models.dart` deixa de importar `dart:io`.

### 5.9 `SeparationOutcome` — reason code

A §8/P2 exige que a separação retorne falha com o motivo `notSupportedInAndroidM1` e que isso seja tratado como **comportamento esperado, não erro nem warning**. O contrato atual (`interfaces.dart:6-14`) não tem código nenhum — só uma string livre, hoje preenchida com prosa em português (`'Modelo $spleeterModelId não está pronto'`, `'Cancelado pelo usuário'`). E o pipeline **emite warning** quando a separação falha (`pipeline.dart:125-133`), que é exatamente o que a §8/P2 proíbe.

```dart
enum SeparationFailureReason {
  notSupportedOnPlatform,   // Android M1: esperado, informativo
  modelNotReady,
  cancelled,
  toolFailed,
  unsupportedAudio,
}

class SeparationOutcome {
  final ({String vocalsWav, String accompanimentWav})? files;
  final SeparationFailureReason? reason;
  final String? detail;                       // diagnóstico livre, nunca texto de UI

  const SeparationOutcome.success(this.files) : reason = null, detail = null;
  const SeparationOutcome.failure(this.reason, {this.detail}) : files = null;
  bool get ok => files != null;
}
```

Comportamento do pipeline:

- `notSupportedOnPlatform` → evento **informativo** (`isWarning: false`) com a mensagem de produto: *"modo voice-over: o áudio original permanece baixo sob a dublagem"*.
- Qualquer outro motivo → warning técnico, como hoje.

O texto de UI é derivado do `reason`, nunca do `detail`.

## 6. Perfis e catálogo de modelos Android

O manifest não pode mapear o mesmo ID Whisper para `.bin` no Windows e ONNX no Android. Introduzir perfis explícitos:

```dart
enum ModelPlatform { windows, android }

class ModelCatalog {
  final ModelPlatform platform;
  final List<ModelEntry> entries;
  final Map<Preset, String> asrModelIds;
  final Map<Lang, String> defaultVoiceIds;
  final Map<(Lang, Lang), TranslationModelEntry> translationModels;

  static ModelCatalog windows();
  static ModelCatalog android();
}
```

### 6.0 Como o `ModelCatalog` se liga ao `ModelManager` (trabalho não óbvio)

A distância entre o catálogo proposto e o código atual é maior do que parece, e **este é um item de trabalho real, não um detalhe**:

- `ModelManager.manifest` é hoje `static List<ModelEntry> get manifest` (`model_manager.dart:75`) — uma lista Dart literal com **64 entradas**;
- `model_manager_test.dart:23` afirma **exatamente 64 entradas** (são 31 testes nesse arquivo);
- `ModelEntry` (`model_manager.dart:41-67`) **não tem nenhum campo de plataforma**;
- o estágio `prepare` do pipeline (`pipeline.dart:56-83`) faz o readiness check com **IDs hardcoded** (whisper, voz alvo, spleeter).

Migração normativa:

1. `ModelManager(String modelsRoot, Tools tools, {ModelCatalog? catalog})`, com default `ModelCatalog.windows()`.
2. `static get manifest => ModelCatalog.windows().entries` **permanece** como compatibilidade — os 31 testes existentes continuam valendo sem reescrita.
3. `ModelEntry` **não** ganha campo de plataforma: os catálogos é que são por plataforma, e os IDs não colidem (`whisper-small-q5_1` × `whisper-android-tiny`).
4. O estágio `prepare` para de usar IDs hardcoded e pergunta ao catálogo: `catalog.asrModelIds[preset]`, `catalog.defaultVoiceIds[lang]`.
5. A tela de modelos itera `catalog.entries`, não `ModelManager.manifest`.

### 6.1 IDs reservados do Android M1

| ID | Uso | Preset |
|---|---|---|
| `whisper-android-tiny` | Whisper ONNX multilíngue | rápido |
| `whisper-android-base` | Whisper ONNX multilíngue | melhor |
| `silero-vad` | segmentação de fala para o ASR (§8/P3) | ambos |
| IDs Piper existentes | TTS | ambos |
| `mt-tiny-enpt`, `mt-tiny-pten`, `mt-tiny-enes`, `mt-tiny-esen` | MT (ver §10) | ambos |

Os nomes exatos dos arquivos ONNX, tokens e URLs devem ser preenchidos no relatório AT-2 a partir do release oficial sherpa-onnx. Não inferir nomes.

O **`silero-vad` não existe no manifest atual** e precisa de entrada nova com URL, SHA-256 e licença.

### 6.1.1 Distribuição dos assets — espelho próprio (D-c)

Os assets do sherpa e as vozes Piper são publicados como **`.tar.bz2`**, e hoje são extraídos com o `tar` do Windows (`model_manager.dart:721`, `tar -xjf`), que não existe no Android. O `BZip2Decoder` do `package:archive` é Dart puro e lento demais para dezenas de MB num celular.

Portanto, **todo asset do catálogo Android é espelhado como `.tar.gz` num GitHub Release do próprio repositório**, com SHA-256 fixado:

- um `tool/mirror_models.dart` baixa o asset upstream, reempacota em `.tar.gz`, calcula o SHA-256 e **emite a entrada correspondente do `ModelCatalog.android()`**;
- o `ArchiveExtractor` do Android só precisa lidar com **gzip** (`GZipDecoder`, ordens de grandeza mais rápido);
- as licenças e atribuições de cada asset espelhado vão para os notices da §16.3;
- **SHA-256 é obrigatório em toda entrada nova.** As 64 entradas desktop legadas seguem sem hash — hoje `entry.sha256` é `null` em todas elas, e `_verifyAndWriteSha256` (`model_manager.dart:744-758`) *calcula* o hash mas **nunca compara**, funcionando apenas como marcador de "download concluído". A regra #4 não deve ser lida como já cumprida.

### 6.2 Localização dos dados

| Conteúdo | Local Android | Persistência |
|---|---|---|
| modelos | application support directory | até desinstalação/remoção manual |
| configurações | application support directory | até desinstalação |
| workdir de job | app-specific external files | até sucesso ou limpeza explícita |
| input importado | dentro do workdir | removido após sucesso/exportação |
| output intermediário | dentro do workdir | removido após exportação |
| vídeo final/SRT | URI escolhida pelo usuário | persistente fora do app |

Não usar cache para arquivos necessários à retomada: o sistema pode remover cache sob pressão de armazenamento.

## 7. Refatoração obrigatória de memória e portabilidade

Esta fase deve ser implementada e testada no Windows antes de adicionar backends Android.

### 7.1 Síntese em duas passagens, baseada em disco

Passagem 1:

1. sintetizar um segmento a 1x;
2. gravar `seg_<id>_natural.wav` imediatamente;
3. registrar sample rate, sample count e duração;
4. liberar o `Float32List` antes do próximo segmento;
5. depois de todos os segmentos, calcular `planDubSchedule` usando somente as durações.

Passagem 2:

1. ler/sintetizar apenas o segmento atual;
2. aplicar velocidade, `atempo`, pitch e resample;
3. gravar `seg_<id>_fit.wav` PCM16 mono 44,1 kHz;
4. preencher `fittedAudioPath`, `fittedSampleRate=44100` e `fittedSampleCount`;
5. liberar buffers;
6. persistir `segments.json` a cada segmento concluído, de forma atômica.

### 7.2 Construção sequencial de `dub_voice.wav`

O scheduler atual não permite sobreposição: cada `placedStart` é maior ou igual ao fim da fala anterior. Aproveitar essa invariável.

Algoritmo:

1. abrir arquivo temporário `dub_voice.wav.part`;
2. escrever header WAV PCM16 mono 44,1 kHz com tamanhos provisórios;
3. manter `cursorSamples`;
4. para cada segmento ordenado por `placedStart`:
   - calcular `startSamples`;
   - se `startSamples < cursorSamples`, lançar erro de invariável;
   - escrever zeros PCM16 para a lacuna;
   - copiar os frames PCM16 de `fittedAudioPath` sem convertê-los para float;
   - avançar cursor;
5. completar silêncio até `videoDurationSec` (ver 7.4);
6. atualizar tamanhos RIFF/data no header;
7. fechar, validar e renomear `.part` para `dub_voice.wav`.

O teste deve demonstrar que o pico de memória não cresce proporcionalmente a 5, 30 ou 60 minutos de saída.

O writer é **mais estrito** que o `buildDubTrack` atual, que tolera sobreposição somando aditivamente (`mixer.dart:32`). A invariável mora no fitter (`fitter.dart:198-207`: `placementSec = max(segStart, cursorSec)`, encadeado em `pipeline.dart:270-278`), não no `planDubSchedule`. Isso é bom, mas é mudança de contrato e exige o teste dedicado já previsto na §19.1 ("writer rejeita overlap").

### 7.3 Leitura WAV por janela

Adicionar uma API que leia apenas um intervalo PCM:

```dart
class WavReader implements Finalizable {
  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int frameCount;

  Float32List readFrames(int startFrame, int frameCount);
  void close();
}
```

- `readWav` permanece apenas para arquivos curtos e testes.
- Código novo deve usar `WavReader` para ASR, trim e análises longas.
- Cada janela de ASR no Android é delimitada por VAD (§8/P3) e limitada a 25 segundos.

Hoje o `asr_in.wav` é lido **inteiro e duas vezes por job** (`whisper_transcriber.dart:62` e `pipeline.dart:213`).

### 7.4 A cauda da última fala — decisão D-b

**Contradição herdada do desktop.** O `buildDubTrack` estende deliberadamente o buffer para não cortar a última fala (`mixer.dart:16-24`, com comentário explícito), e o mix final descarta isso com `amix=inputs=2:duration=first` (`mixer.dart:61` e `:78`), onde `first` é o **áudio original**, que tem exatamente a duração do vídeo. As duas funções do mesmo arquivo se contradizem: a cauda é truncada, sem erro e sem warning. Não há `-shortest`, não há `apad`, não há `-t`, e nenhum teste cobre o caso.

**Decisão:** a saída **mantém a duração exata do vídeo**. Para não truncar fala:

1. `planDubSchedule` passa a receber `videoDurationSec` e a tratar o fim do vídeo como **deadline do último run** — a mesma mecânica de deadline que já existe para `maxDubDriftSeconds` (`fitter.dart:80-92`);
2. o(s) run(s) que ultrapassariam o fim do vídeo podem usar um **teto de emergência dedicado** (`tailSpeedMax`), acima do `maxTotalSpeed = 1.5` / `atempoMax = 1.25` normais;
3. o que ainda assim exceder é cortado, mas **medido e reportado**: `DubbingSegment.overflow` (hoje declarado em `models.dart:96` e **nunca escrito**) e `DubbingResult.segmentsWithOverflow` (idem) passam a ser preenchidos, mais um `truncatedTailMs` no resultado;
4. `amix=duration=first` **permanece** — agora coerente com o resto do pipeline;
5. o writer sequencial escreve exatamente `videoDurationSec` e não estende o buffer.

Constante nova: `tailTruncationCapMs` — o teto de corte tolerado no aceite (§19.4). Acima dele, o job reporta falha de qualidade, não sucesso silencioso.

Esta correção vale **também para o desktop** e é feita na fase D1, antes de existir Android — ver `especificacao-tecnica.md`, regra #4 e §P8.

## 8. Pipeline Android M1, estágio por estágio

### A0 — Importação

1. UI abre `ACTION_OPEN_DOCUMENT` com MIME `video/*`.
2. Kotlin recebe `content://` e consulta nome/tamanho quando disponíveis.
3. Criar job ID UUID v4 e workdir.
4. Copiar a URI para `input.<ext>.part`, mostrando progresso.
5. Verificar espaço antes e durante a cópia.
6. Sincronizar/fechar e renomear para `input.<ext>`.
7. Criar `job.json` com status `imported`.

### P1 — Probe e demux

- Rodar ffprobe pelo `MediaToolRunner` para duração, streams e container.
- Demuxar:
  - `audio_full.wav`: PCM16 estéreo 44,1 kHz;
  - `asr_in.wav`: PCM16 mono 16 kHz.
- Validar header, duração positiva e tamanho maior que 44 bytes.
- Não gerar uma segunda cópia para diarização no M1.

### P2 — Separação

- O `Separator` do `AndroidRuntime` retorna `SeparationOutcome.failure(SeparationFailureReason.notSupportedOnPlatform)` (§5.9).
- Isso é comportamento esperado, não erro nem warning técnico: o evento sai com `isWarning: false`.
- UI deve explicar “modo voice-over: o áudio original permanece baixo sob a dublagem”.
- Hoje `pipeline.dart:125-133` emite **warning** nesse caso; isso muda junto com o reason code.

### P3 — Transcrição

**O risco central do port, e ele é de sincronia, não de qualidade de texto.**

No desktop, o `whisper-cli` roda com `-ml 1 -sow` (`whisper_transcriber.dart:34-45`) — ou seja, **um `TranscriptSegment` por palavra**, com timestamps do próprio modelo. O `OfflineRecognizer` do sherpa **não devolve timestamps para modelos Whisper**. Portanto o Android não tem como reproduzir a granularidade de palavra, e a fronteira temporal passa a vir de onde a janela foi cortada. Como o critério de release da §19.4 exige ≥90% dos segmentos dentro de ±300 ms, a escolha do segmentador **é** a decisão de sincronia.

**Segmentação por VAD, não por janela fixa:**

- `SherpaWhisperTranscriber` abre `asr_in.wav` por `WavReader` (nunca inteiro em RAM).
- Usar o **Silero VAD** do próprio pacote `sherpa_onnx` (`VoiceActivityDetector`) para produzir *runs* de fala. As fronteiras do run passam a ser as fronteiras do segmento — e elas são fronteiras **reais de fala**, não de janela.
- Cada run é transcrito isoladamente pelo `OfflineRecognizer`. Run maior que 25 s é dividido no maior silêncio interno.
- Converter os offsets do run em timestamps absolutos.
- Remover segmentos vazios e garantir `end > start`.
- Ordenar e rejeitar regressões de timestamp maiores que 50 ms.
- Gravar `transcript.json` no formato interno, não no formato do whisper-cli.

**O fallback "janelas de 30 s com overlap de 1 s e deduplicar tokens no overlap" está removido desta especificação.** Deduplicação de texto em overlap de ASR é um problema notoriamente difícil (repetição parcial, corte no meio de palavra, alucinação de borda do Whisper) e a spec não tem como fornecer o algoritmo. O VAD elimina a necessidade dele. O `silero-vad` é uma entrada nova e obrigatória do catálogo (§6.1).

### P4 — Segmentação

- Reusar `buildDubbingSegments` e constantes desktop.
- `speech_trim` deve ler apenas as janelas necessárias de `asr_in.wav`.
- Gravar `segments.json` com texto fonte, timestamps e speaker `0`.

**Correção obrigatória no `buildDubbingSegments` (vale para as duas plataformas).** Hoje o segmentador funde as unidades e, ao dividir por pontuação, reparte a duração **proporcionalmente ao número de caracteres** (`segmenter.dart:38-47`) — jogando fora os timestamps finos que o whisper-cli tinha entregue. Isso é uma perda de sincronia que já existe no desktop e que ficaria pior no Android. Passa a valer:

1. cada unidade mesclada guarda os `TranscriptSegment` que a compõem;
2. ao dividir por pontuação, o corte vai na **fronteira real** entre esses constituintes (exato no desktop, onde eles são palavras);
3. quando não houver fronteira fina (caso Android, em que o constituinte é o run inteiro do VAD), fazer *snap* do ponto estimado para o **vale de energia mais próximo** dentro de ±500 ms, reusando a janela RMS de 20 ms / hop 10 ms de `speech_trim.dart:66-113`.

O `trimDubbingSegmentsToSpeech` (`speech_trim.dart:51`) continua reancorando as fronteiras da unidade na energia real — ele corrige o erro *da borda*, mas não corrige um corte errado *no meio*; por isso os três itens acima são necessários.

### P5 — Tradução

- Chamar `translator.ensureReady(from,to)`.
- Traduzir em lotes pequenos, limitados a 32 frases ou 4.096 caracteres por lote.
- Para pt↔es, seguir `translationPath` via inglês e persistir o texto pivô apenas no checkpoint para diagnóstico.
- Aplicar transliteração sérvia somente nos idiomas futuros já previstos pelo catálogo; M1 usa en/pt/es.
- Nunca substituir silenciosamente tradução vazia pelo texto original: registrar warning por segmento e apresentar contagem no resultado.

### P6/P7 — TTS e ajuste

- Usar uma única voz escolhida pelo usuário ou a voz padrão do idioma.
- Executar as duas passagens da seção 7.1.
- Cada fitted deve terminar em PCM16 mono 44,1 kHz.
- O agendamento aperta o último run para caber no fim do vídeo (§7.4); o corte residual é medido e reportado, nunca silencioso.
- Gravar `sync_report.json` (§8/P9) durante o `fit`, um registro por segmento.

### P8 — Voice-over e mix

- Montar `dub_voice.wav` pelo writer sequencial.
- Aplicar no FFmpegKitNext o filtro já usado no desktop:

```text
[0:a][1:a]sidechaincompress=threshold=0.02:ratio=12:attack=20:release=400[bg];
[bg][1:a]amix=inputs=2:duration=first:normalize=0,
loudnorm=I=-16:TP=-1.5:LRA=11[out]
```

- Saída: `dubbed.wav`, PCM16 estéreo 44,1 kHz, **com a duração exata do vídeo** (§7.4).
- O `duration=first` é intencional: o input 0 é o áudio original, que define a duração da saída. Isso só é correto porque o §7.4 garante que a dublagem já foi agendada para caber.

### P9 — Mux, SRT e relatório de sincronia

- Copiar o stream de vídeo sem reencodar.
- Gerar áudio AAC 192 kbps.
- Incluir áudio dublado como faixa padrão e original como faixa secundária quando o container permitir.
- Se o container original não aceitar a combinação, produzir MP4.
- Gerar SRT de origem e destino no workdir.
- Gravar checkpoint `completedPendingExport`.

**`sync_report.json` — o critério de sincronia vira um número, medido pelo próprio pipeline.**

O critério da §19.4 ("≥90% dos segmentos dentro de ±300 ms") era verificado à mão, por amostragem no player, e só na fase final. Isso significa descobrir na D4 que a sincronia não fecha — depois de todo o pipeline pronto. O engine passa a gravar, por job:

```json
{
  "schemaVersion": 1,
  "videoDurationMs": 300000,
  "truncatedTailMs": 0,
  "segments": [
    { "id": 0, "origStartMs": 1240, "placedStartMs": 1240, "deltaMs": 0,
      "speedUsed": 1.0, "atempoUsed": 1.0, "overflowMs": 0, "truncatedMs": 0 }
  ]
}
```

`tool/sync_report.dart` lê o arquivo e imprime o percentual dentro de ±300 ms, o pior delta e o total truncado. É gerado igual nas duas plataformas: o **baseline é medido no Windows já na fase D1** e o Android é comparado contra ele, em vez de contra uma impressão auditiva.

### A10 — Exportação

1. solicitar destino do vídeo por `ACTION_CREATE_DOCUMENT`;
2. copiar o vídeo final para a URI;
3. solicitar ou criar destinos dos SRTs;
4. validar quantidade de bytes escritos;
5. marcar `exported`;
6. só então remover intermediários.

Se o usuário cancelar a escolha do destino, manter o job em `completedPendingExport` e permitir exportar depois sem reprocessar.

## 9. Checkpoints e retomada

### 9.1 Estados normativos

```text
created
  -> importing
  -> imported
  -> demuxed
  -> transcribed
  -> segmented
  -> translated
  -> synthesized
  -> fitted
  -> mixed
  -> completedPendingExport
  -> exported
```

Estados terminais adicionais: `cancelled` e `failed`.

### 9.2 Escrita atômica

Para JSON ou arquivo final:

1. escrever `<nome>.part`;
2. fechar e flush;
3. validar parse/tamanho;
4. substituir `<nome>` por rename no mesmo volume.

Nunca considerar um `.part` como etapa concluída.

### 9.3 Estrutura mínima de `job.json`

```json
{
  "schemaVersion": 1,
  "jobId": "uuid",
  "state": "translated",
  "sourceLang": "en",
  "targetLang": "pt",
  "preset": "fast",
  "voiceModelId": "piper-pt-br",
  "voiceSid": 0,
  "inputPath": ".../input.mp4",
  "inputSize": 123456,
  "inputLastModified": 0,
  "videoDurationMs": 300000,
  "progress": 0.55,
  "createdAt": "ISO-8601 UTC",
  "updatedAt": "ISO-8601 UTC",
  "warnings": [],
  "lastError": null
}
```

### 9.4 Política de retomada

- Ao iniciar serviço, procurar jobs não terminais.
- Validar o output esperado do estado salvo.
- Se válido, começar no estágio seguinte.
- Se inválido, recuar até o último checkpoint válido.
- Não reutilizar resultado se config, input size ou versão do schema divergirem.
- Após upgrade incompatível do schema, preservar arquivos e pedir para reiniciar o job; não apagar automaticamente.

## 10. Tradução Android — gate AT-1

Tradução é o maior bloqueio de produto porque português é obrigatório.

### 10.1 Evidência existente

O spike SA1 comprovou no moto g86 que slimt compilado para arm64:

- carrega modelos Bergamot tiny;
- preserva UTF-8 latino e cirílico;
- traduz cinco frases incluindo carga em aproximadamente 180 ms;
- gera `libslimt.so` stripped de aproximadamente 3 MB.

O mesmo spike observou que os modelos desktop `en-pt-base` e `pt-en-base` são `base-memory` e que o slimt não os carregou.

**Correção de premissa (2026-07-12).** Aquilo **não era erro de configuração**: o slimt só implementa a arquitetura `tiny` (decoder SSRU). O README do projeto diz textualmente *"Eventual support for `base` models are planned"*. Não existe combinação de hiperparâmetros que faça o slimt carregar um `base-memory` — os passos de "inspecionar a arquitetura" e "rodar com todos os hiperparâmetros corretos", que constavam desta seção, eram um beco sem saída e foram removidos.

E a conclusão de produto que se tirou do SA1 ("português está bloqueado") também estava errada: ela era artefato de olhar só para os modelos **já instalados na máquina do desktop**. Existe pt no tier `tiny` — o mesmo que o SA1 já provou que o slimt carrega.

### 10.1.1 Fonte dos modelos — passos 1–2 EXECUTADOS (2026-07-12)

Relatório completo: [spikes-android/AT1.md](spikes-android/AT1.md).

**O repositório `mozilla/firefox-translations-models` NÃO serve para download.** Os modelos estão em Git LFS e os objetos **foram removidos do servidor** (`410 Object does not exist`); o `raw.githubusercontent` devolve um ponteiro de 132 bytes. Arquivar um repositório preserva o histórico, não o armazenamento LFS. O que ele ainda serve, e é útil, são os `metadata.json` (fora do LFS).

**A fonte é o Remote Settings do Firefox**, que distribui exatamente os mesmos arquivos:

```
índice:  https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/translations-models/records
CDN:     https://firefox-settings-attachments.cdn.mozilla.net/<attachment.location>
```

Cada registro traz `fromLang`, `toLang`, `fileType` (`model`|`vocab`|`lex`), `version` e um `attachment` com `location`, `size` e `hash` (SHA-256) — ou seja, a §16.3 é atendida direto pela API.

| `version` | Arquitetura | Modelo |
|---|---|---|
| **`1.0`** | **`tiny`** — `dec-cell: ssru`, `dec-depth: 2`, `enc-depth: 6`, `dim-emb: 256` | 17.140.899 B |
| `2.0`/`2.1` | `base-memory` | 31.561.787 B |

Não é inferência por tamanho: o `hash` declarado no `metadata.json` de `models/tiny/enpt` é **idêntico** ao `attachment.hash` do registro v1.0. Download verificado ponta a ponta (HTTP 200, SHA-256 confere).

⚠ Os `location` são **UUIDs por versão**. Fixar `location` **e** `hash` juntos no catálogo, e validar o hash após baixar.

### 10.1.2 Qualidade tiny × base — medida, não estimada

Os `metadata.json` publicam BLEU e COMET no FLORES:

| Par | tiny BLEU | base BLEU | Δ | tiny COMET | base COMET |
|---|---:|---:|---:|---:|---:|
| **en→pt** (gate) | **49,4** | 50,0 | **−0,6** | 0,8895 | 0,8910 |
| **pt→en** (gate) | **47,8** | 47,9 | **−0,1** | 0,8866 | 0,8887 |
| en→es | 25,9 | 27,7 | −1,8 | 0,8414 | 0,8527 |
| es→en | 27,5 | 27,5 | 0,0 | 0,8513 | 0,8568 |

Nos pares de gate a perda é **ruído**. A divergência de qualidade desktop×Android da decisão D-a, portanto, existe no papel e é irrelevante na prática.

### 10.2 Ordem obrigatória do AT-1

1. ~~localizar fonte pública e licença~~ — **FEITO** (§10.1.1): Remote Settings, MPL-2.0;
2. ~~registrar URL, SHA-256, arquivos e atribuição~~ — **FEITO** (`spikes-android/AT1.md` §4);
3. **versionar o build do slimt neste repositório** — o `libslimt.so` do SA1 foi produzido no protótipo irmão e **não existe mais**. Transformar os patches (PCRE2, `-Werror`) num script versionado, como o próprio SA1 §5 já exigia. Conferir o alinhamento de 16 KB da `.so` gerada (NDK ≥ r27 alinha por padrão);
4. **criar e versionar a suíte fixa de 100 frases** por direção — ela ainda não existe;
5. executar as 100 frases/direção em en→pt e pt→en no moto g86;
6. aplicar o critério de decisão do §10.4;
7. expor a C-API mínima do §10.3 sobre o backend aprovado.

**Só se o §10.4 reprovar** é que se compila o `bergamot-translator` completo via NDK arm64 — com **time-box de 5 dias úteis**, critério de desistência explícito e registro em `docs/decisoes.md`. Antes desta revisão esse fallback era o caminho previsto e não tinha estimativa; agora ele é a exceção, e os números da §10.1.2 tornam-no improvável.

**Subproduto para o desktop.** O `model.enpt.intgemm.alphas.bin` instalado em `%LOCALAPPDATA%\translateLocally\` é **bit a bit idêntico** ao registro v2.1 do Remote Settings. Encerra o risco aberto em `decisoes.md` de que uma instalação limpa não consiga mais baixar `en-pt-base`.

### 10.3 C-API mínima

```c
typedef void* OtTranslatorHandle;

OtTranslatorHandle ot_translator_create(
    const char* config_path,
    char** error_utf8);

char* ot_translator_translate(
    OtTranslatorHandle handle,
    const char* source_utf8,
    char** error_utf8);

void ot_string_free(char* value);
void ot_translator_free(OtTranslatorHandle handle);
```

- Nunca lançar exceção C++ através da fronteira C.
- Toda falha deve retornar null e preencher `error_utf8`.
- Strings são UTF-8 e liberadas exclusivamente por `ot_string_free`.
- Um handle é usado em um isolate por vez.

### 10.4 Critério de decisão automático

Slimt é escolhido somente se **en→pt e pt→en** cumprirem todos os critérios:

- 100/100 frases retornam texto UTF-8 não vazio;
- zero crash, segfault ou repetição degenerada;
- qualidade humana classificada aceitável em pelo menos 90 frases por direção;
- mediana ≤ 300 ms/frase após carga no moto g86;
- pico RSS do processo durante o teste ≤ 500 MB.

**en↔es e os pivôs pt↔es são medição informativa, não gate** — en↔es tiny já é o que o desktop usa em produção hoje, então reprová-lo aqui reprovaria o produto atual. O formulário `aceite-android.md` §4 pede as 6 direções: as 4 linhas de pivô/es são registro, e só en→pt e pt→en decidem.

Se qualquer critério de gate falhar, usar bergamot-translator completo (time-box do §10.2). Não criar um terceiro backend no M1.

## 11. ASR Android — gate AT-2

### 11.1 Backend

- pacote `sherpa_onnx` fixado inicialmente em `1.13.4`;
- `OfflineRecognizer` com Whisper ONNX multilíngue;
- **`VoiceActivityDetector` (Silero VAD) do mesmo pacote como segmentador** (§8/P3);
- tiny para preset rápido;
- base para preset melhor;
- `numThreads = max(2, min(4, processors - 2))`;
- provider `cpu` no M1.

O `OfflineRecognizer` com Whisper **não devolve timestamps**. Essa é a razão de o VAD ser obrigatório e não "preferencial": ele é a única fonte de fronteira temporal do Android.

### 11.2 Saída esperada

O backend retorna `List<TranscriptSegment>` com:

- timestamp absoluto;
- texto sem tokens especiais;
- idioma forçado pela configuração do job;
- segmentos ordenados;
- nenhum `end <= start`.

### 11.3 Aceite AT-2

- executar uma amostra real de 5 min em en, pt e es;
- tempo de transcrição < duração do áudio em cada preset no moto g86;
- pico total do app < 1,5 GB;
- timestamps não regressivos;
- nenhuma janela perdida na fronteira;
- **sincronia:** transcrever o **mesmo clipe** com whisper-cli (desktop) e com sherpa+VAD (device), rodar os dois pelo mesmo `buildDubbingSegments` e comparar o `sync_report.json` das duas execuções. **≥90% dos segmentos dentro de ±300 ms do baseline desktop.**

O último item era, antes desta revisão, "diferença perceptual contra whisper-cli documentada e aceitável" — formulação vaga demais para um gate. Mas é justamente o critério de release da §19.4. Do jeito antigo, era possível aprovar o AT-2, construir o pipeline inteiro e só descobrir na fase D4 que a sincronia não fecha. Medir aqui custa uma tarde e responde a pergunta antes de existir pipeline.

Os nomes exatos dos assets sherpa e o código de configuração aprovado devem ser anexados ao relatório `docs/spikes-android/AT2.md` antes de integrar o pipeline.

### 11.4 Aceite AT-2b — TTS Piper no device

O TTS **não tinha gate**: era assumido de graça por vir do mesmo pacote `sherpa_onnx`. É um backend inteiro no caminho crítico, com consumo de memória próprio (`OfflineTts` carregando um VITS) e dependência da extração de modelos. A premissa é provavelmente verdadeira — o `piper_synthesizer.dart` já roda **in-process via FFI** no desktop, então o código é praticamente o mesmo —, mas premissa não testada não é gate.

- sintetizar 20 frases por idioma (en/pt/es) com a voz padrão, no moto g86;
- RTF < 0,3;
- pico de memória do `OfflineTts` registrado;
- saída reamostrada para PCM16 mono 44,1 kHz e reaberta com sucesso;
- tempo de extração do `.tar.gz` da voz medido no device (§6.1.1);
- cancelamento entre segmentos encerra a síntese sem sessão órfã.

Registrar em `docs/spikes-android/AT2.md`, seção própria.

## 12. FFmpegKitNext — gate AT-3

### 12.1 Fonte e build

- usar tag `8.1.0` do repositório oficial `arthenica/ffmpeg-kit-next`;
- registrar o commit resolvido no relatório AT-3 e em `docs/decisoes.md`;
- build reproduzível via Nix em Linux/CI ou WSL2;
- variante LGPL, sem `--enable-gpl`;
- release somente `arm64-v8a`;
- `x86_64` permitido apenas no artifact de debug;
- guardar scripts de build no repositório, não o checkout inteiro do upstream.

### 12.2 Matriz de comandos obrigatória

| Caso | Recurso que deve existir |
|---|---|
| probe | ffprobe JSON |
| demux | PCM16, `-ac`, `-ar` |
| ajuste | `atempo` |
| voz infantil futura | `asetrate`, `aresample` |
| mix | `amix` |
| ducking | `sidechaincompress` |
| loudness | `loudnorm` |
| divisão/união | segment muxer e concat demuxer |
| saída | encoder AAC nativo |
| vídeo | `-c:v copy` |

### 12.3 Adaptação de progresso e cancelamento

- criar uma sessão assíncrona por comando;
- converter statistics time para progresso quando a duração total for conhecida;
- ao cancelar, solicitar cancelamento da sessão e aguardar término;
- mapear return code, logs finais e últimos 50 lines para `ToolResult`;
- timeout cancela a sessão e retorna resultado distinguível de erro normal.

### 12.4 Aceite AT-3

Executar no aparelho cada comando real do pipeline, não apenas `-version`. Cada output deve ser reaberto e validado. O relatório deve incluir configuração FFmpeg, tamanho das `.so`, licenças habilitadas e prova de ausência de `--enable-gpl`.

## 13. Casca Android

### 13.1 Projeto e identidade

- executar futuramente `flutter create --platforms=android .` dentro de `app/`, preservando `lib/`;
- `applicationId`: `com.luistiagos.omnitranslator`;
- `minSdk = 28`;
- `targetSdk`: valor estável exigido pela versão Flutter/Play no momento da implementação, nunca menor que 35;
- Java/Kotlin 17;
- namespace igual ao applicationId.

### 13.2 ABI

- release/AAB: `arm64-v8a`;
- debug: `arm64-v8a` e `x86_64`;
- não incluir quatro cópias do sherpa/ONNX/FFmpeg em APK universal de release;
- Google Play recebe AAB e gera split por ABI;
- APK direto é arm64 e assinado.

### 13.3 Permissões

Manifest mínimo do M1:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROCESSING" />
```

Não solicitar `MANAGE_EXTERNAL_STORAGE`, `READ_MEDIA_VIDEO` ou permissões legadas de escrita apenas para o fluxo SAF.

## 14. Foreground service e protocolo com Flutter

### 14.1 Decisão

Usar um foreground service Android direto do tipo `mediaProcessing`. Não usar WorkManager para o pipeline longo. WorkManager pode ser usado futuramente apenas para limpeza curta ou manutenção não crítica.

### 14.2 Componentes

- `MediaProcessingService` Kotlin;
- FlutterEngine headless pertencente ao serviço, não à Activity;
- isolate Dart do job iniciado pelo entrypoint registrado;
- Activity liga/desliga do serviço e observa estado persistido;
- MethodChannel para comandos de ciclo de vida;
- EventChannel para progresso ao vivo, sem ser fonte única de verdade.

### 14.3 Comandos

```text
startJob(jobId)
cancelJob(jobId)
getJob(jobId)
listRecoverableJobs()
exportJob(jobId)
```

### 14.4 Eventos

```text
jobStateChanged
jobProgress
jobWarning
jobCompleted
jobFailed
```

Cada evento inclui `jobId` e `updatedAt`. A UI deve recarregar `job.json` quando perder eventos.

### 14.5 Notificação

- canal: “Processamento de vídeo”;
- título com nome do arquivo;
- estágio e percentual;
- ação Cancelar;
- toque abre o job;
- iniciar foreground dentro do prazo exigido pelo Android;
- chamar `stopForeground` e `stopSelf` em sucesso, falha ou cancelamento;
- implementar tratamento de timeout disponível no nível de API atual.

### 14.6 Aceite de ciclo de vida

Um job de 30 min deve continuar quando:

- tela apaga;
- usuário troca de app;
- Activity sofre rotação/recriação;
- Activity é removida da memória, mantendo o serviço;
- UI é reaberta e reconecta ao estado persistido.

Morte forçada do processo deve permitir retomada pelo último checkpoint, não continuidade instantânea.

## 15. Armazenamento e espaço livre

### 15.1 Fórmula de reserva

Antes de importar, calcular:

```text
requiredBytes =
  2 * inputSizeBytes
  + round(500_000 * durationSeconds)
  + 1 GiB
```

Se duração ainda não for conhecida, reservar `max(2 GiB, 4 * inputSizeBytes)` para importação e recalcular após ffprobe.

### 15.2 Falta de espaço

- impedir início quando `freeBytes < requiredBytes`;
- exibir necessário e disponível em GB;
- verificar novamente antes de demux, mix e mux;
- preservar checkpoints válidos em falha de espaço;
- oferecer excluir job, não apagar automaticamente outros jobs.

### 15.3 Limpeza

- sucesso exportado: apagar workdir;
- sucesso ainda não exportado: preservar;
- cancelado/falhou: preservar por sete dias para diagnóstico/retomada;
- startup: listar jobs expirados e pedir confirmação antes da primeira limpeza destrutiva;
- modelos nunca entram na limpeza de workdir.

## 16. Compatibilidade nativa, segurança e licenças

### 16.1 Página de 16 KB — gate AT-0, antes de qualquer outro spike

Todas as `.so` próprias e de terceiros devem suportar páginas de 16 KB. O `targetSdk ≥ 35` da §13.1 coloca o app na faixa em que o Google Play **exige** suporte a 16 KB (desde novembro de 2025), e um device de 16 KB simplesmente **não carrega** uma `.so` alinhada a 4 KB — não é só política de loja.

**O `zipalign` sozinho não basta.** `zipalign -c -P 16` verifica se as `.so` estão alinhadas *dentro do zip*; ele **não** verifica o alinhamento do segmento `LOAD` do próprio ELF. Um APK pode passar no `zipalign` e ainda assim falhar ao carregar. Validação completa:

```text
zipalign -c -P 16 -v 4 app-release.apk        # necessário, insuficiente
llvm-readelf -l <cada .so>                    # exigir "align 2**14" em todos os LOAD
```

Mais `android.bundle.enableUncompressedNativeLibs` / `useLegacyPackaging=false` no Gradle, e execução num emulador Android 15+ configurado para 16 KB, carregando de fato sherpa, ONNX Runtime, backend de tradução e FFmpegKitNext.

**Gate AT-0 — EXECUTADO em 2026-07-12, PASSOU.** Relatório: [spikes-android/AT0.md](spikes-android/AT0.md).

As três `.so` arm64 do `sherpa_onnx_android_arm64` 1.13.4 têm **todos** os segmentos `LOAD` com `align 0x4000` (16 KB), e o ONNX Runtime embutido é **1.27.0**. A issue [k2-fsa/sherpa-onnx#3291](https://github.com/k2-fsa/sherpa-onnx/issues/3291) (mar/2026), que reportava ORT 1.17.1 sem alinhamento, está obsoleta em dois níveis: a versão subiu, e a lib de que ela reclama (`libonnxruntime4j_jni.so`) é o binding **Java** — o pacote Dart usa a C API e não empacota nenhuma lib `*4j*`.

**Portanto o remédio caro — compilar sherpa-onnx + ONNX Runtime do fonte com `-Wl,-z,max-page-size=16384` — não é necessário.** Era o único risco do marco sem plano de contingência orçado.

Restam duas confirmações de runtime, que dependem de `app/android/` existir e portanto entram na fase D3, **sem bloquear nada**: o `zipalign -c -P 16` do APK (controlado pela nossa config Gradle, não por terceiros) e o carregamento num emulador 16 KB. E duas `.so` que ainda vamos compilar nós mesmos: `libslimt.so` (AT-1 — o NDK ≥ r27 já alinha por padrão, conferir no rebuild) e FFmpegKitNext (AT-3 — passar a flag explicitamente).

### 16.2 Inventário obrigatório de nativos — script local, não CI

Não existe CI neste repositório e não será criada uma (decisão D-d em `docs/decisoes.md`). O inventário vira um script local, rodado à mão nos gates:

- `tool/check_native_libs.dart` — lista todas as `.so` do APK/AAB por ABI, tamanho, hash e origem; **falha** se aparecer ABI não autorizada ou lib sem entrada no inventário; roda o `llvm-readelf -l` da §16.1 em cada uma.
- `tool/verify.ps1` — `dart analyze` + `dart test` no engine (conta os testes e falha se regredir dos 199) + `flutter analyze`.

Sem CI, "os 199 testes passam" é uma afirmação de documento, não uma barreira. Os dois scripts são o que a torna verificável.

### 16.3 Licenças

Tela “Sobre” e arquivo de notices devem cobrir:

- sherpa-onnx e ONNX Runtime;
- Whisper/modelos;
- Piper e o model card de cada voz;
- slimt ou bergamot-translator;
- modelos de tradução e suas atribuições;
- FFmpegKitNext/FFmpeg e configuração de build;
- pacotes Dart usados para arquivo/armazenamento.

Nenhum modelo **novo** pode entrar no manifest de produção sem URL, SHA-256, licença e texto de atribuição. Isso vale para as entradas do Android (Whisper ONNX, Silero VAD, vozes Piper espelhadas, modelos de tradução).

As **64 entradas desktop legadas seguem sem hash**, por decisão registrada. Não ler a regra #4 ("modelos validados por SHA-256") como um fato já verdadeiro: hoje `entry.sha256` é `null` em todas as 64 entradas, e `_verifyAndWriteSha256` (`model_manager.dart:744-758`) *calcula* o hash e grava um sentinela `.sha256`, mas **nunca compara nada** — é trust-on-first-use, não verificação.

## 17. Ordem de implementação e gates

### Fase D0 — documentação e baseline

- consolidar esta especificação e SA1 no repositório principal;
- registrar decisões;
- manter os 199 testes atuais passando;
- corrigir warnings Flutter antes de gerar Android, para baseline limpo.

**Gate:** somente documentação alterada e links internos válidos.

### Fase D0.5 — AT-0, o gate de 16 KB ✅ CONCLUÍDA (2026-07-12)

Primeiro item executável do programa, antes de qualquer investimento. Ver §16.1 e [spikes-android/AT0.md](spikes-android/AT0.md).

**Gate: PASSOU.** As `.so` do sherpa/ORT são 16 KB-compatíveis e o ORT é 1.27.0. O remédio caro está descartado. As confirmações de runtime (`zipalign`, emulador) migram para a fase D3.

### Fase D1 — runtime e memória no Windows

- implementar contratos da seção 5 (incluindo `JobCheckpointStore`, `CancellationToken` generalizado e `SeparationOutcome` com reason code);
- criar `DesktopRuntime`;
- migrar testes das factories antigas;
- implementar áudio por segmento e writer sequencial;
- adicionar checkpoints;
- **corrigir a cauda da última fala (§7.4)** — é um bug que existe hoje no desktop;
- **corrigir o split do segmentador (§8/P4)** e gerar o `sync_report.json` (§8/P9);
- migrar `ModelManager` para `ModelCatalog` (§6.0) e `DiskSpaceProbe` para async (§5.4);
- escrever `tool/verify.ps1` (§16.2).

**Gate:** paridade funcional Windows; 199 testes anteriores mais os novos; memória quase constante no teste de 30 min; **`sync_report.json` do desktop registrado como baseline** (é contra ele que o AT-2 vai medir).

### Fase D2 — spikes Android bloqueadores

Executar nesta ordem:

1. AT-1 tradução portuguesa (tiny; ver §10);
2. AT-2 Whisper sherpa + Silero VAD, **com a métrica de ±300 ms**;
3. AT-2b TTS Piper no device (§11.4);
4. AT-3 FFmpegKitNext;
5. AT-4 foreground service + engine headless;
6. AT-5 SAF + import/export + StatFs, incluindo o tempo de extração `.tar.gz`.

**Gate:** todos passam separadamente no moto g86 antes de montar o pipeline completo.

### Fase D3 — integração Android M1

- gerar `app/android`;
- implementar `AndroidRuntime`;
- portar settings/model screen para paths Android;
- ligar importação, pipeline, serviço e exportação;
- adicionar presets e capacidades por plataforma.

**Gate:** fixture curta end-to-end nos três idiomas.

### Fase D4 — aceite e release

- seis direções;
- soak de 30 min;
- API 28 e 35/36;
- 16 KB;
- AAB/APK assinados;
- notices/licenças;
- faixa interna da Play.

**Gate:** todos os itens da seção 19.

## 18. Marcos posteriores

### Android M2 — separação e múltiplos falantes

- binding C/Dart da source separation sherpa;
- chunking limitado por memória;
- diarização e perfis;
- banco de vozes;
- fallback voice-over continua obrigatório.

### Android M3 — YouTube

- spike separado para extração, cookies e mudanças do site;
- não misturar downloader com engine de arquivo;
- input baixado entra pelo mesmo contrato de path local.

### Android M4 — player e tempo real

- player embutido;
- ASR streaming;
- tradução incremental;
- vídeo atrasado e áudio dublado agendado.

### Android M5 — fontes externas

- `AudioPlaybackCapture` Android 10+;
- microfone;
- denoise;
- políticas de privacidade e permissões específicas.

## 19. Plano de testes e aceite do Android M1

Registrar todas as execuções e métricas no formulário [aceite-android.md](aceite-android.md). Um campo vazio equivale a “não testado”.

### 19.1 Unitários do engine

- `DubbingRuntime` encaminha dependências corretas;
- `DesktopRuntime` preserva comandos atuais;
- writer sequencial produz WAV válido com gaps;
- writer rejeita overlap;
- **writer produz WAV com exatamente a duração do vídeo** (§7.4);
- **o último run acelera para caber no fim do vídeo, e o corte residual é reportado** (§7.4);
- fitted por path mantém sincronismo;
- **o split do segmentador cai na fronteira real entre os constituintes, não em proporção de caracteres** (§8/P4);
- **sem fronteira fina, o split faz snap para o vale de energia mais próximo** (§8/P4);
- `sync_report.json` é gerado com um registro por segmento e `deltaMs` correto;
- `SeparationOutcome.notSupportedOnPlatform` produz evento informativo, **não** warning (§5.9);
- `CancellationToken` dispara callbacks que não são `Process` (§5.8);
- YouTube sem `createDownloader` lança `PipelineException`, não `NoSuchMethodError` (§5.1);
- checkpoint atômico ignora `.part`;
- retomada recua diante de output inválido;
- retomada rejeita checkpoint com `configFingerprint` divergente;
- extração rejeita path traversal;
- cálculo de espaço usa a fórmula normativa;
- tradução vazia gera warning, não fallback silencioso.

### 19.2 Spikes no device

- AT-0: 16 KB em todas as `.so`, antes de tudo;
- AT-1: 100 frases/direção e métricas da seção 10;
- AT-2: 5 min por idioma e preset, **mais a métrica de ±300 ms contra o baseline desktop**;
- AT-2b: TTS Piper no device;
- AT-3: matriz completa FFmpeg;
- AT-4: job de 30 min em background;
- AT-5: URI local, Downloads e provedor externo suportado pelo SAF, mais tempo de extração `.tar.gz`.

### 19.3 End-to-end

Executar vídeos reais de aproximadamente 5 min:

| Caso | Origem | Destino |
|---|---|---|
| 1 | en | pt |
| 2 | pt | en |
| 3 | en | es |
| 4 | es | en |
| 5 | pt | es |
| 6 | es | pt |

Para cada caso registrar:

- aparelho/API;
- preset/modelos;
- duração e tamanho de entrada;
- duração total do processamento, sem download;
- pico de memória;
- temperatura/throttling observado;
- quantidade de segmentos;
- percentual dentro de ±300 ms;
- overflows;
- warnings de tradução;
- tamanho e container da saída;
- SRTs válidos;
- resultado auditivo.

### 19.4 Critérios finais mecânicos

Android M1 é aceito somente se:

- 100% das seis direções completarem;
- vídeo final for reproduzível;
- faixa dublada for padrão;
- SRT de origem e destino forem parseáveis;
- o áudio final tiver a duração exata do vídeo e **nenhuma fala for truncada além de `tailTruncationCapMs`**, com todo corte reportado no `sync_report.json` (§7.4 — antes esta linha era "nenhuma fala for truncada", o que o código contradizia e o resto da spec tornava impossível);
- pelo menos 90% dos segmentos estiverem dentro de ±300 ms, **medidos pelo `sync_report.json`** e não por amostragem no player;
- tempo total ≤ 4× duração no moto g86;
- pico de memória < 1,8 GB;
- job de 30 min sobreviver aos cenários da seção 14.6;
- cancelamento parar FFmpeg e inferências sem processo/sessão órfã;
- retomada funcionar após encerramento entre estágios;
- APK/AAB carregarem em ambiente 16 KB;
- inventário não contiver GPL nem ABI inesperada;
- fluxo normal não solicitar permissão ampla de armazenamento.

## 20. Checklist para o implementador

Seguir exatamente esta ordem:

- [ ] Ler esta especificação e `especificacao-tecnica.md`.
- [ ] Rodar baseline de testes e registrar quantidade.
- [x] **Executar AT-0 (16 KB).** ✅ PASSOU em 2026-07-12 — ver `spikes-android/AT0.md`.
- [ ] Implementar interfaces da seção 5 sem Android.
- [ ] Migrar desktop para `DesktopRuntime`.
- [ ] Remover imports concretos do pipeline.
- [ ] Implementar áudio por segmento em disco.
- [ ] Implementar writer sequencial.
- [ ] **Corrigir a cauda da última fala (§7.4).**
- [ ] **Corrigir o split do segmentador e gerar `sync_report.json` (§8/P4, §8/P9).**
- [ ] Migrar `ModelManager` para `ModelCatalog`; `DiskSpaceProbe` para async.
- [ ] Implementar checkpoints e retomada.
- [ ] Reexecutar aceite desktop e **registrar o baseline de sincronia**.
- [ ] Executar AT-1 (tiny primeiro); não avançar sem português.
- [ ] Executar AT-2 e AT-2b.
- [ ] Executar AT-3.
- [ ] Executar AT-4 e AT-5.
- [ ] Gerar `app/android` no app existente.
- [ ] Implementar `AndroidRuntime`.
- [ ] Integrar UI, serviço, SAF e modelos.
- [ ] Executar testes das seis direções.
- [ ] Validar 16 KB, AAB, APK, licenças e notices.
- [ ] Só então marcar Android M1 como concluído.

## 21. Referências oficiais

- sherpa-onnx, plataformas e APIs: <https://github.com/k2-fsa/sherpa-onnx>
- build sherpa para Android: <https://k2-fsa.github.io/sherpa/onnx/android/build-sherpa-onnx.html>
- FFmpegKitNext: <https://github.com/arthenica/ffmpeg-kit-next>
- foreground service `mediaProcessing`: <https://developer.android.com/develop/background-work/services/fgs/service-types>
- WorkManager e jobs longos: <https://developer.android.com/develop/background-work/background-tasks/persistent/how-to/long-running>
- Storage Access Framework: <https://developer.android.com/training/data-storage/shared/documents-files>
- armazenamento Android: <https://developer.android.com/training/data-storage>
- páginas de 16 KB: <https://developer.android.com/guide/practices/page-sizes>
- Android App Bundle: <https://developer.android.com/guide/app-bundle/app-bundle-format>
