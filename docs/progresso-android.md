# Progresso do port Android — registro de andamento

**Última atualização:** 2026-07-12
**Branch de trabalho:** `android-port` (todo o trabalho abaixo vive aqui)
**Branch estável:** `main` em `b15c821` — desktop exatamente como antes, 199 testes; é a âncora para voltar se algo der errado.

> Este documento é o índice de andamento. Os detalhes de cada item estão nos documentos referenciados (spec, `decisoes.md`, relatórios de spike). Ordem normativa de trabalho: §17 de [especificacao-android.md](especificacao-android.md).

---

## 1. Estado por fase

| Fase | Item | Estado |
|---|---|---|
| Etapa 0 | Fechar a especificação (spec v2) | ✅ concluída |
| D0.5 | **AT-0** — gate de 16 KB | ✅ **PASSOU** (parte estática; runtime na D3) |
| D2 | **AT-1** — tradução pt | 🟡 fonte/licença/qualidade resolvidas; execução no device pendente |
| D1 | Correções de qualidade no engine (valem p/ desktop) | ✅ 4 itens feitos e verificados |
| D1 | Contratos G-1…G-7 | ⬜ pendente (próximo) |
| D1 | Refatoração de memória (áudio em disco, writer sequencial, `WavReader`) | ⬜ pendente |
| D1 | `tool/verify.ps1` | ⬜ pendente |
| D2 | AT-2 / AT-2b / AT-3 / AT-4 / AT-5 | ⬜ pendente (exigem device) |
| D3/D4 | Integração e aceite Android | ⬜ pendente |

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

### 3.3 AT-1 — tradução pt — fonte e qualidade resolvidas; device pendente

Relatório: [spikes-android/AT1.md](spikes-android/AT1.md).

**Correção de premissa importante:** o repositório arquivado `mozilla/firefox-translations-models` **não serve para download** — os arquivos estão em Git LFS e os objetos foram removidos do servidor (`410`). A fonte real é o **Remote Settings do Firefox** (CDN pública, com `location`, `size` e `hash` SHA-256 por registro). `version: "1.0"` = tier **tiny** (a arquitetura `ssru`/`dec-depth: 2` que o slimt suporta); `version: "2.x"` = `base-memory`.

- Download do modelo tiny en→pt verificado ponta a ponta (HTTP 200, 17.140.899 bytes, SHA-256 confere).
- Licença MPL-2.0.
- **Qualidade medida, não estimada** (BLEU/COMET dos `metadata.json`): nos pares de gate, o tiny perde só **0,6 BLEU em en→pt** e **0,1 em pt→en** ante o `base-memory`. Divergência desprezível.
- Subproduto: o modelo instalado no desktop é bit a bit idêntico ao registro v2.1 → fonte pública/hasheável para pt também no Windows (encerra um risco antigo do desktop).

**Bloqueado para a execução no device por dois pré-requisitos:** (a) o `libslimt.so` do SA-1 não sobreviveu — foi construído no protótipo irmão e não versionado, e precisa virar script de build neste repo; (b) nenhum aparelho conectado; (c) a suíte de 100 frases/direção ainda não existe.

### 3.4 D1 (parcial) — correções de qualidade no engine

Estas quatro correções **afetam o desktop hoje** — são bugs reais no produto atual, não preparação para o Android. Todas verificadas com o pipeline real rodando (whisper → translateLocally → Piper → ffmpeg), não só com testes unitários.

| # | O quê | Por quê | Arquivos |
|---|---|---|---|
| a | **Split na fronteira real.** O merge das palavras passou a guardar os constituintes; o corte por sentença cai na fronteira real entre eles, não numa repartição por proporção de caracteres. | Preserva os timestamps por palavra do whisper (`-ml 1 -sow`). Antes, duas frases com 300 ms de pausa terminavam/começavam ~150 ms errado. Melhora a sincronia nas duas plataformas. | `steps/segmenter.dart`, `test/segmenter_test.dart` |
| b | **Cauda da última fala.** `planDubSchedule` trata o fim do vídeo como prazo duro (acelera o último run até `tailSpeedMax = 1.65`, acima do teto normal de 1.5). O resíduo que ainda sobra é medido (`overflow`, `truncatedTail`), nunca cortado em silêncio. | `amix=duration=first` corta tudo que passa do fim do vídeo. `buildDubTrack` estendia o buffer justamente para preservar a cauda, e o mix a descartava — as duas funções se anulavam. Os campos `overflow`/`segmentsWithOverflow`, antes declarados e nunca escritos, agora são preenchidos. | `steps/fitter.dart`, `steps/mixer.dart`, `constants.dart`, `models.dart`, `test/fitter_test.dart`, `test/mixer_test.dart` |
| c | **`sync_report.json`.** O pipeline grava `<saída>.sync.json` com delta por fala, `%` dentro de ±300 ms, pior delta, estouros e cauda cortada. | Torna o critério de release ("≥90% em ±300 ms") um número medido pelo próprio pipeline, e dá ao Android um baseline de desktop para comparar — em vez de "diferença perceptual documentada". | `steps/sync_report.dart` (novo), `pipeline.dart`, `dubbing_engine.dart`, `test/sync_report_test.dart` (novo) |
| d | **Fallback do mux com `libopenh264`.** O re-encode usava `-c:v libx264`, que **não existe** no ffmpeg LGPL distribuído (`--disable-libx264`). | Falhava sempre no caminho que existe para salvar containers cujo codec o MP4 não aceita (VP9/WebM). Provado com um WebM/VP9 real: agora gera h264 + faixas aac. Os dois testes de muxer asseriam `libx264` com o ffmpeg **mockado**, por isso ninguém percebeu. | `steps/muxer.dart`, `constants.dart`, `test/muxer_test.dart`, `tool/integration_test.dart` |

> **Mudança de comportamento audível no desktop (item b):** em vídeos onde a dublagem passaria do fim, a última fala pode soar um pouco mais rápida (até 1.65×) em troca de não ser truncada. É a única mudança perceptível para o usuário final do desktop; as outras três são correções invisíveis ou melhorias.

---

## 4. Verificação executada

- **`main`:** `dart test` → **199 passam** (baseline original preservado).
- **`android-port`:** `dart test` → **213 passam** (199 + 14 novos).
- **Integração ponta a ponta** (`tool/integration_test.dart`, en→pt, pipeline real): **9/9 asserções**. Saída com a duração exata do vídeo (13,675 s = fixture); `sync.json` com **100 % das falas dentro de ±300 ms** (pior delta: 1 ms; cauda cortada: 0 ms).
- `dart analyze` e `flutter analyze` sem erros nem warnings novos nos dois pacotes.

> Nota de execução: rodar o pipeline via `dart run` falha ao carregar a DLL do sherpa (o Windows resolve o `onnxruntime.dll` 1.17.1 do System32 em vez do 1.27.0 do pacote). Compilar com `dart compile exe` e copiar os `.dll` de `sherpa_onnx_windows-1.13.4/windows/` para o lado do `.exe` resolve.

---

## 5. Pendente

### 5.1 D1 restante (desbloqueado — não precisa de device)

- **Contratos G-1…G-7** (§5 da spec): `DubbingRuntime` como injeção única, `CancellationToken` generalizado (`addCancellable`), `SeparationOutcome` com reason code, `JobCheckpointStore`, `ModelCatalog`↔`ModelManager`, `MediaDownloader` nullable, `DiskSpaceProbe` async. **É onde a refatoração de portabilidade de fato começa.**
- **Memória:** áudio por segmento em disco, writer WAV sequencial, `WavReader` por janela, correção do spread boxed em `writeWavPcm16`.
- **`tool/verify.ps1`** (analyze + testes, falha se regredir dos 199) e **`tool/check_native_libs.dart`** (inventário de `.so`).

### 5.2 Bloqueado em pré-requisitos

- **AT-1 no device:** versionar o build do `libslimt.so` arm64 (paga a dívida do SA-1), criar a suíte de 100 frases, conectar o moto g86.
- **AT-2 / AT-2b / AT-3 / AT-4 / AT-5:** exigem o aparelho e, alguns, `app/android/` gerado.

### 5.3 Dívidas registradas

- `libslimt.so` não versionado (SA-1 foi feito no protótipo irmão).
- Sem aparelho conectado no momento.
- Sem CI (decisão D-d) — os gates são scripts locais.
