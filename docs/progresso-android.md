# Progresso do port Android — registro de andamento

**Última atualização:** 2026-07-16
**Branch de trabalho:** `android-port` (todo o trabalho abaixo vive aqui, à frente de `main`; contagem exata via `git rev-list --count main..android-port`)
**Branch estável:** `main` em `b15c821` — desktop exatamente como antes, 199 testes; é a âncora para voltar se algo der errado.

> Este documento é o índice de andamento. Os detalhes de cada item estão nos documentos referenciados (spec, `decisoes.md`, relatórios de spike). Ordem normativa de trabalho: §17 de [especificacao-android.md](especificacao-android.md).

---

## 1. Estado por fase

| Fase | Item | Estado |
|---|---|---|
| Etapa 0 | Fechar a especificação (spec v2) | ✅ concluída |
| D0.5 | **AT-0** — gate de 16 KB | ✅ **PASSOU** (estática + confirmada no APK real da D3.0, ver §3.3f) |
| D2 | **AT-1** — tradução pt | ✅ **PASSOU** no moto g86 (slimt + `dedupRepeatedTail`) |
| D2 | **AT-2** — ASR (Whisper ONNX + Silero VAD) | ✅ **PASSOU** no moto g86 (ver §3.3b) |
| D2 | **AT-2b** — TTS Piper (VITS via `sherpa_onnx`) | ✅ **PASSOU** no moto g86 (ver §3.3c) |
| D2 | **AT-3** — FFmpegKitNext (build LGPL próprio) | ✅ **PASSOU** no moto g86 (ver §3.3e) |
| D1 | Correções de qualidade no engine (valem p/ desktop) | ✅ 4 itens feitos e verificados |
| D1 | **Contratos G-1…G-7** | ✅ **concluídos** (ver §3.5) |
| D1 | **Refatoração de memória** (áudio em disco, writer sequencial, `WavReader`) | ✅ **concluída** (ver §3.6) |
| D1 | **`MediaToolRunner`** (§5.2) | ✅ **concluído** (ver §3.7) |
| D1 | **`JobCheckpointStore` + fingerprint + política de retomada** (§5.7/§9.4) | ✅ **concluído** (ver §3.7) |
| D1 | **`tool/verify.ps1` + `check_native_libs.dart`** (D-d) | ✅ **concluídos** (ver §3.7) |
| **D1** | **fase completa** | ✅ **o engine está pronto para o port** |
| **D3** | **D3.0 — scaffold `app/android`** | ✅ **feito** — build sobe no moto g86 (ver §3.3f) |
| D3 | **D3.1 — armazenamento/SAF** (AT-5) | ✅ **PASSOU** no moto g86 (ver §3.3g) |
| D3 | Pré-req D3.2 — build versionado da `libslimt.so` | ✅ **feito** (ver §3.3h) |
| D3 | **D3.2 — `ModelCatalog.android()` + mirror publicado** | ✅ **feito** (ver §3.3i) |
| D3 | **D3.2 — backends Android + `androidRuntime()`** | ✅ **feito** (ver §3.3j) |
| D3 | **D3.3 — `MediaProcessingService` (foreground service, AT-4)** | ✅ **feito** — compila contra o app real (ver §3.3m); 5 cenários do §14.6 pendentes de device |
| D3 | D3.4 — liga a UI e roda end-to-end nos três idiomas | ⬜ pendente |
| D4 | Aceite e release | ⬜ pendente |

**A fase D1 está concluída**, **AT-0, AT-1, AT-2, AT-2b e AT-3 passaram no moto g86**, e **a D3 (casca Android M1) está em andamento**: o scaffold `app/android` existe e builda no device (D3.0), **AT-5 (StatFs + SAF) passou** dentro da D3.1 (ver §3.3g), os 4 backends Android + `androidRuntime()` estão escritos (D3.2, ver §3.3j), e **D3.3 — `MediaProcessingService` (foreground service, AT-4) está escrito e compilando contra o app real** (ver §3.3m) — código de produção real em todos os casos, não spike descartável. O engine continua passando **368 testes**, com o pipeline real dublando ponta a ponta a 100% de sincronia. Decisão do usuário (2026-07-15): AT-4 (foreground service) e AT-5 (SAF/StatFs) deixam de ser spikes isolados e passam a ser validados dentro da própria D3, já que dependem da casca Android existir de verdade. Ordem da D3: D3.1 armazenamento/SAF (=AT-5, ✅) → D3.2 backends Android + `AndroidRuntime` (✅) → D3.3 foreground service (=AT-4, ✅) → D3.4 liga a UI e roda end-to-end nos três idiomas (pendente). Pré-requisito antes da D3.2: versionar o build da `libslimt.so` (dívida do SA-1/AT-1).

---

## 2. Estratégia de branches

| Branch | HEAD verificado¹ | Testes | Papel |
|---|---|---|---|
| `main` | `b15c821` | 199 | Desktop estável, intocado. Referência para regressão. |
| `android-port` | `be159a3` | 322 | Todo o trabalho do port + as correções de bug do engine. Onde evoluímos daqui. |

¹ O commit em que a contagem de testes foi verificada com `tool/verify.ps1` — commits posteriores só de docs não a alteram (o HEAD real pode estar à frente; `git log` é a fonte).

Motivo (decisão do usuário, 2026-07-12): as mudanças do engine afetam **ambas** as plataformas (o `dubbing_engine` é compartilhado), então, para não arriscar o desktop com nada não previsto, o trabalho ficou isolado no `android-port`. `main` só recebe quando estiver validado. Verificado rodando os testes em cada branch: `main` = 199 (baseline original), `android-port` = 322 (via `tool/verify.ps1`, piso 284).

---

## 3. Concluído

### 3.1 Etapa 0 — especificação fechada (spec v2)

A auditoria em [revisao-especificacao-android.md](revisao-especificacao-android.md) deixara 2 pendências, 7 lacunas de contrato e 6 riscos sem gate. Todos resolvidos e registrados:

- [especificacao-android.md](especificacao-android.md) subiu para **v2**: contratos que faltavam (§5.7 `JobCheckpointStore`, §5.8 `CancellationToken` generalizado, §5.9 `SeparationOutcome` com reason code, §5.1 `MediaDownloader`), ligação `ModelCatalog`↔`ModelManager` (§6.0), Silero VAD como segmentador (§8/P3), cauda da última fala (§7.4), AT-0 (§16.1), sem CI (§16.2), `sync_report.json` (§8/P9).
- Decisões **D-a…D-d** e as correções de premissa em [decisoes.md](decisoes.md).
- [especificacao-tecnica.md](especificacao-tecnica.md): reconciliada a contradição entre a regra #4 ("nunca truncar") e a validação da §P8.
- [aceite-android.md](aceite-android.md): linhas de AT-0 e AT-2b, escopo das 6 direções alinhado (gate = en↔pt).

### 3.2 AT-0 — páginas de 16 KB — **PASSOU**

Relatório: [spikes-android/AT0.md](spikes-android/AT0.md).

As três `.so` arm64 do `sherpa_onnx_android_arm64` 1.13.4 têm **todos** os segmentos `LOAD` com `align 0x4000` (16 KB), e o ONNX Runtime embutido é **1.27.0**. A issue k2-fsa/sherpa-onnx#3291 (que reportava ORT 1.17.1) está obsoleta, e a lib de que ela reclama (`libonnxruntime4j_jni.so`) é o binding **Java** — o pacote Dart não o empacota. **O remédio caro (recompilar sherpa + ORT do fonte) está descartado.** Restam só confirmações de runtime (`zipalign`, emulador 16 KB), que dependem de `app/android/` existir e entram na fase D3.

### 3.3 AT-1 — tradução pt — **PASSOU** no moto g86

Relatório: [spikes-android/AT1.md](spikes-android/AT1.md).

**Correção de premissa importante:** o repositório arquivado `mozilla/firefox-translations-models` **não serve para download** — os arquivos estão em Git LFS e os objetos foram removidos do servidor (`410`). A fonte real é o **Remote Settings do Firefox** (CDN pública, com `location`, `size` e `hash` SHA-256 por registro). `version: "1.0"` = tier **tiny** (a arquitetura `ssru`/`dec-depth: 2` que o slimt suporta); `version: "2.x"` = `base-memory`.

- Download do modelo tiny en→pt verificado ponta a ponta (HTTP 200, 17.140.899 bytes, SHA-256 confere). Licença MPL-2.0.
- **Qualidade medida, não estimada** (BLEU/COMET dos `metadata.json`): nos pares de gate, o tiny perde só **0,6 BLEU em en→pt** e **0,1 em pt→en** ante o `base-memory`. Divergência desprezível.
- Subproduto: o modelo instalado no desktop é bit a bit idêntico ao registro v2.1 → fonte pública/hasheável para pt também no Windows (encerra um risco antigo do desktop).
- **Execução real no moto g86** (100 frases/direção): en→pt passou de cara (100/100, ~96 boas, ~20 ms/frase, 114 MB). pt→en reprovou cru — decodificação **gulosa** do slimt (beam 1) não para no EOS e repete a frase inteira (ex.: "I would like a cup of coffee. I would like a cup of coffee."). Não é defeito do modelo (en→de tiny, mesma arquitetura, traduz limpo) nem de qualidade — é o modo de falha do decodificador.
- **Resolvido** com `dedupRepeatedTail` (`packages/dubbing_engine/lib/src/steps/translation_postprocess.dart`): 4 regras que são propriedades do modo de falha (pontuação metralhada, 4-gram repetido, eco de sentença, fragmento final repetitivo). Sobre as 100 saídas reais do device: 17→0 degeneradas, nenhuma frase limpa alterada. `AndroidTranslator` (D3) **deve** aplicar essa função antes de devolver.

Pendência não bloqueante: versionar o build do `libslimt.so` arm64 neste repo (hoje só sobrevive como binário em cache — dívida do SA-1, a resolver antes da D3).

### 3.3b AT-2 — ASR (Whisper ONNX + Silero VAD) — **PASSOU** no moto g86

Relatório: [spikes-android/AT2.md](spikes-android/AT2.md).

Metodologia nova: áudio de teste **sintetizado** via Piper (mesma engine de produção) com pausas fixas entre frases, dando uma verdade conhecida (ground truth) do início real de cada fala — em vez de comparar dois backends de ASR ruidosos entre si.

- **6 combos** (en/pt/es × whisper-tiny/whisper-base) rodados no device via app de benchmark descartável: RTF 0,138–0,267 (teto: <1), pico do processo 711 MB (teto: 1,5 GB), **zero** regressão de timestamp e **zero** janela perdida nos 6 combos.
- **Confirmado empiricamente:** `enableSegmentTimestamps` não devolve timestamps nativos do Whisper no sherpa-onnx 1.13.4 — o VAD como segmentador (§8/P3) é obrigatório, não uma opção; fecha uma dúvida que a auditoria original tinha levantado.
- **Sincronia** (baseline `whisper-cli` desktop real + `buildDubbingSegments`, mesmo segmentador dos dois lados): ≥90% em 5/6 combos (96–99%). O 6º (`es/best`) mediu 69,7% — verificado com **mediana de N=5 runs** (idêntico: whisper-cli é determinístico), é **viés sistemático do `whisper-small` desktop neste material espanhol** (66,7% contra o ground truth, erro de até 861 ms; o `whisper-base` desktop acerta 100% no mesmo áudio). O **device**, medido contra o mesmo ground truth, acerta **99%** nesse combo — idêntico aos outros 5. A divergência é 100% atribuível ao baseline.
- **Achado de storage (não bloqueia produção):** arquivos copiados via `adb push`/`adb shell mkdir` para dentro da pasta externa do app ficam com dono `shell` e o Android nega acesso ao **próprio app** — só o que o processo do app cria sobrevive. Contorno do spike: assets em `/data/local/tmp`, copiados pelo app no primeiro start. Produção não é afetada (`ModelManager` sempre escreve pelo processo do app).

### 3.3c AT-2b — TTS Piper (VITS via `sherpa_onnx`) — **PASSOU** no moto g86

Relatório: [spikes-android/AT2.md](spikes-android/AT2.md) §8.

Reaproveitou o mesmo app de benchmark do AT-2 (já instalado no device, mesmo contorno de storage) — só o corpo mudou, de ASR para TTS. Testava a premissa não verificada do §11.4: o `sherpa_onnx.OfflineTts` (VITS) — o **mesmo caminho de código** que `piper_synthesizer.dart` já usa em produção no desktop — carrega e sintetiza igual sobre o **binário nativo do Android** (`.so` arm64 em vez da `.dll` win-x64), com as mesmas vozes.

- **20 frases/idioma** (en/pt: as 20 primeiras da suíte do AT-1; es: tradução literal das mesmas 20), zero vazias: RTF 0,135–0,139 (teto: <0,3), pico do processo 690 MB (teto: 1,5 GB).
- **Extração do pacote de voz** (`.tar.gz`, 67–80 MB, via `package:archive` — Dart puro, D-c) medida no device: 1,9–2,3 s.
- **Reamostragem para PCM16 mono 44,1 kHz + reabertura**: sucesso nos 3 idiomas (validado com um resampler/writer/reader WAV próprios do spike, já que o FFmpegKitNext do AT-3 ainda não existe).
- **Cancelamento entre segmentos**: interrompido a meio de um lote de 20, `free()` + reinstanciação do `OfflineTts` bem-sucedida nos 3 idiomas — sem sessão órfã.
- **Achados laterais:** `espeak-ng-data` é byte-idêntico entre as 3 vozes (candidato a asset compartilhado no catálogo); `es_ES-sharvard-medium` é um modelo multi-locutor (2 *speakers*, sid=0 já válido).

### 3.3d Infraestrutura de produção — extração em streaming e asset compartilhado

Os dois achados laterais do AT-2b (extração em memória cheia no spike, `espeak-ng-data` triplicado) viraram pendências de melhoria registradas em [spikes-android/AT2.md](spikes-android/AT2.md) §7. Implementadas em código de produção nesta etapa — **escopo combinado com o usuário**: só o mecanismo, testado com fixtures sintéticas; nada migrado nas 58 vozes reais do catálogo Windows, nenhuma URL inventada para um `ModelCatalog.android()` (que ainda não existe).

- **Extração `.tar.gz` em streaming.** `ModelManager.download()` ganhou `kind: 'targz'`: baixa o pacote e extrai via `extractFileToDisk` do `package:archive`, que decodifica o gzip e escreve cada entrada por `InputFileStream`/`OutputFileStream` — sem materializar o pacote inteiro num buffer único em RAM (o que o app de benchmark do AT-2b fazia com `GZipDecoder().decodeBytes`). Reusa o mesmo padrão do caminho `tarbz2` existente (extrai num `.extract` temporário, achata um diretório de topo se houver via `_moveContentsUp`, valida SHA-256, limpa o intermediário). `archive` migrou de `dev_dependencies` para `dependencies` no `pubspec.yaml` do engine — antes só era usado por `tool/check_native_libs.dart`.
- **Asset de modelo compartilhado.** `ModelEntry` ganhou `dependsOn` (IDs de outras entradas que devem estar prontas junto) e `ModelCatalog` ganhou `resolveRequiredIds()`, que expande uma lista de IDs para incluir as dependências transitivas — deduplicado, seguro contra ciclo. Dá a um catálogo futuro a capacidade de declarar `espeak-ng-data` como uma entrada baixada/extraída **uma vez**, referenciada por várias vozes, em vez de duplicada dentro do pacote de cada uma.
- **Bug real encontrado ao testar (corrigido junto):** `stateOf()` e `download()` liam `manifest.firstWhere(...)` — o manifest **estático** do Windows (`ModelCatalog.windows().entries`) — em vez de `catalog.entryOf(id)`, a instância injetada no construtor do `ModelManager`. Ou seja: qualquer `ModelManager` construído com um `catalog` customizado (o meu teste com uma entrada `targz` sintética, e no futuro qualquer catálogo Android) já falhava com `Bad state: No element` nessas duas operações — as mais fundamentais da classe. Não era um problema hipotético; era um bug latente que só não tinha sido pisado ainda porque nada além do `ModelCatalog.windows()` default tinha sido exercitado via `download()`/`stateOf()` até agora.
- **7 testes novos** em `model_manager_test.dart`: 2 de extração `targz` (fixture real gerada com o encoder do `package:archive`, servida por um `HttpServer` local — um caso flat, um com diretório de topo tipo os pacotes `tts-models` do sherpa-onnx hoje) + 5 de `resolveRequiredIds` (sem dependência, dependência compartilhada por duas vozes, transitividade, ciclo, ID sem entrada no catálogo).

### 3.3e AT-3 — FFmpegKitNext LGPL próprio — **PASSOU** no moto g86

Relatório: [spikes-android/AT3.md](spikes-android/AT3.md); plano de execução com histórico: [AT3-plano.md](spikes-android/AT3-plano.md).

O único gate que exigia **compilar** um binário nativo próprio (não há build LGPL publicado do FFmpegKitNext). Feito em duas fases:

- **Fase 1 — build LGPL** via GitHub Actions (rota decidida com o usuário; o `nix-android.sh` é Linux-only e o WSL local está sem distro). FFmpegKitNext **v8.1.0** (commit `3e223118…`), arm64-v8a only, API 28, `--enable-openh264`, **sem `--enable-gpl`**. O workflow versionado (`.github/workflows/build-ffmpeg-kit-next.yml`) é o script de build reproduzível. Levou 6 iterações — nenhuma foi o FFmpeg falhando (ele compilou de primeira); foram bugs no meu script de evidências, sendo o mais importante que a prova de licença tem de vir do **binário** (`strings libavutil.so`, macro `FFMPEG_CONFIGURATION`), não de `grep "configuration:"` na árvore-fonte, que só pega format strings — os gates "passavam" sem checar nada até eu baixar o AAR e inspecionar à mão.
- **Fase 2 — matriz no device.** App de bench descartável (`at3_bench`) com o AAR local e uma ponte Kotlin MethodChannel (API v8.1.0 verificada via `javap` — a interface `Session` usa funções, `ReturnCode`/`Statistics` usam propriedades). Os **13 casos** rodaram no moto g86 sobre esse build, comandos copiados literais do código de produção, cada output reaberto e validado por ffprobe: probe/demux/atempo/asetrate/sidechain+amix+loudnorm/segment/concat/aac/mux `-c:v copy`/re-encode openh264. Os primitivos do §12.3 provados: progresso (10 amostras de statistics), **cancelamento** (`returnCode=255`, `isCancel=true` — o sinal que o `FFmpegKitNextRunner` da D3 vai mapear) e **timeout** (`timedOut=true`, distinguível). `ALL_OK=true`.
- Todas as 10 `.so` do AAR com `LOAD Align=0x4000` (16 KB), verificado com `readelf -lW` (o `-W` é obrigatório: sem ele o readelf quebra `LOAD` em duas linhas e esconde a coluna de alinhamento).

### 3.3f D3.0 — Scaffold `app/android` — **feito**, primeiro build sobe no moto g86

Início da fase D3 (casca Android M1), decisão do usuário 2026-07-15: iniciar a integração e validar AT-4/AT-5 dentro dela, em vez de mais spikes descartáveis — os 5 gates de primitivo isolado (AT-0…AT-3) já estavam todos verdes, e a casca em si (service, SAF, StatFs) não é isolável de `app/android` existir de verdade.

- `flutter create --platforms=android .` dentro de `app/`, preservando `lib/` e `windows/` intactos (§13.1). Ajustado manualmente porque o gerador usa o nome do pacote Dart (`omnitranslator_app`) como applicationId, e a spec pede o nome do produto: `applicationId`/`namespace` = **`com.luistiagos.omnitranslator`**, `MainActivity.kt` movido para o pacote certo.
- `minSdk=28`, NDK fixado em **27.0.12077973** (o default do Flutter pode ser mais velho; sherpa e o FFmpegKitNext do AT-3 exigem r27+ para alinhar 16 KB por padrão), Java/Kotlin 17, `abiFilters=["arm64-v8a"]`, `packaging.jniLibs.useLegacyPackaging=false` (§13.1/§13.2/§16.1).
- Manifest mínimo do §13.3: `INTERNET`, `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PROCESSING` — sem `MANAGE_EXTERNAL_STORAGE`/`READ_MEDIA_VIDEO`.
- `gradle.properties` com os mesmos ajustes anti-OOM já provados nos spikes ([[at3-ffmpeg-passou]]): `-Xmx768m`, Serial GC, Kotlin in-process, 1 worker — o default do template (`-Xmx8G`) é o que estourava o commit charge desta máquina.
- **Build debug arm64 subiu no moto g86** (PID vivo). `sherpa_onnx` já aparece como dependência transitiva do `dubbing_engine` mesmo sem nenhum backend Android escrito ainda — 5 `.so` no APK real (`libflutter`, `libVkLayer_khronos_validation` — só debug, tooling do Vulkan/Impeller —, `libonnxruntime`, `libsherpa-onnx-c-api`, `libsherpa-onnx-cxx-api`).
- **Fecha a confirmação de runtime que o AT-0 tinha deixado pendente** (§16.1): `zipalign -c -P 16 -v 4` no APK real → **Verification succesful**; `readelf -lW` em todas as 5 `.so` → **todos os `LOAD` com `Align` múltiplo de 16 KB** (sherpa/ORT em `0x4000`; `libflutter.so` e a lib de validação Vulkan em `0x10000` — mais rígido, também compatível: 65536 = 4×16384). Reconfirmado na P2 da revisão de 2026-07-16 com `libslimt.so` real dentro do APK (empacotado via `jniLibs`, ver §3.3j/P2): também `Align=0x4000` nos 3 `LOAD`. Só falta o teste num emulador/device Android 15+ de página 16 KB **de verdade em runtime** (o g86 é 4 KB e não exercita isso — todas as confirmações acima são estáticas, via `readelf`, não um boot real em kernel 16 KB).
  - **Rotas reais para fechar isso (P5 da revisão de 2026-07-16, não executadas ainda):** (a) a developer option "Boot with 16 KB page size" — Android 15+ expõe isso em alguns devices (Options for Developers); checar se o moto g86 (Android 16) tem essa opção quando o USB voltar, junto do smoke test da §3.3j; (b) um device físico com kernel 16 KB nativo (nenhum disponível agora); (c) build x86_64 dos nativos só para esse teste específico — custo alto (recompilar sherpa/ONNX Runtime/slimt/FFmpegKitNext pra x86_64), última opção. Um AVD x86_64 de 16 KB **não serve**: os nativos do projeto são `arm64-v8a`-only (`abiFilters`), e rodar um AVD arm64 num host Windows x86 é inviável (sem aceleração de hardware).
- `tool/verify.ps1` continua verde (323 testes) — nada no engine mudou, só a casca nova.

### 3.3g D3.1 — Armazenamento/SAF — **AT-5 PASSOU** no moto g86

- `AndroidDiskSpaceProbe implements DiskSpaceProbe` (`disk_space_probe.dart`) — injeta um callback assíncrono em vez de chamar `MethodChannel` direto, porque o `dubbing_engine` é Dart puro (zero dependência de `package:flutter`, mesma regra que já valia para `MediaToolRunner`/`RunToolFn`).
- `app/lib/src/platform/android_storage.dart` — a ponte real do app: `createAndroidDiskSpaceProbe()`, `pickImportDocument()`, `pickExportLocation()`, `copyUriToLocalFile()`, `copyLocalFileToUri()`, todas sobre `MethodChannel('omnitranslator/storage')`.
- `MainActivity.kt` ganhou o handler do canal: `StatFs` (sobe a árvore até achar um ancestral que existe), `ACTION_OPEN_DOCUMENT`/`ACTION_CREATE_DOCUMENT` via **`startActivityForResult`/`onActivityResult` clássico** — `FlutterActivity` estende `Activity` puro, não `ComponentActivity`, então `registerForActivityResult` não está disponível mesmo com `activity-ktx` declarado (achado verificado: adicionar a dependência não resolveu o erro de compilação; só a troca de padrão resolveu).
- **Validado no device com o app de produção** (não um bench descartável): `main.dart` foi trocado temporariamente por uma tela mínima de 5 botões só para poder rodar os MethodChannels sem esperar o `AndroidRuntime` (D3.2), depois revertido byte a byte (`diff` conferido) antes do commit — nenhum código de teste ficou no `main.dart` commitado.
- **Resultados:** `StatFs` devolve espaço real (170 GB livres); import e export SAF fazem round-trip **byte-exato com hash MD5 idêntico** nas duas direções; `extractFileToDisk` (a mesma função do `ModelManager` para `kind: 'targz'`) extraiu um modelo de tradução real de 16,7MB em 17,5s no device — achado para a D3.4: vale mostrar progresso na UI de download de modelos, porque o decoder gzip é Dart-puro e não é instantâneo em modelos maiores.
- Relatório completo, com as duas tabelas de hash e a análise do provedor externo: [spikes-android/AT5.md](spikes-android/AT5.md).
- `tool/verify.ps1` continua verde; 2 testes novos no engine (`AndroidDiskSpaceProbe`) e 7 testes novos no app (`android_storage_test.dart`, travando o contrato Dart↔Kotlin: nomes de método e chaves de argumento).

### 3.3h Pré-requisito da D3.2 — build versionado da `libslimt.so` (dívida do SA-1) paga

- `.github/workflows/build-slimt.yml` (mesmo padrão do AT-3) + patches versionados em `tool/android/slimt-patches/` — os dois patches que o SA-1 tinha aplicado manualmente (remover `-Werror`; fix de generator/`BUILD_BYPRODUCTS` no `FindPCRE2.cmake` pro Ninja), recuperados do checkout intacto que ainda sobrevivia em cache de uma sessão anterior. Fonte pinada: `jerinphilip/slimt` commit `9f0b1a20d14871cc94dbe65b7a3df128e5e81f55`, o mesmo do SA-1.
- **Achado de licença, tratado antes de escrever o build**: o `LICENSE` do slimt é **GPLv2 genuíno**, conflitando com a regra §16/#6 da spec ("sem GPL no binário distribuído"). Nunca tinha sido checado no SA-1/AT-1 (que avaliaram só viabilidade técnica). Decisão do usuário: prosseguir mesmo assim, linkando in-process como a §10.3 já especifica — risco registrado em `decisoes.md`, a ser revisitado antes do release (o checklist de D4 vai reprovar formalmente enquanto isso não for resolvido).
- **Achado técnico**: NDK r27 **base** (27.0.12077973, a mesma versão pinada em `app/android`) **não** alinha 16 KB por padrão — a primeira tentativa de build reprovou com `Align=0x1000`. Corrige a suposição repetida nesta sessão ("NDK ≥ r27 alinha por padrão"), que nunca tinha sido testada contra um build próprio do zero. Corrigido passando a flag de linker explicitamente (`-Wl,-z,max-page-size=16384`) em vez de confiar em defaults por versão de NDK.
- Segunda tentativa passou os 4 gates automatizados; artifact baixado manualmente e **reverificado de forma independente** (`llvm-readelf`/hash locais reproduzem exatamente o que a CI reportou — mesmo padrão de rigor do AT-3, não confiar só no self-report).
- Smoke test funcional no device (comparar tradução contra a saída original do SA-1) ficou pendente — o moto g86 não respondeu ao adb no momento (sem prompt de autorização, provável cabo/porta só-carga). Não bloqueia o pré-requisito: a evidência estrutural (hash, alinhamento, dependências dinâmicas idênticas ao SA-1) já é suficiente.
- Relatório completo: [spikes-android/slimt-build.md](spikes-android/slimt-build.md).

### 3.3i D3.2 — `ModelCatalog.android()` escrito e publicado (Release `android-models-v1`)

- `tool/mirror_models.dart` (novo): baixa cada asset upstream (k2-fsa/sherpa-onnx tag `asr-models`; Remote Settings da Mozilla para os 4 pares de tradução), reempacota em `.tar.gz`, calcula SHA-256 e publica como asset da Release `android-models-v1` do próprio repositório (§6.1.1/D-c) — nunca aponta direto pro upstream. 11 entradas: `whisper-android-{tiny,base}`, `silero-vad`, `espeak-ng-data` (compartilhado via `dependsOn` — confirmado byte-idêntico entre as 3 vozes com `diff -rq`), `piper-android-{en,pt-br,es}`, `mt-tiny-{enpt,pten,enes,esen}`.
- Todas as URLs upstream verificadas contra a API/índice ao vivo antes de usar, nenhuma inferida. **Achado no processo**: o hash de `base-encoder.int8.onnx` no AT2.md estava errado (erro de medição do AT-2 original — o asset no GitHub segue intocado desde 2024-10-02); corrigido, ver AT2.md.
- **Dois bugs reais de produção achados e corrigidos** rodando `ModelManager.download()` de verdade contra a Release publicada (não só confiando nos hashes impressos pelo script): (1) `tar -czf` não é determinístico — corrigido zerando o timestamp do gzip e normalizando mtimes antes de empacotar (o hash que vai pro catálogo é sempre medido no arquivo realmente publicado); (2) **`_verifyAndWriteSha256` hasheava o primeiro arquivo extraído em vez do pacote baixado** — inofensivo no catálogo desktop (nenhuma entrada legada tem `sha256` não-nulo) mas quebrava toda entrada Android nova (hash comparado contra o arquivo errado, `espeak-ng-data` — cujo `expects` é um diretório — lançava `PathNotFoundException`). Corrigido: a verificação agora roda no arquivo baixado, antes de extrair (mais correto — é o que o "digest" do GitHub realmente descreve — e não muda o comportamento das 64 entradas legadas).
- Todos os 11 assets confirmados com download real ponta a ponta (`ModelManager.download()` completo, `stateOf == ModelState.ready`) contra a Release ao vivo antes do commit. `tool/verify.ps1` verde (334 testes, +9 novos pro `ModelCatalog.android()`).

### 3.3j D3.2 — backends Android + `androidRuntime()` escritos

Os 4 backends concretos + o runtime que os monta — espelha `desktop_runtime.dart`, mas para o Android.

- **`AndroidTranslator`** (slimt via `dart:ffi`): a C-API do §10.3 (`ot_translator_create/translate/free`, `ot_string_free`) não existia no slimt upstream — foi escrita (`OtTranslatorCapi.cc`, patches 0003/0004) e adicionada direto ao `SLIMT_SOURCES` do `libslimt.so` (sem precisar de `.so` nova). **Compilada e linkada localmente** contra o build do SA-1 antes de subir (os 4 símbolos confirmados na tabela dinâmica via `llvm-nm`); a CI (`build-slimt.yml`) ganhou um **Gate 5** que reconfirma isso a cada build. O `config_path` da C-API é um contrato interno do wrapper (texto de 2 linhas: model, vocabulary) — não normativo, a spec só define a assinatura `extern "C"`. `AndroidTranslator` pivota pt↔es por inglês (Android M1 só tem modelo direto en↔pt/en↔es) e aplica `dedupRepeatedTail` obrigatoriamente (§10.4/AT-1). 13 testes com bindings falsos (`SlimtBindings` injetável — o `.so` real só existe compilado pra arm64, não roda neste desktop).
- **`AndroidTranscriber`** (Whisper ONNX + Silero VAD via sherpa-onnx): espelha o código já provado no device pelo AT-2 (`at2-bench-main.dart`, RTF 0,138-0,267, 96-99% de sincronia). O VAD já segmenta na fala real, então — ao contrário do `WhisperTranscriber` do desktop — não precisa de `trimSegmentsToSpeechFromFile`.
- **`AndroidSynthesizer`** (Piper/VITS via sherpa-onnx): mais simples que o `PiperSynthesizer` do desktop — Android M1 é voz única (sem diarização/elenco por perfil de falante). **Achado de design**: `espeak-ng-data` é uma entrada COMPARTILHADA do catálogo (`dependsOn`), não embutida dentro do pacote de cada voz como no desktop — o `dataDir` aponta pro destDir da própria entrada `espeak-ng-data` (`models.pathOf('espeak-ng-data')`), não pro destDir da voz.
- **`FFmpegKitNextRunner`** (FFmpegKitNext via MethodChannel, API provada pelo AT-3): **achado de arquitetura corrigido durante a escrita** — a primeira versão importava `package:flutter/services.dart` direto no engine, o mesmo erro que o `AndroidDiskSpaceProbe` da D3.1 já tinha resolvido (`dubbing_engine` é Dart puro). Corrigido injetando 4 callbacks (`start`/`poll`/`cancel`/`ffprobe`) em vez do `MethodChannel` — a ponte real (`app/lib/src/platform/android_ffmpeg.dart`) fica na camada do app, mesmo padrão do `android_storage.dart`. Timeout e cancelamento espelham `process_runner.dart` (`Timer` + `token.addCancellable`); progresso (`onProgress`) só é reportado quando o comando declara `-t <segundos>` explícito (sem isso não há como converter `statTimeMs` em 0..1 — nenhum chamador usa ainda, é preparação pra D3.3/D3.4). 8 testes com callbacks falsos + 3 testes do lado app com `MethodChannel` mockado (mesmo padrão do `android_storage_test.dart`).
- **`androidRuntime()`**: `createSeparator` é **obrigatório** em `DubbingRuntime` (não nullable, ao contrário de `createDiarizer`/`createDownloader`) — **achado ao escrever**: `pipeline.dart` chama `runtime.createSeparator()` incondicionalmente e distingue `SeparationOutcome.failure(notSupportedOnPlatform)` pra emitir evento informativo em vez de warning (§5.9); a primeira versão tentava um `throw`, que teria quebrado esse caminho. Corrigido com um `_NoSeparator` que devolve o outcome certo.
- Smoke test funcional no device (chamar `ot_translator_translate`/`AndroidTranscriber`/`AndroidSynthesizer` de verdade) fica pendente — mesma causa do §3.3h (moto g86 sem responder ao adb). `tool/verify.ps1` verde: engine com 355 testes (+21 — 13 `AndroidTranslator`, 8 `FFmpegKitNextRunner`), mais 3 novos no app (`android_ffmpeg_test.dart`).

**Revisão pós-D3.2 (2026-07-16, pedida pelo usuário):** cruzando cada backend contra o que o `pipeline.dart` faz em runtime (não contra os testes, que mockam as bordas), foram achados e corrigidos **2 bugs críticos** — (1) o `AndroidTranscriber` recebia o `audio_full.wav` de 44,1kHz estéreo e tratava como 16kHz mono (agora converte via `MediaToolRunner` injetado, gerando o `asr_in.wav` que o pipeline também usa pro trim); (2) os handles nativos do `AndroidTranslator` vazavam a cada job (interface `Translator` ganhou `dispose()` + `try/finally` no pipeline, como o `Synthesizer` já tinha) — mais ANR risk nas cópias SAF do `MainActivity.kt` (movidas pra background thread), pick duplo pendurando Future, e 2 guards de prontidão com mensagem clara. Detalhes em `decisoes.md` (2026-07-16). 358 testes no engine (+3), APK debug rebuilda.

### 3.3k Pendências fechadas após a revisão (2026-07-16)

Ao planejar o smoke test on-device ficou evidente uma lacuna que nenhum doc tinha listado: o `AndroidTranslator` abre `libslimt.so` via `dart:ffi`, mas nada empacotava essa `.so` no APK. Fechado junto com as demais pendências acumuladas na sessão:

- **P1 — distribuição permanente**: os artifacts do `actions/upload-artifact` expiram em ~90 dias e exigem login pra baixar. `build-slimt.yml` ganhou um passo final (só roda se os 5 gates passaram e é push de tag real) que publica `libslimt.so`, `slimt-cli`, `LICENSE-slimt.txt` e `SHA256SUMS.txt` como assets de uma **Release permanente na própria tag** (`at-slimt-build-4`) — pública, sem expiração, mesmo raciocínio que levou os modelos pra `android-models-v1`. Hash do download confere byte a byte com o publicado.
- **P2 — empacotar no APK**: `tool/android/fetch_native_libs.ps1` (novo) baixa `libslimt.so` da Release do P1, verifica o SHA-256 **pinado no próprio script** e coloca em `app/android/app/src/main/jniLibs/arm64-v8a/` (path padrão do Android Gradle Plugin — nenhuma mudança de `build.gradle.kts` necessária; `.so` não entra no git, o hash pinado é a proveniência, mesmo padrão do `ModelCatalog`). Verificado ponta a ponta: `flutter build apk --debug` → `.so` presente no APK (tamanho bate) → `zipalign -c -P 16` → **Verification succesful** → `readelf -lW` na `.so` extraída do APK real → 3 `LOAD` em `Align=0x4000`.
- **P3 — harness de smoke test versionado**: `tool/android/smoke/` (`smoke_main.dart` + `smoke_ffmpeg_handler.kt.snippet` + `README.md`) — mesmo padrão de swap temporário do `main.dart` já usado (e revertido) na D3.1, mas desta vez o harness em si fica commitado. Cobre catálogo real, `AndroidTranslator`, `AndroidTranscriber` e `AndroidSynthesizer` com FFI de verdade. **Compilação validada** fazendo o swap real (`flutter analyze` limpo) e revertendo antes de commitar (`git status` confirmado vazio). **Achado ao escrever**: o botão de transcrição precisa do AAR do FFmpegKitNext no `build.gradle.kts` — que **ainda não está declarado**, mesma classe de lacuna que o P2 fechou pro slimt; documentado no `.snippet`, não bloqueia os outros 3 botões nem os itens 1/2/4.
- **P4 — risco GPL do slimt, investigado**: licenças verificadas na fonte (não inferidas) das 3 dependências que a rota de fallback (`bergamot-translator`, já prevista na spec §10.2) arrastaria — todas permissivas: `bergamot-translator` = MPL-2.0, `marian-dev` (o fork que faz a inferência) = MIT, `ssplit-cpp` = Apache-2.0. Recomendação escrita em `decisoes.md` (2026-07-16): trocar pro bergamot-translator resolve a licença **e** dá paridade de qualidade com `base-memory` (que o slimt nunca teve); isolar o `slimt-cli` como subprocesso é a correção rápida de baixo risco se o prazo apertar. Decisão de rota fica com o usuário.
- **P5 — rotas do AT-0 16KB documentadas** (ver §3.3f acima) — nenhuma executada ainda, precisa do device.
- **P6 — itens de UI já rastreados pra D3.4**: reafirmados, sem ação de código agora — export SAF com nome+MIME coerentes, progresso de extração `.tar.gz` na tela de modelos, teste manual de provedor externo (Drive), migração dos 4 usos síncronos de disco do `home_screen.dart` pro probe assíncrono cacheado (todos já em `spikes-android/AT5.md` §6).

### 3.3l Lacuna do AAR do FFmpegKit fechada (F1-F4, 2026-07-16)

O P3 documentou mas não fechou: nada empacotava o AAR do FFmpegKitNext (AT-3) no APK — `app/lib/src/platform/android_ffmpeg.dart` chama um `MethodChannel` cujo handler Kotlin (`smoke_ffmpeg_handler.kt.snippet`) usa `com.arthenica.ffmpegkit.*`, mas essas classes não existiam no classpath do app. Fechado:

- **F1 — distribuição permanente**: `build-ffmpeg-kit-next.yml` ganhou o mesmo passo do P1 (`permissions: contents: write` + publish condicional em `if: success() && startsWith(github.ref, 'refs/tags/')`) — a run `at3-ffmpeg-build-7` publicou `ffmpeg-kit.aar` (8.731.233 bytes) + `SHA256SUMS.txt` como Release permanente. Hash conferido por download independente (`sha256sum` local bate com o `digest` da API do GitHub e com o `SHA256SUMS.txt` publicado).
- **F2 — fetch com verificação**: `tool/android/fetch_native_libs.ps1` ganhou um segundo laço (`$aars`, além do `$nativeLibs` já existente) — mesma lógica de hash pinado no script, mas destino diferente: `app/android/app/libs/` (não `jniLibs/<abi>/`, porque um AAR precisa de uma dependência Gradle explícita, não é auto-empacotado). `app/android/.gitignore` ganhou `app/libs/`.
- **F3 — wiring no Gradle**: `app/android/app/build.gradle.kts` ganhou `dependencies { implementation(files("libs/ffmpeg-kit-next.aar")) }` — dependência de arquivo local, não Maven (não resolve POM transitivo, mas o `aar-metadata.properties` do FFmpegKitNext não tem dependências transitivas incomuns). Verificado ponta a ponta com o AAR baixado pelo F2 (não uma cópia manual): APK final tem as 16 `.so` esperadas (10 do FFmpegKit + `libslimt.so` + sherpa/ONNX/flutter/Vulkan, `libc++_shared.so` deduplicada), `zipalign -c -P 16` → **Verification succesful**, `readelf -lW` em todas as 16 → todos os `LOAD` com `Align` múltiplo de 16384 (a maioria `0x4000`, `libflutter.so`/`libVkLayer_khronos_validation.so` em `0x10000`, ambos compatíveis).
- **F4 — API do handler Kotlin confirmada contra o AAR real (não só suposta)**: colar o bloco do `.snippet` dentro de `MainActivity.configureFlutterEngine()` (splice temporário, revertido antes de qualquer commit — `git diff` conferido vazio) revelou que a doc anterior do AT-3 estava **incompleta**: `Session`/`FFprobeSession` são Kotlin (não Java), mas seus membros (`sessionId`, `returnCode`, `output`, `allLogsAsString`) são **funções** Kotlin explícitas — Kotlin só mapeia `getX()`→`.x` automaticamente pra código declarado em Java, então é preciso chamar `.getSessionId()`, `.getReturnCode()`, `.getOutput()` etc., nunca a sintaxe de propriedade. (`ReturnCode.value` e `Statistics.time`, ao contrário, SÃO propriedades Kotlin de verdade — funcionam com `.value`/`.time`.) Além disso, as interfaces de callback (`FFmpegSessionCompleteCallback`, `LogCallback`, `StatisticsCallback`) não são `fun interface` — lambda solta (`{ }`) não faz SAM conversion, precisa de `object : Interface { override fun apply(...) { } }` explícito. `smoke_ffmpeg_handler.kt.snippet` corrigido com a API testada; a ressalva de "gap aberto" removida dele e do cabeçalho do `smoke_main.dart`.

**Achado colateral (não relacionado ao AAR):** esta máquina tem headroom de commit charge (`FreeVirtualMemory` do Windows) mais apertado que RAM livre sugere — o pagefile fixo (~4GB) é o teto real, não os ~31GB físicos. A extensão Kotlin do VSCode (`fwcd.kotlin`) sozinha chegou a consumir ~4GB e foi a causa de dois OOMs (nativo da JVM e heap do Jetifier) durante os rebuilds deste bloco; matá-la antes de builds pesados (ela reinicia sozinha quando o VSCode volta a precisar) é uma mitigação adicional às já registradas (matar `java.exe` zumbi, checar `Win32_OperatingSystem` antes do build).

### 3.3m D3.3 — `MediaProcessingService` (foreground service, §14/AT-4) — **feito**, compila contra o app real

Componentes novos: `MediaProcessingService.kt` (dono de um `FlutterEngine` HEADLESS separado do da `MainActivity` — padrão de execução headless do Flutter que não existia no repo, escrito do zero: `FlutterLoader` inicializado manualmente, `executeDartEntrypoint` apontando pro símbolo `serviceMain`) + `service_entrypoint.dart` (`serviceMain()`, `@pragma('vm:entry-point')`, roda `runDubbingJob` de ponta a ponta dentro do isolate do serviço) + `media_processing_service.dart` (cliente Dart tipado do lado Activity, consumido pela D3.4). Protocolo real (§14.2/§14.3/§14.4):

- `omnitranslator/service` (`MethodChannel`, Activity↔serviço): `startJob`/`cancelJob`.
- `omnitranslator/service/events` (`EventChannel`, serviço→Activity): os 5 eventos do §14.4 (`jobStateChanged`/`jobProgress`/`jobWarning`/`jobCompleted`/`jobFailed`), cada um com o `JobCheckpoint` inteiro + a mensagem pontual do `PipelineEvent`.
- `omnitranslator/service_worker` (`MethodChannel` interno, Kotlin↔isolate do job): `runJob`/`cancelJob` numa direção, os 5 eventos na outra.
- `getJob`/`listRecoverableJobs`/`exportJob` (§14.3) **não passam por canal nenhum** (decisão D-1) — leem/escrevem `job.json` direto via `FileJobCheckpointStore`, funcionando mesmo com o serviço morto (é exatamente o que o cenário de morte forçada do processo, abaixo, precisa).

**Escopo do MVP, decisão do usuário antes de implementar**: o serviço só *grava* checkpoints a cada transição de `JobState` (`jobStateForStage`/`applyPipelineEvent`, novos em `job_checkpoint_store.dart`, 6 testes novos) — não pula estágios já concluídos ao retomar. Isso basta pra 4 dos 5 cenários do §14.6: tela apaga, troca de app, rotação/recriação da Activity e Activity removida da memória com o serviço vivo são todos propriedades da arquitetura do serviço em si (`startForegroundService` independe de `bindService`; o `EventChannel` reconecta via `onListen`/`attachEventSink` quando a Activity reabre) — nenhum deles depende de retomar computação. Só o 5º cenário (morte forçada do processo, `adb shell am force-stop`) fica com crédito parcial: `listRecoverableJobs()` mostra o job depois de o processo inteiro morrer, mas "retomar" hoje significa `runDubbingJob` do zero de novo (reaproveita modelos já baixados em disco, não computação já feita) — lacuna documentada, não bug; fechar de verdade exige um `resumeFrom` real em `pipeline.dart` (compartilhado com o desktop), fora do escopo desta fase.

**Achados durante a implementação:**

- **`omnitranslator/ffmpeg` migrou de splice-temporário-em-`MainActivity` pra handler real do serviço** — reaproveitando literalmente a API confirmada no F4 (`smoke_ffmpeg_handler.kt.snippet`: getters explícitos como `.getSessionId()`, `object : Interface { ... }` em vez de lambda solta). O `.snippet` continua válido só como splice temporário do harness D3.2 (`smoke_main.dart`, que testa `AndroidTranscriber` direto no isolate da Activity, sem passar pelo serviço).
- **`getFreeBytes` precisou ser registrado UMA SEGUNDA VEZ**, no engine headless (não só na `MainActivity`): o estágio `prepare` do pipeline chama `runtime.diskSpace.freeBytes()` de dentro do isolate do job, que fala com o `binaryMessenger` do engine do SERVIÇO, não o da Activity — dois `FlutterEngine`s independentes no mesmo processo. Só ficou óbvio depois de mapear explicitamente de qual engine cada chamada de canal realmente sai.
- **`DubbingJobConfig` ganhou `toJson`/`fromJson`** (primeiro uso real — a config precisa cruzar o canal Activity→serviço, que não compartilha memória). Cuidado explícito: buscar `Lang` por `code`, não por `Lang.name`/`.byName` — divergem no islandês (`is` é palavra reservada em Dart, o identificador do enum é `isl`), testado especificamente (`models_test.dart`).
- **Compilação confirmada contra o app real** (`flutter build apk --debug --target-platform android-arm64`, não só `flutter analyze`) — achado no processo: o handler `ffmpegStart` colado em `MediaProcessingService.kt` tinha reintroduzido `session.sessionId` (a sintaxe de propriedade errada já corrigida uma vez no F4), por ter sido copiado da versão anterior à correção; o mesmo erro do Kotlin compiler do F4 (`Not enough information to infer type argument for 'V'/'B'`) apontou o problema, corrigido pra `session.getSessionId()`.
- **Checagens estáticas no APK real**: `<service android:name=".MediaProcessingService" foregroundServiceType="mediaProcessing">` presente no manifest mesclado (`aapt2 dump xmltree`); as 16 `.so` (inalteradas — esta fase é só Kotlin+Dart, nenhuma lib nativa nova) continuam passando `zipalign -c -P 16`.

10 testes novos no engine (368 no total) + 12 no app (`media_processing_service_test.dart`: contrato dos canais + `getJob`/`listRecoverableJobs`/`exportJob` contra um `FileJobCheckpointStore` real via `PathProviderPlatform.instance` mockado). Harness de validação versionado em `tool/android/smoke/smoke_service_main.dart` (mesmo padrão de swap temporário do `main.dart`, nunca commitado) com o roteiro manual completo dos 5 cenários do §14.6 no cabeçalho — pronto pra rodar, não executado (moto g86 sem `adb` a sessão toda). Wiring da UI de produção (`AppState`/`home_screen.dart`/`progress_screen.dart` falando com o serviço) é escopo explícito da D3.4, não desta fase.

### 3.4 D1 (parcial) — correções de qualidade no engine

Estas quatro correções **afetam o desktop hoje** — são bugs reais no produto atual, não preparação para o Android. Todas verificadas com o pipeline real rodando (whisper → translateLocally → Piper → ffmpeg), não só com testes unitários.

| # | O quê | Por quê | Arquivos |
|---|---|---|---|
| a | **Split na fronteira real.** O merge das palavras passou a guardar os constituintes; o corte por sentença cai na fronteira real entre eles, não numa repartição por proporção de caracteres. | Preserva os timestamps por palavra do whisper (`-ml 1 -sow`). Antes, duas frases com 300 ms de pausa terminavam/começavam ~150 ms errado. Melhora a sincronia nas duas plataformas. | `steps/segmenter.dart`, `test/segmenter_test.dart` |
| b | **Cauda da última fala.** `planDubSchedule` trata o fim do vídeo como prazo duro (acelera o último run até `tailSpeedMax = 1.65`, acima do teto normal de 1.5). O resíduo que ainda sobra é medido (`overflow`, `truncatedTail`), nunca cortado em silêncio. | `amix=duration=first` corta tudo que passa do fim do vídeo. `buildDubTrack` estendia o buffer justamente para preservar a cauda, e o mix a descartava — as duas funções se anulavam. Os campos `overflow`/`segmentsWithOverflow`, antes declarados e nunca escritos, agora são preenchidos. | `steps/fitter.dart`, `steps/mixer.dart`, `constants.dart`, `models.dart`, `test/fitter_test.dart`, `test/mixer_test.dart` |
| c | **`sync_report.json`.** O pipeline grava `<saída>.sync.json` com delta por fala, `%` dentro de ±300 ms, pior delta, estouros e cauda cortada. | Torna o critério de release ("≥90% em ±300 ms") um número medido pelo próprio pipeline, e dá ao Android um baseline de desktop para comparar — em vez de "diferença perceptual documentada". | `steps/sync_report.dart` (novo), `pipeline.dart`, `dubbing_engine.dart`, `test/sync_report_test.dart` (novo) |
| d | **Fallback do mux com `libopenh264`.** O re-encode usava `-c:v libx264`, que **não existe** no ffmpeg LGPL distribuído (`--disable-libx264`). | Falhava sempre no caminho que existe para salvar containers cujo codec o MP4 não aceita (VP9/WebM). Provado com um WebM/VP9 real: agora gera h264 + faixas aac. Os dois testes de muxer asseriam `libx264` com o ffmpeg **mockado**, por isso ninguém percebeu. | `steps/muxer.dart`, `constants.dart`, `test/muxer_test.dart`, `tool/integration_test.dart` |

> **Mudança de comportamento audível no desktop (item b):** em vídeos onde a dublagem passaria do fim, a última fala pode soar um pouco mais rápida (até 1.65×) em troca de não ser truncada. É a única mudança perceptível para o usuário final do desktop; as outras três são correções invisíveis ou melhorias.

### 3.5 D1 — os sete contratos (G-1…G-7) ✅

O que a auditoria chamava de "lacunas de contrato": a §5 se dizia normativa mas não definia essas interfaces, e o implementador teria de inventá-las.

| Contrato | O que mudou | Por que importa no Android |
|---|---|---|
| **G-2** `CancellationToken` | Largou a lista de `Process` do `dart:io` por um `addCancellable(onCancel)` genérico + `CancellationRegistration` e `throwIfCancelled`. O core **não importa mais `dart:io`**. | A regra #10 (FFmpeg, sherpa e loops Dart observando o mesmo token) era **impossível** com o contrato antigo, que só sabia matar subprocesso. |
| **G-3** `SeparationOutcome` | String livre → enum `SeparationFailureReason` + `detail` só-diagnóstico. O pipeline emite evento **informativo** (não warning) para `notSupportedOnPlatform`. | Voice-over é o modo **esperado** do M1, não uma falha técnica — a §8/P2 proíbe tratá-lo como warning. |
| **G-1/G-5/G-6** `DubbingRuntime` | `runDubbingJob` deixou de receber `tools`, `models` e cinco factories soltas; recebe **um** runtime. `pipeline.dart` **não importa nenhum backend concreto**. YouTube virou `MediaDownloader`; `createDownloader`/`createDiarizer` nulos = a plataforma não faz aquilo. | É o que permite um `androidRuntime()` sem tocar no pipeline. E a ausência de YouTube/diarização vira **recusa explícita**, não crash. |
| **G-7** `DiskSpaceProbe` | `freeBytesForPath` (FFI síncrono, Windows-only, chamado **de dentro do `build()`** 4× por frame) → interface async, medida fora do frame e cacheada por diretório. | No Android o `StatFs` vem por MethodChannel: um probe síncrono é impossível. Tirou o último import Windows-only do core. |
| **G-4** `ModelCatalog` | O `prepare` decidia os modelos com IDs hardcoded, e 3 backends + 3 telas liam o `manifest` estático. Agora o catálogo é por plataforma (`entries`, `asrModelIds`, `defaultVoiceIds`, `separatorModelId` **nulável**). | O mesmo ID não pode ser `.bin` no Windows e ONNX no Android. E o M1 **não tem separação** — o `prepare` exigia um modelo que a plataforma nunca usaria. |

`ModelCatalog.android()` foi deliberadamente **deixado de fora**: a spec (§6.1) proíbe inferir os nomes dos assets do sherpa, que o AT-2 vai fixar.

**Revisão dos contratos** (feita antes de seguir): G-3 saiu limpo; em G-2 achei e corrigi dois bugs reais — `cancel()` abortava os cancelamentos restantes se um deles lançasse (o que deixaria FFmpeg/sherpa órfãos, exatamente o que a §19.4 proíbe), e havia uma corrida de `stdin` com token pré-cancelado.

### 3.6 D1 — memória ✅ (§7 da spec)

Era **o** bloqueio do celular: a memória crescia com a duração do vídeo.

| Antes | Agora |
|---|---|
| O pipeline guardava a síntese de **todas** as falas num `List<Float32List>` antes de planejar. | Síntese em **duas passagens**: a fase 1 grava `seg_<id>_natural.wav` e retém só a **duração** — que é tudo de que o `planDubSchedule` precisa. |
| `DubbingSegment.fittedAudio` era um `Float32List` por fala, todas vivas até o mix. | O segmento carrega **paths e metadados** (`fittedAudioPath`, `fittedSampleRate/Count`); o natural é apagado assim que o fitted é validado. |
| `buildDubTrack` alocava **um `Float32List` do vídeo inteiro** e somava cada fala dentro dele. | **Writer sequencial**: escreve o silêncio da lacuna e copia os quadros PCM16 de cada fala — sem conversão para float, sem soma. O working set é um bloco de 64K quadros, **independente da duração**. |
| `asr_in.wav` era lido **inteiro, duas vezes por job** (~230 MB/hora). | `WavReader` por janela: cada segmento lê só o seu próprio trecho. |
| `writeWavPcm16` materializava uma `List<int>` **boxed** do arquivo inteiro (spread). | Duas escritas diretas, sem boxing. |

**Medido** (vídeo de 1 hora, 600 falas):

| | Pico de RSS do processo |
|---|---:|
| Buffer antigo (`Float32List` de 158.760.000 amostras = 605 MB) | **841 MB** (a alocação sozinha subiu o RSS em 592 MB) |
| Writer sequencial | **329 MB** — e nada disso escala com a duração |

O writer também passou a **rejeitar sobreposição** de falas em vez de somá-las em silêncio: o scheduler garante que não há sobreposição, então uma violação é um bug que merece aparecer (§19.1: "writer rejeita overlap").

### 3.7 D1 — o que fechou a fase

| Item | O que é | Por que importa no Android |
|---|---|---|
| **`MediaToolRunner`** (§5.2) | As etapas de mídia (`demux`, `fitter`, `mixer`, `muxer`) pediam um `.exe` + uma `RunToolFn` que chama `Process.start`. Agora pedem um `MediaToolRunner` e a **ferramenta** (`MediaTool.ffmpeg`), não um path. | No Android o ffmpeg é biblioteca in-process — não há `Process` nem path. **O `pipeline.dart` não referencia mais `Tools`, `RunToolFn` nem nenhum `.exe`**: o último resquício de "executável" saiu do core. Um `FFmpegKitNextRunner` entra sem tocar nas etapas. |
| **`JobCheckpointStore`** (§5.7/§9.4) | O último contrato que a §5 declarava e não definia. `FileJobCheckpointStore` grava `job.json` atomicamente (`.part`→flush→revalida→rename); `computeConfigFingerprint` decide se um job reaberto pode ser reaproveitado; `resolveResumeState` implementa o §9.4 (recua até o último estágio cujos artefatos validam). | É o que permite retomar um job depois de o processo morrer — requisito do foreground service (§14). A re-entrada mid-pipeline em si é da D3 (é lá que o serviço reinicia o job); aqui está o **store testado** que ele vai dirigir. |
| **`tool/verify.ps1`** + **`tool/check_native_libs.dart`** (D-d) | Sem CI, os gates são scripts locais. O `verify.ps1` roda analyze+testes do engine e do app com piso de contagem; o `check_native_libs.dart` inventaria as `.so` do APK/AAB por ABI/tamanho/hash e falha em ABI não autorizada. | Torna "os testes passam" e "não há ABI proibida" verificáveis, não afirmações de documento. |

Nada disso mudou comportamento do desktop — são portabilidade e ferramentas. `verify.ps1` foi rodado ponta a ponta (**VERIFY OK**), e o `check_native_libs.dart` foi exercitado em APKs falsos (falha no x86, passa só com arm64).

---

## 4. Verificação executada

- **`main`:** `dart test` → **199 passam** (baseline original preservado).
- **`android-port`:** `dart test` → **322 passam** (199 + 123 novos, incluindo os 31 casos do device usados no `dedupRepeatedTail` e os 7 de extração `targz`/`resolveRequiredIds`).
- **Integração ponta a ponta** (`tool/integration_test.dart`, en→pt, pipeline real com whisper-cli, translateLocally, Piper e ffmpeg): **9/9 asserções**, saída com a duração exata do vídeo e **100 % das falas dentro de ±300 ms**.
- `dart analyze` e `flutter analyze` sem erros nem warnings novos; teste de widget do app passa.

### 4.1 ⚠ A sincronia não é perfeitamente reprodutível

O `tool/integration_test.dart` **regerava a fixture a cada execução** com o Piper — que é um VITS com `noise_scale_w=0.8`, ou seja, **síntese estocástica**. Entrada diferente a cada run → segmentação e sincronia diferentes (medido: 4–6 unidades para o mesmo texto, 83 %–100 % de sincronia). A fixture agora é **congelada** (gerada uma vez e reusada).

Mesmo assim, com fixture de SHA-256 idêntico, a segmentação ainda oscila 5↔6 unidades. Investigado: **whisper-cli e spleeter são individualmente determinísticos** (transcript e vocals com hash idêntico em 3 execuções cada); o que sobra é jitter sub-ms da inferência nativa multi-thread, que ocasionalmente cruza o `mergeMaxPause` de 600 ms.

**Consequência para o gate:** o baseline de ±300 ms tem de ser a **mediana de N ≥ 5 execuções**, não um número único — senão o AT-2 compara ruído contra ruído. Registrado na spec (§11.3) e em `decisoes.md`.

> Nota de execução: rodar o pipeline via `dart run` falha ao carregar a DLL do sherpa (o Windows resolve o `onnxruntime.dll` 1.17.1 do System32 em vez do 1.27.0 do pacote). Compilar com `dart compile exe` e copiar os `.dll` de `sherpa_onnx_windows-1.13.4/windows/` para o lado do `.exe` resolve.

---

## 5. Pendente

### 5.1 D1 — concluída

Nada pendente na D1. O que era "desbloqueado, sem device" — contratos, memória, `MediaToolRunner`, `JobCheckpointStore`, scripts de gate — está feito e testado.

### 5.2 AT-1 e AT-2 — concluídos

Ambos passaram no moto g86 (§3.3, §3.3b). Resta só a dívida não bloqueante de versionar o build do `libslimt.so` (§5.3).

### 5.2b Bloqueado em pré-requisitos

- **AT-2b / AT-3 / AT-4 / AT-5:** exigem o aparelho e, alguns, `app/android/` gerado.

### 5.3 Dívidas registradas

- `libslimt.so` não versionado (SA-1 foi feito no protótipo irmão) — pagar antes da D3.
- Proveniência exata (URL/tag do release) dos assets `sherpa-onnx-whisper-tiny`/`whisper-base`/`silero_vad.onnx` a fixar no `ModelCatalog.android()` antes da D3 (hashes já medidos, ver `spikes-android/AT2.md` §6).
- Sem CI (decisão D-d) — os gates são scripts locais.
