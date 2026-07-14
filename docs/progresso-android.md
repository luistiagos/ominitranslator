# Progresso do port Android — registro de andamento

**Última atualização:** 2026-07-14
**Branch de trabalho:** `android-port` (todo o trabalho abaixo vive aqui; 17 commits à frente de `main`)
**Branch estável:** `main` em `b15c821` — desktop exatamente como antes, 199 testes; é a âncora para voltar se algo der errado.

> Este documento é o índice de andamento. Os detalhes de cada item estão nos documentos referenciados (spec, `decisoes.md`, relatórios de spike). Ordem normativa de trabalho: §17 de [especificacao-android.md](especificacao-android.md).

---

## 1. Estado por fase

| Fase | Item | Estado |
|---|---|---|
| Etapa 0 | Fechar a especificação (spec v2) | ✅ concluída |
| D0.5 | **AT-0** — gate de 16 KB | ✅ **PASSOU** (parte estática; runtime na D3) |
| D2 | **AT-1** — tradução pt | ✅ **PASSOU** no moto g86 (slimt + `dedupRepeatedTail`) |
| D2 | **AT-2** — ASR (Whisper ONNX + Silero VAD) | ✅ **PASSOU** no moto g86 (ver §3.3b) |
| D1 | Correções de qualidade no engine (valem p/ desktop) | ✅ 4 itens feitos e verificados |
| D1 | **Contratos G-1…G-7** | ✅ **concluídos** (ver §3.5) |
| D1 | **Refatoração de memória** (áudio em disco, writer sequencial, `WavReader`) | ✅ **concluída** (ver §3.6) |
| D1 | **`MediaToolRunner`** (§5.2) | ✅ **concluído** (ver §3.7) |
| D1 | **`JobCheckpointStore` + fingerprint + política de retomada** (§5.7/§9.4) | ✅ **concluído** (ver §3.7) |
| D1 | **`tool/verify.ps1` + `check_native_libs.dart`** (D-d) | ✅ **concluídos** (ver §3.7) |
| **D1** | **fase completa** | ✅ **o engine está pronto para o port** |
| D2 | AT-2b / AT-3 / AT-4 / AT-5 | ⬜ pendente (exigem device) |
| D3/D4 | Integração e aceite Android | ⬜ pendente |

**A fase D1 está concluída**, e **AT-0, AT-1 e AT-2 passaram no moto g86**. O engine foi refatorado no Windows — memória constante, contratos completos, nenhum `.exe` no core — e continua passando **315 testes** (era 199), com o pipeline real dublando ponta a ponta a 100% de sincronia. Os dois gates de device concluídos validam as duas peças de IA on-device mais arriscadas do M1 (tradução e ASR). O próximo passo real são os gates restantes (AT-2b TTS, AT-3 FFmpegKitNext, AT-4 foreground service, AT-5 SAF), todos exigindo device.

---

## 2. Estratégia de branches

| Branch | HEAD | Testes | Papel |
|---|---|---|---|
| `main` | `b15c821` | 199 | Desktop estável, intocado. Referência para regressão. |
| `android-port` | `8ad91bb` | 213 | Todo o trabalho do port + as correções de bug do engine. Onde evoluímos daqui. |

Motivo (decisão do usuário, 2026-07-12): as mudanças do engine afetam **ambas** as plataformas (o `dubbing_engine` é compartilhado), então, para não arriscar o desktop com nada não previsto, o trabalho ficou isolado no `android-port`. `main` só recebe quando estiver validado. Verificado rodando os testes em cada branch: `main` = 199 (baseline original), `android-port` = 213.

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
- **Sincronia** (baseline `whisper-cli` desktop real + `buildDubbingSegments`, mesmo segmentador dos dois lados): ≥90% em 5/6 combos (96–99%). O 6º (`es/best`) mediu 69,7% — mas só pela comparação literal a uma **run isolada e ruidosa** do baseline desktop (erro de até 861 ms contra o ground truth); o **device**, medido contra o mesmo ground truth, acerta **99%** nesse combo — idêntico aos outros 5. Confirma o que já estava registrado: o baseline desktop é uma faixa, não um número único.
- **Achado de storage (não bloqueia produção):** arquivos copiados via `adb push`/`adb shell mkdir` para dentro da pasta externa do app ficam com dono `shell` e o Android nega acesso ao **próprio app** — só o que o processo do app cria sobrevive. Contorno do spike: assets em `/data/local/tmp`, copiados pelo app no primeiro start. Produção não é afetada (`ModelManager` sempre escreve pelo processo do app).

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
- **`android-port`:** `dart test` → **315 passam** (199 + 116 novos, incluindo os 31 casos do device usados no `dedupRepeatedTail`).
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
