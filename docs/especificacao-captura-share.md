# OmniTranslator Android — Especificação M6: captura e compartilhamento (v1)

Data: 2026-07-19. Status: **aprovada para implementação** (decisões de produto fechadas pelo usuário em 2026-07-19, ver §2).

Documento-base: [especificacao-android.md](especificacao-android.md) (spec v2 do port, prevalece em tudo que esta spec não cobrir — regras de ouro do §2, contratos do §5, SAF do §8, foreground service do §14). Progresso registrado em [progresso-android.md](progresso-android.md) §5; decisões novas em [decisoes.md](decisoes.md).

Esta spec foi escrita para ser executada por um agente de implementação **sem contexto prévio do projeto**: cada fase (C1–C5) diz exatamente quais arquivos criar/alterar, com assinaturas, e termina num gate objetivo. Implemente **uma fase por vez, na ordem**, e não avance com um gate reprovado.

---

## 1. Objetivo e escopo

Três capacidades novas no app Android (marco **Android M6**):

- **F1 — Traduzir minha voz**: o usuário grava a própria voz pelo microfone numa tela do app; ao parar, o app roda ASR → tradução → TTS automaticamente e produz um **áudio `.m4a`** com a fala traduzida em voz sintetizada, além de exibir a transcrição e a tradução em texto.
- **F2 — Gravar e dublar vídeo**: o usuário grava um vídeo com **o app de câmera do sistema** (intent); ao voltar, o mp4 entra no pipeline de dublagem existente, sem mudanças de estágio, e sai dublado.
- **F3 — Compartilhar**: tela de resultado (para F1, F2 e também para o fluxo atual de importação) com player de preview e botões de compartilhamento: um botão direto por app (**WhatsApp, Telegram, Facebook, Instagram, TikTok**) + botão "Outros" com o Sharesheet do sistema. O "Salvar em..." (export SAF) continua existindo.

### 1.1 O que entra

- Job de **áudio-only** no engine (`MediaKind.audio`): mesmo pipeline, sem demux de vídeo no sentido estrito, sem mux — saída `.m4a` AAC, ritmo natural (sem time-stretch).
- Permissão `RECORD_AUDIO` + gravação WAV via plugin `record`.
- Captura de vídeo via `image_picker` (`ACTION_VIDEO_CAPTURE` por baixo).
- Canal nativo `omnitranslator/share` (ACTION_SEND direcionado + Sharesheet) + `FileProvider` + `<queries>`.
- Telas novas: `RecordVoiceScreen`, `ResultScreen`; dois cards de entrada na home.
- Idiomas: **somente en/pt/es** (6 direções, pt↔es por pivô en) — igual ao M1.

### 1.2 O que NÃO entra (fora de escopo, não implementar)

- Câmera embutida (CameraX) — decisão do usuário: câmera do sistema.
- SDKs proprietários de share (Facebook Share SDK, TikTok Share Kit), legendas/hashtags automáticas, postagem direta via API.
- Converter áudio em vídeo (waveform) para postar voz no Instagram/TikTok — os botões desses apps simplesmente não aparecem para resultado de áudio (§7.5).
- Novos idiomas, diarização, separação de fontes, tempo real, `AudioPlaybackCapture` (continuam nos marcos M2–M5).
- Limpeza automática de `outputsRootDir()` (documentada como pendência em §8).

### 1.3 Relação com a D4

O M6 **não bloqueia nem é bloqueado pela D4** (aceite/release do M1). Se a D4 rodar depois do M6, o aceite deve incluir o sanity de regressão do §8.3.

---

## 2. Decisões fechadas (não rediscutir)

| # | Decisão | Motivo |
|---|---|---|
| M6-1 | Vídeo capturado pelo **app de câmera do sistema** via `image_picker` (`pickVideo(source: camera)`), não câmera embutida | Decisão do usuário (2026-07-19). Menos código nativo, sem permissão `CAMERA`, quirks por fabricante tratados pelo plugin mantido pelo time Flutter |
| M6-2 | Share com **botões diretos por app + Sharesheet** ("Outros"/fallback) | Decisão do usuário (2026-07-19) |
| M6-3 | Share implementado por **MethodChannel nativo** (`omnitranslator/share`), não `share_plus` | `share_plus` não suporta intent direcionado a package (o requisito central do M6-2); o projeto já tem o padrão de canais nativos no `MainActivity.kt` (SAF) |
| M6-4 | Voz gravada em **WAV PCM16 16 kHz mono** pelo plugin `record` | 16 kHz mono é o formato nativo do ASR (`asr_in.wav`); o áudio original não aparece na saída de um job de áudio (não há voice-over), então gravar acima disso só desperdiça espaço |
| M6-5 | Saída de F1 em **`.m4a` (AAC 128 kbps)** | Compartilhável no WhatsApp/Telegram como áudio; o encoder AAC nativo já existe no FFmpegKit LGPL do AT-3 (o mux atual já usa `-c:a aac`) |
| M6-6 | Job de áudio **reusa `runDubbingJob`** com um campo `mediaKind` no config — não é um pipeline novo | Aproveita foreground service, checkpoints, cancelamento, notificação e a `ProgressScreen` sem nenhuma mudança de Kotlin |
| M6-7 | Job de F1 roda no **mesmo foreground service** dos jobs de vídeo | Zero infra nova; notificação e sobrevivência a background de graça. O overhead do service é irrelevante perto do ASR/TTS |
| M6-8 | Ritmo **natural** no job de áudio (sem time-stretch): deadline inflado no `planDubSchedule`, nunca acelera | A saída não precisa caber na duração original — é uma mensagem de voz traduzida, não uma dublagem sincronizada |

---

## 3. O que é reusado (não reescrever nada disto)

| Peça existente | Onde | Papel no M6 |
|---|---|---|
| `runDubbingJob` + estágios | `packages/dubbing_engine/lib/src/pipeline.dart` | Único ponto que muda no engine (branch `mediaKind`) |
| `MediaProcessingService` + `serviceMain` + cliente Dart | `app/android/.../MediaProcessingService.kt`, `app/lib/src/service_entrypoint.dart`, `app/lib/src/platform/media_processing_service.dart` | Executa os jobs novos **sem mudança alguma** (config cruza o canal como mapa opaco) |
| `AppState.startJob/cancelJob` + eventos | `app/lib/src/state/app_state.dart` | Mesmo caminho de job; ganha só o `mediaKind` corrente |
| `ProgressScreen` | `app/lib/src/screens/progress_screen.dart` | Ganha filtro de estágios por `mediaKind` e botão "Ver resultado" |
| Import SAF / export SAF | `MainActivity.kt` + `home_screen.dart`/`progress_screen.dart` | Export ("Salvar em...") migra para a `ResultScreen`; import continua na home |
| `ModelManager` / `ModelCatalog.android()` / `ensureTranslationModels` | `packages/dubbing_engine/lib/src/model_manager.dart` | Gate de modelos antes de gravar (§5.3) |
| `translationPath` | `packages/dubbing_engine/lib/src/translation_catalog.dart:52` | Diz quais `mt-tiny-*` um par de idiomas exige (pivô incluído) |
| `MediaToolRunner`/FFmpegKit | `packages/dubbing_engine/lib/src/runtime/media_tool_runner.dart` | O encode `.m4a` novo usa o mesmo runner |
| Helpers de diretório | `app/lib/src/platform/media_processing_service.dart:22-49` (`appRootDir`/`jobsRootDir`/`outputsRootDir`/`workRootDir`) | Saídas novas continuam em `outputsRootDir()`; workDirs em `workDirBase` |

Regras herdadas que continuam valendo: engine é Dart puro (nunca importar `package:flutter` em `packages/dubbing_engine` — erro já cometido e corrigido duas vezes, ver `decisoes.md` 2026-07-16); paths locais apenas no engine; storage do usuário só via SAF (sem `READ_MEDIA_*`/`MANAGE_EXTERNAL_STORAGE`); release arm64-v8a; 16 KB pages; cancelamento via `CancellationToken`.

---

## 4. Fase C1 — engine: job áudio-only

**Toda a C1 é Dart puro, testável no Windows com `dart test` — nenhum device necessário.**

### 4.1 `packages/dubbing_engine/lib/src/models.dart`

1. Novo enum, junto dos outros:
   ```dart
   /// Tipo de mídia do job: [video] = dublagem clássica (demux→…→mux);
   /// [audio] = tradução de voz (entrada de áudio, saída .m4a, ritmo natural).
   enum MediaKind { video, audio }
   ```
2. `DubbingJobConfig` ganha `final MediaKind mediaKind;` com default `MediaKind.video` no construtor. Em `toJson()`: `'mediaKind': mediaKind.name`. Em `fromJson()`: `mediaKind: MediaKind.values.byName(j['mediaKind'] as String? ?? 'video')` — **o default `video` é obrigatório**: `job.json` de checkpoints antigos e todo o código desktop não têm o campo.
3. `DubbingResult` ganha `final String? sourceText;` e `final String? targetText;` (transcrição e tradução completas, segmentos unidos com `'\n'`; preenchidos **só** em jobs de áudio). `toJson`/`fromJson` com tolerância a ausência (`as String?`). O campo `outputVideo` **mantém o nome** (está serializado em checkpoints) e passa a carregar o path do `.m4a` quando o job é de áudio — documentar isso no doc comment do campo.

### 4.2 `packages/dubbing_engine/lib/src/pipeline.dart`

No topo do `runDubbingJob`, depois de ler `config`: `final isAudio = config.mediaKind == MediaKind.audio;`. Mudanças estágio a estágio (tudo que não está listado fica **intocado**):

- **prepare**: inalterado (o guard de espaço e de modelos vale igual).
- **download**: se `isAudio && config.youtubeUrl != null` → `PipelineException(PipelineStage.download, 'Download remoto não é suportado para jobs de áudio.')` (antes do bloco atual).
- **demux**: a chamada `runDemux(...)` fica como está — `ffmpeg -vn -ac 2 -ar 44100 -c:a pcm_s16le` sobre um `.wav` de entrada só converte o áudio para o formato canônico `audio_full.wav`, e o `ffprobe` devolve a duração (`runDemux` → `Future<double>`, segundos). Só as mensagens dos eventos mudam quando `isAudio`: `'Preparando áudio...'` / `'Áudio preparado'`.
- **separate**: quando `isAudio`, **pular o estágio inteiro** (nenhum evento): `voiceOverMode` permanece `false` e `audioForAsr = p.join(workDir, 'audio_full.wav')`. Motivo: não existe trilha a separar, e o modo voice-over colocaria a voz ORIGINAL do usuário sob a tradução — indesejado num job de voz.
- **diarize**: quando `isAudio`, pular (nenhum evento). Voz única do idioma-destino, sempre.
- **transcribe**: inalterado. Logo após o transcribe/segment, adicionar o guard: se `isAudio && segments.isEmpty` → `PipelineException(PipelineStage.transcribe, 'Nenhuma fala detectada na gravação.')` (caso real: usuário grava silêncio).
- **segment / translate / synthesize (fase 1)**: inalterados.
- **fit** (ritmo natural): o deadline passado ao `planDubSchedule` (`packages/dubbing_engine/lib/src/steps/fitter.dart:40`) muda quando `isAudio`:
  ```dart
  double deadline = videoDuration;
  if (isAudio) {
    for (final s in segments) {
      final originalSec = (s.end - s.start).inMicroseconds / 1e6;
      deadline += math.max(0.0, s.naturalDurationSec! - originalSec);
    }
    deadline += 2.0;
  }
  final plan = planDubSchedule(starts, ends, naturals, deadline);
  ```
  Esse deadline é **provadamente suficiente** (pior caso: cada fala empurra a próxima pelo próprio excesso), então nenhum item do plano precisa acelerar — as pausas originais do usuário são preservadas e a fala sai a 1.0x. O laço de `applyPlanToSegment` fica igual; **guardar o `cursor` final** (o `Future<double>` devolvido pela última chamada — fim real da última fala materializada).
  - Se os testes da §4.5 mostrarem o fitter devolvendo `speed < 1.0` com esse deadline (desacelerando para "preencher"), adicionar um parâmetro `bool naturalPace = false` ao `planDubSchedule` que força `speed = 1.0` em todos os itens — **não** mexer em mais nada do fitter. Caso contrário, não tocar no fitter.
- **mix**: a duração da trilha muda quando `isAudio` (evita a cauda de silêncio do deadline inflado):
  ```dart
  final trackDuration = isAudio ? cursor + 0.5 : videoDuration;
  final dubTrack = await buildDubTrack(segments, trackDuration, workDir, token);
  if (!isAudio) await buildFinalMix(voiceOverMode, workDir, media, token);
  ```
  **Não chamar `buildFinalMix` em jobs de áudio**: o ramo não-voice-over dele depende de `accompaniment.wav` (que não existe sem separação) e o ramo voice-over mixaria a voz original sob a tradução. A fonte do encode é o `workDir/dub_voice.wav` que o `buildDubTrack` escreve (`mixer.dart:32`).
- **mux → encode**: quando `isAudio`, no lugar de `buildFinalVideo(...)`:
  ```dart
  yield PipelineEvent(PipelineStage.mux, 0.0, 'Gerando áudio final...');
  final outputVideo = await buildFinalAudio(
      config, p.join(workDir, 'dub_voice.wav'), media, token);
  ```
  (novo step, §4.3). Evento final: `'Áudio gerado com sucesso'`. O nome da variável/campo continua `outputVideo` (§4.1.3).
- **SRT**: o bloco `config.generateSrt` funciona sem mudança para ambos os tipos (o fluxo F1 passa `generateSrt: false` por default; se true, os `.srt` saem ao lado do `.m4a`).
- **sync report**: quando `isAudio`, **pular** (não há vídeo com que sincronizar; `syncReportPath` fica null).
- **DubbingResult**: preencher `sourceText`/`targetText` quando `isAudio`:
  ```dart
  sourceText: isAudio ? segments.map((s) => s.sourceText).join('\n') : null,
  targetText: isAudio ? segments.map((s) => s.translatedText).join('\n') : null,
  ```

### 4.3 Novo step `packages/dubbing_engine/lib/src/steps/audio_encode.dart`

```dart
/// Codifica a trilha dublada em .m4a (AAC) — o "mux" dos jobs de áudio.
/// `-f ipod` explícito: garante container m4a mesmo que a extensão do
/// outputPath mude; `+faststart` deixa o arquivo streamável (WhatsApp toca
/// antes de baixar inteiro).
Future<String> buildFinalAudio(
  DubbingJobConfig config,
  String dubVoiceWav,
  MediaToolRunner media,
  CancellationToken token,
) async { ... }
```

Comando: `ffmpeg -y -i <dubVoiceWav> -c:a aac -b:a 128k -movflags +faststart -f ipod <config.outputPath>`. Erro de exit code ≠ 0 → `PipelineException(PipelineStage.mux, 'Erro ao gerar o áudio final: ${r.stderrTail}')`. Devolve `config.outputPath`. Seguir o estilo de `steps/muxer.dart` (mesmo uso de `media.run(MediaTool.ffmpeg, [...])`, mesmo tratamento de token).

### 4.4 O que NÃO muda na C1

`MediaProcessingService.kt`, `MainActivity.kt`, `service_entrypoint.dart`, `media_processing_service.dart`, checkpoints (`job_checkpoint_store.dart`), backends, `ModelCatalog` — **nada**. A config nova cruza o MethodChannel como mapa opaco e o default de `fromJson` cobre o resto.

### 4.5 Testes e gate C1

Novo arquivo `packages/dubbing_engine/test/pipeline_audio_test.dart`, com o fake runtime já usado por `pipeline_test.dart`:

1. Job `MediaKind.audio` completo: eventos **não** contêm `separate`/`diarize`; contêm `mux` com mensagem de áudio; `onDone` traz `outputVideo` terminando em `.m4a`, `sourceText`/`targetText` não nulos, `syncReport == null`.
2. O ffmpeg do estágio final recebeu `-f ipod` e `-c:a aac` (inspecionar os args gravados pelo fake runner).
3. Ritmo natural: com um fake em que a duração natural excede o slot original, `segmentsWithOverflow == 0` e nenhum item do plano tem `clamped == true` / `speed > 1.0`.
4. Guard de silêncio: transcriber fake devolvendo 0 segmentos → `PipelineException` no `transcribe` com a mensagem de "Nenhuma fala".
5. Roundtrip JSON: `DubbingJobConfig` sem `mediaKind` no mapa → `video`; com `'audio'` → `audio`. `DubbingResult` com e sem `sourceText`/`targetText`.
6. Job `MediaKind.video` continua byte-a-byte igual (os testes existentes não podem mudar).

**Gate C1**: `tool/verify.ps1` verde com o piso de testes atualizado (hoje 371 + os novos); `flutter analyze` limpo; nenhum arquivo fora de `packages/dubbing_engine/` alterado.

---

## 5. Fase C2 — F1: gravar voz e traduzir

### 5.1 Plugin e permissão

- `app/pubspec.yaml`: adicionar `record: ^6.0.0`. O pacote Android do `record` não embute `.so` próprio (usa `AudioRecord`/`MediaRecorder` da plataforma) — não afeta o gate de 16 KB; ainda assim, o gate C2 reconfirma com `packages/dubbing_engine/tool/check_native_libs.dart`.
- `app/android/app/src/main/AndroidManifest.xml`: `<uses-permission android:name="android.permission.RECORD_AUDIO" />`. **Não** adicionar `CAMERA` (ver §6.1) nem `permission_handler` — `AudioRecorder.hasPermission()` do próprio plugin já dispara o prompt de runtime.

### 5.2 Nova tela `app/lib/src/screens/record_voice_screen.dart`

Estados: `idle → recording → starting` (job disparado). Elementos:

- Seletores de idioma origem/destino (só `Lang.en/pt/es`; defaults das settings, como na home). Origem ≠ destino.
- Aviso/gate de modelos (§5.3) — o botão de gravar só habilita com tudo `ready`.
- Botão único gravar/parar + cronômetro (`Timer.periodic` de 1 s) + limite `const maxVoiceRecording = Duration(minutes: 5)` (auto-stop no limite) + botão cancelar (apaga o `workDir` e volta).
- Opcional (não bloqueia o gate): medidor de nível via `recorder.onAmplitudeChanged(const Duration(milliseconds: 200))`.

Gravação (API do `record` v6):

```dart
final recorder = AudioRecorder();                      // dispose() no dispose da tela
if (!await recorder.hasPermission()) { /* SnackBar amigável, permanece idle */ }
await recorder.start(
  const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1),
  path: p.join(workDir, 'input.wav'),
);
final path = await recorder.stop();                    // null = nada gravado
```

O `workDir` é criado ANTES de começar a gravar, no mesmo padrão de `_startDubAndroid` (`home_screen.dart:430`): `p.join(state.settings.workDirBase, timestamp)`.

Ao parar com sucesso: montar o config e disparar o job **automaticamente** (é o "imediatamente" do requisito):

```dart
final config = DubbingJobConfig(
  mediaKind: MediaKind.audio,
  inputVideo: p.join(workDir, 'input.wav'),
  sourceLang: _sourceLang, targetLang: _targetLang,
  preset: state.settings.preset-equivalente-da-home,
  keepOriginalTrack: false, generateSrt: false,
  workDir: workDir,
  outputPath: p.join(await outputsRootDir(), '${timestamp}_voice_${_targetLang.code}.m4a'),
);
Navigator.push(... ProgressScreen ...);
state.startJob(config, displayName: 'Tradução de voz');
```

(Conferir a assinatura real de `state.startJob` no `app_state.dart` — no Android ela já aceita `displayName`.)

### 5.3 Gate de modelos — helper compartilhado

Extrair a lógica de `_missingModels` (`app/lib/src/screens/home_screen.dart:153`) para `app/lib/src/state/model_gating.dart`, sem alterá-la no que já cobre, garantindo que o resultado final cubra:

- ASR do preset (`catalog.asrModelIds[preset]`);
- `silero-vad` e `espeak-ng-data` (dependências do catálogo — respeitar `dependsOn` das entradas);
- voz default do destino (`catalog.defaultVoiceIds[targetLang]`);
- pares MT de `translationPath(source, target)` (`translation_catalog.dart:52` — pivô en incluído), via `directTranslationModelId`.

A home passa a usar o helper (comportamento idêntico); a `RecordVoiceScreen` e o fluxo F2 usam o mesmo. Quando falta modelo: texto laranja (padrão da home) + botão "Baixar modelos" → `Navigator.push(ModelsScreen)`.

### 5.4 `ProgressScreen` — estágios por tipo de job

`progress_screen.dart:67` itera `PipelineStage.values`. Mudar para uma lista filtrada:

```dart
const _audioStages = [PipelineStage.prepare, PipelineStage.demux,
  PipelineStage.transcribe, PipelineStage.segment, PipelineStage.translate,
  PipelineStage.synthesize, PipelineStage.fit, PipelineStage.mix, PipelineStage.mux];
```

com rótulos próprios no modo áudio para `demux` ("Preparando áudio") e `mux` ("Gerando áudio final") — os demais rótulos de `_stageNames` servem. O `AppState` guarda o `MediaKind` do job corrente (setar em `startJob` a partir do config; ao reatar um job vivo/recuperável, derivar do config persistido no checkpoint — verificar se `JobCheckpoint` carrega o config; se não carregar, default `video`).

### 5.5 Testes e gate C2

Testes (`app/test/`): widget test da `RecordVoiceScreen` com o recorder mockado (estados idle/recording, botão desabilitado sem modelos); teste do helper de gating (§5.3) cobrindo pivô pt→es; teste do filtro de estágios da `ProgressScreen` em modo áudio.

**Gate C2 (smoke no moto g86, roteiro manual no padrão `tool/android/smoke/README.md`)**:
1. Gravar uma frase em inglês → job completa → `.m4a` em `outputsRootDir()` audível em pt-BR (export SAF para conferir no desktop, ou tocar na `ResultScreen` se a C4 já existir).
2. Negar `RECORD_AUDIO` → mensagem amigável, sem crash; conceder depois → funciona.
3. Colocar o app em background durante o job → notificação do service progride e o job completa (comportamento herdado da D3.3 — só confirmar que vale para o job de áudio).
4. Gravar silêncio → erro "Nenhuma fala detectada" apresentado sem crash.
5. `packages/dubbing_engine/tool/check_native_libs.dart` sem `.so` nova inesperada.

---

## 6. Fase C3 — F2: gravar vídeo com a câmera do sistema

### 6.1 Captura

- `app/pubspec.yaml`: adicionar `image_picker: ^1.1.0`.
- Uso: `ImagePicker().pickVideo(source: ImageSource.camera, maxDuration: const Duration(minutes: 3))` → `XFile?` (null = usuário cancelou a câmera; nesse caso apagar o `workDir` recém-criado e voltar sem erro).
- `maxDuration` de 3 min é `const` nomeada (`maxCapturedVideoDuration`) — limite deliberado do M6 v1: vídeo 4K de câmera cresce ~1 GB/10 min e o job ficaria longo demais (mitigação do risco R-M6-1, §9).
- **Não declarar `CAMERA` no manifest.** O `ACTION_VIDEO_CAPTURE` só exige a permissão se o próprio app a declarar; o `image_picker` não declara. O gate C3 confere o manifest MESCLADO do APK para garantir que nenhum plugin a introduziu.

### 6.2 Fluxo — refatoração mínima da home

Em `home_screen.dart`, extrair de `_startDubAndroid` (linha 430) um método reutilizável:

```dart
/// Monta o DubbingJobConfig de vídeo a partir de um arquivo JÁ dentro do
/// workDir, navega pra ProgressScreen e dispara o job. Usado pelo import
/// SAF (fluxo atual) e pela captura de câmera (M6/C3).
Future<void> _startAndroidVideoJob(AppState state, String workDir,
    String localInputPath, {required String displayName}) async { ... }
```

- Fluxo SAF atual: cria workDir → `copyUriToLocalFile` → `_startAndroidVideoJob` (comportamento final idêntico ao de hoje; `outputPath` continua `outputsRootDir()/{ts}_dub_{target}.mp4`).
- Fluxo captura: gate de modelos (§5.3) → cria workDir → `pickVideo(...)` → copiar `xfile.path` para `p.join(workDir, 'input.mp4')` com **copy + delete do original** (`File.rename` pode falhar entre filesystems — o cache do picker pode morar em outro mount) → `_startAndroidVideoJob`.

### 6.3 Entradas na home

No topo do `build` da home, **somente Android**, dois cards/botões grandes:

- "🎤 Traduzir minha voz" → `Navigator.push(RecordVoiceScreen())`;
- "📹 Gravar e dublar vídeo" → fluxo §6.2 (idiomas/preset: os já selecionados na home).

O fluxo de importação existente ("Escolher vídeo...") permanece intacto logo abaixo.

### 6.4 Testes e gate C3

Testes: unit do copy+delete (arquivo temporário); widget test dos cards (aparecem no Android, não no desktop — usar o mesmo padrão de `Platform.isAndroid` mockável dos testes existentes, se houver; senão, testar só o helper).

**Gate C3 (smoke no moto g86)**:
1. Card → câmera do sistema abre → gravar ~30 s falando inglês → app volta → job roda → mp4 dublado pt reproduzível (export SAF).
2. Cancelar na câmera → volta à home sem erro e sem `workDir` órfão (conferir `workRootDir()` via `adb shell run-as`).
3. Manifest mesclado sem `CAMERA`: `apkanalyzer manifest print app-debug.apk | findstr CAMERA` vazio (ou `aapt dump permissions`).
4. Regressão: um import SAF completo continua funcionando.

---

## 7. Fase C4 — F3: compartilhamento + tela de resultado

### 7.1 Canal nativo `omnitranslator/share` (`MainActivity.kt`)

Dois métodos, no mesmo estilo dos canais existentes:

- `installedPackages(candidates: List<String>) → List<String>`: filtra por `packageManager.getPackageInfo(pkg, 0)` dentro de try/catch (`NameNotFoundException` = ausente). Só funciona por causa do `<queries>` (§7.3).
- `shareFile(path: String, mimeType: String, targetPackage: String?, text: String?)`:

```kotlin
val file = File(path)
if (!file.exists()) { result.error("file_not_found", path, null); return }
val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
val send = Intent(Intent.ACTION_SEND).apply {
    type = mimeType
    putExtra(Intent.EXTRA_STREAM, uri)
    if (text != null) putExtra(Intent.EXTRA_TEXT, text)
    clipData = ClipData.newRawUri(null, uri)   // o grant do flag só é confiável com ClipData
    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
}
if (targetPackage != null) {
    send.setPackage(targetPackage)
    if (packageManager.resolveActivity(send, 0) != null) {
        startActivity(send); result.success(true); return
    }
    send.setPackage(null)                       // alvo sumiu entre a checagem e o tap
}
val chooser = Intent.createChooser(send, "Compartilhar")
    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
startActivity(chooser)
result.success(true)
```

Não há `onActivityResult` aqui — share é fire-and-forget (não dá para saber se o usuário concluiu o envio; não fingir que dá).

### 7.2 FileProvider

No `AndroidManifest.xml`, dentro de `<application>`:

```xml
<provider
    android:name="androidx.core.content.FileProvider"
    android:authorities="${applicationId}.fileprovider"
    android:exported="false"
    android:grantUriPermissions="true">
    <meta-data
        android:name="android.support.FILE_PROVIDER_PATHS"
        android:resource="@xml/file_paths" />
</provider>
```

Novo `app/android/app/src/main/res/xml/file_paths.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<paths>
    <files-path name="outputs" path="outputs/" />
</paths>
```

`outputsRootDir()` = `getApplicationSupportDirectory()/outputs` (`media_processing_service.dart:37`), e no Android o `path_provider` mapeia `getApplicationSupportDirectory()` para `Context.getFilesDir()` → `<files-path>` com `path="outputs/"`. **Validar em runtime no gate** (logar o path e conferir que começa com `/data/user/0/com.luistiagos.omnitranslator/files/`); se o `path_provider` da versão em uso devolver outro subdiretório, ajustar o `file_paths.xml` de acordo (ex.: `<files-path path="."/>` como último recurso — nunca expor a raiz de `/data` inteira com `<root-path>`).

### 7.3 Package visibility (`<queries>`)

Fora de `<application>`, no manifest:

```xml
<queries>
    <package android:name="com.whatsapp" />
    <package android:name="org.telegram.messenger" />
    <package android:name="com.facebook.katana" />
    <package android:name="com.instagram.android" />
    <package android:name="com.zhiliaoapp.musically" />
    <package android:name="com.ss.android.ugc.trill" />
</queries>
```

Sem isto, `getPackageInfo`/`resolveActivity` mentem "ausente" no Android 11+. TikTok tem dois packages por região — tratar como um alvo lógico ("TikTok") que tenta `musically` e cai para `trill`.

### 7.4 Camada Dart — `app/lib/src/platform/share.dart`

```dart
enum ShareTarget { whatsapp, telegram, facebook, instagram, tiktok }
// por alvo: rótulo pt-BR, lista de packages candidatos (tiktok tem 2),
// e `supportsAudio` (true só para whatsapp/telegram — §7.5)

Future<Set<ShareTarget>> installedShareTargets();
Future<void> shareFile({required String path, required String mimeType,
    ShareTarget? target, String? text});   // target null = Sharesheet
```

MIME: `video/mp4` para `.mp4`, `audio/mp4` para `.m4a`. `text` default: `'Traduzido com OmniTranslator'` (o usuário pode limpar — campo opcional na tela; WhatsApp/Telegram exibem como legenda, Facebook ignora, documentado).

### 7.5 Nova tela `app/lib/src/screens/result_screen.dart`

Recebe `DubbingResult result` + `MediaKind mediaKind` (+ `jobId` para o export SAF). Conteúdo:

- **Player** (`video_player: ^2.9.0` no pubspec): mp4 com preview visual; `.m4a` toca com ExoPlayer também — para áudio, UI própria (play/pause + posição + duração), sem área de vídeo.
- **Jobs de áudio**: dois blocos de texto selecionável — "Você disse:" (`result.sourceText`) e "Tradução:" (`result.targetText`).
- **Botões de share**: linha de botões por alvo instalado (`installedShareTargets()`, esconder ausentes). Resultado de **áudio** → só WhatsApp, Telegram e "Outros" (Instagram/TikTok/Facebook não aceitam `ACTION_SEND` de áudio); **vídeo** → os 5 + "Outros". "Outros" = `shareFile(target: null)`.
- **"Salvar em..."**: mover `_exportOutput` de `progress_screen.dart:168` para um helper compartilhado (ex.: `app/lib/src/platform/export_helpers.dart`), parametrizando o MIME (`audio/mp4` para `.m4a`); a `ResultScreen` o chama; a lógica `exportJob(jobId)` (flip do checkpoint) permanece idêntica.
- Avisos herdados (voice-over etc.) continuam na `ProgressScreen` — a `ResultScreen` é só resultado.

Na `ProgressScreen` (Android): quando `result != null`, o bloco atual de "Arquivo gerado + Salvar em..." vira um botão **"Ver resultado"** → `Navigator.push(ResultScreen(...))`. Desktop fica exatamente como está (`Abrir pasta`).

### 7.6 Testes e gate C4

Testes: unit do mapeamento alvo→packages/MIME/`supportsAudio`; widget test da `ResultScreen` (áudio esconde IG/TikTok/FB; textos aparecem) com o canal mockado (`TestDefaultBinaryMessenger`).

**Gate C4 (smoke manual no moto g86, com os 5 apps instalados e logados)**:
1. Vídeo dublado → cada um dos 5 botões abre o app certo com o vídeo anexado (TikTok: abrir o fluxo de upload já é sucesso; se algum app recusar o intent direcionado, o fallback chooser abrindo conta como sucesso **documentado** no relatório do gate).
2. Áudio traduzido → WhatsApp recebe como áudio reproduzível; Telegram idem; botões de IG/TikTok/FB ausentes.
3. Desinstalar (ou usar device sem) um dos apps → botão some; "Outros" continua funcionando.
4. Path do FileProvider validado (§7.2).

---

## 8. Fase C5 — polimento e aceite do M6

### 8.1 Itens

- Tela "Sobre"/notices (§16.3 da spec Android): adicionar `record`, `image_picker`, `video_player` (licenças BSD-3-Clause/Apache-2.0 — conferir o `LICENSE` real de cada um no pub.dev na versão travada pelo lock, e citar a versão).
- `tool/verify.ps1`: subir o piso para a contagem nova de testes.
- `docs/progresso-android.md` §5: marcar C1–C5 com resultado e evidências.
- Documentar a pendência: `outputsRootDir()` acumula saídas sem limpeza automática (cada `.m4a` é pequeno, mas mp4 dublado não); gestão/limpeza fica para um marco futuro.

### 8.2 Critérios de aceite do M6

1. F1 completo no moto g86 nas 6 direções (en↔pt, en↔es, pt↔es via pivô).
2. F2 completo em pelo menos en→pt e en→es (as demais direções são cobertas por F1 — o pipeline de vídeo é o mesmo do M1 já aceito).
3. F3: matriz do gate C4 preenchida.
4. `tool/verify.ps1` verde; `packages/dubbing_engine/tool/check_native_libs.dart` sem ABI/`.so` inesperada; APK com `zipalign -c -P 16` OK (16 KB).

### 8.3 Sanity de regressão (obrigatório no fim)

Um job de **importação SAF** completo (fluxo M1 original) no device, provando que a refatoração da home e o `mediaKind` não regrediram o caminho antigo.

---

## 9. Riscos e mitigações

| # | Risco | Mitigação |
|---|---|---|
| R-M6-1 | Câmera do sistema grava 4K/60 → arquivo enorme, job lento | `maxDuration` 3 min (§6.1); medir tamanho/tempo real no gate C3 e registrar; `EXTRA_VIDEO_QUALITY` não é confiável entre OEMs — não usar |
| R-M6-2 | TikTok mudar/limitar o tratamento de `ACTION_SEND` | Botão direto é best-effort com fallback chooser sempre presente; dois packages tentados (§7.3) |
| R-M6-3 | Plugin novo introduzir permissão (`CAMERA` etc.) no manifest mesclado | Checagem explícita no gate C3 (item 3) |
| R-M6-4 | Ligação/interrupção durante a gravação de voz | v1: parar e manter o parcial (o `record` emite mudança de estado); comportamento documentado, não tratado como erro |
| R-M6-5 | `mediaKind` quebrar checkpoints/desktop | Default `video` em `fromJson` + teste de roundtrip com JSON antigo (§4.5.5); zero mudança no caminho de vídeo (§4.5.6) |
| R-M6-6 | `ProgressScreen` exibir estágios que nunca rodam no job de áudio | Lista de estágios por `MediaKind` (§5.4) |
| R-M6-7 | FileProvider com path errado (share falha com `IllegalArgumentException`) | Validação de runtime no gate C4 (§7.2/§7.6.4) |
| R-M6-8 | Fitter desacelerar (<1.0x) com deadline inflado | Plano B já especificado: `naturalPace` no `planDubSchedule` (§4.2/fit) |

---

## 10. Ordem de implementação e gates (resumo)

| Fase | Entrega | Gate | Precisa de device? |
|---|---|---|---|
| **C1** | Engine áudio-only (`MediaKind`, branch do pipeline, `audio_encode.dart`) | `verify.ps1` verde, testes §4.5, zero mudança fora do engine | Não |
| **C2** | F1: `record`, `RecordVoiceScreen`, gate de modelos, estágios por tipo | Smoke §5.5 no moto g86 | Sim |
| **C3** | F2: `image_picker`, refactor da home, cards de entrada | Smoke §6.4 no moto g86 | Sim |
| **C4** | F3: canal share, FileProvider, `<queries>`, `ResultScreen` | Smoke §7.6 no moto g86 (5 apps) | Sim |
| **C5** | Notices, piso de testes, docs, aceite | §8.2 + sanity §8.3 | Sim |

Convenções: commits em português com prefixo da fase (`feat(C1): ...`), decisões novas em `docs/decisoes.md`, progresso em `docs/progresso-android.md` §5, roteiros de smoke no padrão de `tool/android/smoke/README.md`. Branch: `android-port`.

---

## 11. Inventário de arquivos

**Novos:**

| Arquivo | Fase |
|---|---|
| `packages/dubbing_engine/lib/src/steps/audio_encode.dart` | C1 |
| `packages/dubbing_engine/test/pipeline_audio_test.dart` | C1 |
| `app/lib/src/state/model_gating.dart` | C2 |
| `app/lib/src/screens/record_voice_screen.dart` | C2 |
| `app/lib/src/screens/result_screen.dart` | C4 |
| `app/lib/src/platform/share.dart` | C4 |
| `app/lib/src/platform/export_helpers.dart` | C4 |
| `app/android/app/src/main/res/xml/file_paths.xml` | C4 |

**Alterados:**

| Arquivo | Fase | Mudança |
|---|---|---|
| `packages/dubbing_engine/lib/src/models.dart` | C1 | `MediaKind`, campo no config, campos no result |
| `packages/dubbing_engine/lib/src/pipeline.dart` | C1 | branch `isAudio` (§4.2) |
| `packages/dubbing_engine/lib/src/steps/fitter.dart` | C1 | **só se** R-M6-8 se confirmar (`naturalPace`) |
| `app/pubspec.yaml` | C2/C3/C4 | `record`, `image_picker`, `video_player` |
| `app/android/app/src/main/AndroidManifest.xml` | C2/C4 | `RECORD_AUDIO`; provider + `<queries>` |
| `app/android/app/src/main/kotlin/.../MainActivity.kt` | C4 | canal `omnitranslator/share` |
| `app/lib/src/screens/home_screen.dart` | C2/C3 | cards de entrada, helper `_startAndroidVideoJob`, `_missingModels` → helper |
| `app/lib/src/screens/progress_screen.dart` | C2/C4 | estágios por `MediaKind`; "Ver resultado"; export movido |
| `app/lib/src/state/app_state.dart` | C2 | `MediaKind` do job corrente |
| `tool/verify.ps1` | C1/C5 | piso de testes |
| `docs/progresso-android.md` | todas | registro por fase |
