# AT-2 — ASR (Whisper ONNX + Silero VAD) no Android

**Data:** 2026-07-14
**Escopo:** §11 de [../especificacao-android.md](../especificacao-android.md)
**Resultado:** **PASSOU.** RTF, memória, não-regressão de timestamps e cobertura de janelas passam com folga nos 6 combos (en/pt/es × fast/best). Sincronia ≥90% em 5/6 combos; o 6º (es/best) só falha o critério **literal** (comparação a uma única run do baseline desktop) — quando ambos os lados são comparados contra o ground truth sintético, o device acerta 99% e é o **desktop** quem está ruidoso naquela run. Ver §5.

---

## 1. Método

Diferente do AT-1 (comparar dois backends ruidosos entre si), o áudio de teste é **sintetizado** (Piper, mesma engine de produção) a partir das 100 frases do AT-1 (en/pt) + 99 frases próprias (es), com pausas fixas de 0,9 s entre frases. Isso dá uma **verdade conhecida** (ground truth) do início exato de cada fala, o que permite medir o erro absoluto de qualquer backend de ASR contra um valor exato — em vez de só comparar desktop×device entre si.

- Geração: `packages/dubbing_engine/tool/at2_gen_fixture.dart` → `<lang>.wav` (16 kHz mono PCM16) + `<lang>_ground_truth.json` (texto + `startMs`/`endMs` reais por frase).
- Durações: en=298,1 s, pt=299,7 s, es=326,9 s (a spec pede ~5 min; es passou um pouco por ter 99 frases mais longas, aceito).
- App de benchmark: projeto Flutter descartável (`sherpa_onnx` 1.13.4 + `path_provider`), instalado no **moto g86 5G** (Android 16, arm64-v8a). Roda os 6 combos (en/pt/es × whisper-tiny/whisper-base) em sequência: Silero VAD segmenta o áudio, cada segmento de fala vai para o `OfflineRecognizer` (Whisper ONNX), resultado + timing + `VmHWM` (`/proc/self/status`, pico de RSS do processo) gravados em JSON.
- Baseline desktop: `WhisperTranscriber` de produção (`whisper-cli`, flags `-ml 1 -sow` reais, mesma `trimSegmentsToSpeechFromFile`) rodado sobre o **mesmo** `.wav`, depois `buildDubbingSegments` — o mesmo segmentador de produção, dos dois lados (`packages/dubbing_engine/tool/at2_sync_report.dart`).
- **Evidência bruta versionada em [at2-evidence/](at2-evidence/)**: JSONs por combo do device + `log.txt` (`device-results/`), relatórios de sincronia (`sync/`), os 3 `*_ground_truth.json` e o `at2-bench-main.dart` (código do app de benchmark). Os ground truths são o único registro do experimento exato — o Piper é estocástico (`noise_scale_w=0.8`), então regerar a fixture produz áudio e timestamps **diferentes** (igualmente válidos, mas não os desta execução). Os `.wav` (~10 MB cada) não são versionados, coerente com a convenção do repo.

## 2. Achado de storage — bloqueou a primeira tentativa

Arquivos copiados para `Android/data/<pkg>/files/...` via `adb push`/`adb shell mkdir` ficam com dono `shell` (uid do adb). O Android isola armazenamento externo por app (FUSE); o processo do app (uid `u0_a661`) recebeu `Permission denied` tanto para `Directory.createSync` quanto para `File.existsSync` em qualquer caminho criado por outro uid — mesmo dentro da própria pasta externa do app. Diretórios/arquivos que o **próprio app** cria (rodando uma vez) ficam acessíveis normalmente.

**Contorno:** os assets são enviados a `/data/local/tmp` (sem isolamento por app) e o próprio app os copia para sua pasta externa no primeiro start (`_ensureAssetsCopied` em `main.dart` do spike). Não é um problema de produção — a build final baixa os modelos de dentro do próprio app (`ModelManager`), que sempre escreve pelo processo do app.

## 3. Resultado — RTF, memória, timestamps, janelas (§11.3)

| Combo | RTF | VmHWM após a run | Segmentos VAD | Segmentos com texto | Regressões | Timestamps nativos do Whisper |
|---|---:|---:|---:|---:|---:|---:|
| en / fast (tiny) | 0,138 | 557 MB | 100 | 100 | 0 | 0 |
| en / best (base) | 0,250 | 669 MB | 100 | 100 | 0 | 0 |
| pt / fast (tiny) | 0,147 | 669 MB | 100 | 100 | 0 | 0 |
| pt / best (base) | 0,267 | 711 MB | 100 | 100 | 0 | 0 |
| es / fast (tiny) | 0,148 | 711 MB | 99 | 99 | 0 | 0 |
| es / best (base) | 0,263 | 711 MB | 99 | 99 | 0 | 0 |

Pico final do processo: **727.880 KB (~711 MB)** — teto da spec é 1,5 GB.

- **RTF < 1 em todos os presets** (pior caso 0,267× no pt/best) — folga grande.
- **Zero regressões de timestamp**, **zero janelas perdidas** (nenhum segmento VAD virou texto vazio — `outputSegmentCount == vadSegmentCount` nos 6 combos).
- **`enableSegmentTimestamps: true` não produz timestamps nativos do Whisper** (`nativeTimestampsNonEmptyCount = 0` nos 6 combos) — confirma empiricamente a premissa original da spec (§8/P3) e fecha a dúvida que a auditoria tinha levantado: o VAD como segmentador **é** obrigatório, não uma opção.

## 4. Resultado — sincronia (§11.3, critério ≥90% em ±300 ms)

### 4.1 Comparação literal (device × baseline desktop, alinhados pelo ground truth)

Alinhamento por proximidade ao ground truth (não por índice — o whisper-cli desktop produz 10–25% mais "segmentos" que frases reais, por inserções espúrias durante as pausas; um índice raso desalinha tudo após a primeira divergência):

| Combo | Segmentos desktop | Segmentos device | Frases (ground truth) | Casados | Dentro de ±300 ms | % |
|---|---:|---:|---:|---:|---:|---:|
| en / fast | 123 | 100 | 100 | 100 | 98 | **98,0%** |
| en / best | 120 | 100 | 100 | 100 | 96 | **96,0%** |
| pt / fast | 109 | 100 | 100 | 100 | 99 | **99,0%** |
| pt / best | 110 | 100 | 100 | 100 | 97 | **97,0%** |
| es / fast | 112 | 99 | 99 | 99 | 98 | **99,0%** |
| es / best | 115 | 99 | 99 | 99 | 69 | **69,7%** ⚠️ |

5 de 6 combos passam com folga. `es/best` fica abaixo do teto de 90%.

### 4.2 Por que `es/best` — device × ground truth, desktop × ground truth

Separando o erro de cada lado contra a verdade absoluta (não um contra o outro):

| Combo | Device × GT (dentro de ±300 ms) | Device × GT (erro mediano) | Desktop × GT (dentro de ±300 ms) | Desktop × GT (erro mediano) |
|---|---:|---:|---:|---:|
| en / fast | 97,0% | 31 ms | 100,0% | 55 ms |
| en / best | 97,0% | 31 ms | 100,0% | 30 ms |
| pt / fast | 99,0% | 17 ms | 100,0% | 48 ms |
| pt / best | 99,0% | 17 ms | 100,0% | 60 ms |
| es / fast | 99,0% | 21 ms | 100,0% | 13 ms |
| **es / best** | **99,0%** | **21 ms** | **66,7%** | **138 ms (máx. 861 ms)** |

O **device** acerta 99% em `es/best` — idêntico aos outros 5 combos, com erro mediano de 21 ms. É o **desktop** (`whisper-small-q5_1` via `whisper-cli`, sobre o espanhol) quem produz timestamps deslocados (erro de até 861 ms contra o ground truth).

**Verificado com N=5 (a mediana da §11.3):** a hipótese inicial era "run ruidosa isolada", e ela estava **errada**. As 5 execuções do desktop sobre o mesmo `es.wav` produziram **exatamente 115 segmentos cada** e a comparação do device contra a **mediana** das 5 dá os mesmos **69,7%** (evidência: [at2-evidence/sync/es_best_median_n5_report.json](at2-evidence/sync/es_best_median_n5_report.json)). O whisper-cli é determinístico sobre entrada fixa (como `decisoes.md` já registrava) — o desvio é **viés sistemático do `whisper-small` neste material espanhol sintético**, não ruído. Repare que o próprio desktop com `whisper-base` (preset rápido) acerta 100% no mesmo áudio (erro mediano 13 ms): o problema é específico do modelo `small` × este material, e a mediana de N runs não o remedia.

**Veredito:** o gate de sincronia mede a granularidade do **device**, e essa é boa e consistente nos 6 combos (97–99% contra a verdade absoluta, mediana ≤31 ms). A divergência de `es/best` é 100% atribuível ao **baseline** — reprodutível, não sorte — e portanto não é um defeito do que está sendo avaliado. O critério literal "±300 ms do baseline desktop" pressupõe um baseline que acerte; quando o baseline erra sistematicamente (66,7% contra a verdade conhecida), a comparação mede o erro dele, não o do device. A métrica de interesse (precisão do device) está estabelecida com folga pelas outras 5 comparações e pela medição direta contra o ground truth.

### 4.3 Limitações declaradas da metodologia

1. **Casamento sem restrição de unicidade:** o `_nearest` do `at2_sync_report.dart` casa cada frase do ground truth com o segmento mais próximo, sem impedir que o mesmo segmento sirva a duas frases (aconteceria se um backend perdesse uma frase inteira e a vizinha estivesse a <2 s). Não ocorreu nesta execução — o device produziu exatamente 100/99 segmentos, 1:1 com as frases, e os erros medianos de 17–31 ms provam casamento correto — mas quem reusar o script com material menos comportado deve verificar duplicatas.
2. **Assimetria de trim:** o lado desktop passa por `trimSegmentsToSpeechFromFile` (apara por RMS) dentro do `transcribe()` de produção; o lado device usa as fronteiras cruas do Silero VAD. Os dois mecanismos cumprem o mesmo papel (limiar de energia) e o erro do device contra o ground truth (mediana ≤31 ms) mostra que a diferença não distorceu o resultado — mas são caminhos distintos, e a comparação os herda.
3. **Baseline de 1 run nos 5 combos que passaram** (a §11.3 prescreve mediana de N≥5): para `es/best`, o único combo em disputa, a mediana de N=5 **foi executada** e deu resultado idêntico à run única (69,7%; 115 segmentos nas 5 runs — determinístico, ver §4.2). Para os outros 5 combos a folga (96–99% vs teto de 90%) torna improvável que a mediana mudasse o veredito; se algum deles for contestado no futuro, o `at2_sync_report.dart` reexecuta em minutos.

## 5. Resultado formal do AT-2

| Pergunta | Resultado |
|---|---|
| Amostra real de ~5 min em en, pt e es? | **PASSOU** (298,1 / 299,7 / 326,9 s, síntese Piper com ground truth) |
| RTF < 1 em cada preset no moto g86? | **PASSOU** (0,138–0,267) |
| Pico do app < 1,5 GB? | **PASSOU** (~711 MB) |
| Timestamps não regressivos? | **PASSOU** (0 regressões, 6/6 combos) |
| Nenhuma janela perdida na fronteira? | **PASSOU** (0 segmentos vazios, 6/6 combos) |
| Sincronia ≥90% dentro de ±300 ms do baseline desktop? | **PASSOU em 5/6** — `es/best` fica em 69,7% (idêntico com mediana de N=5) por viés sistemático do próprio baseline `whisper-small` neste material; contra o ground truth o device acerta 99% igual aos demais (§4.2) |
| **AT-2 — Whisper ONNX + Silero VAD aprovado para o Android M1?** | **PASSOU** |

## 6. Modelos usados (proveniência a fechar antes da D3)

| Arquivo | SHA-256 (calculado sobre os bytes usados neste gate) |
|---|---|
| `silero_vad.onnx` | `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6` |
| `tiny-encoder.int8.onnx` | `d24fb083ae3b1041fc24e97971d60e280c9342201fbb67b0ab428a8b4a51a434` |
| `tiny-decoder.int8.onnx` | `d2fece8dd42771f1df975c6c0445770d0c292bf7547c2cae04a6c0cc57540925` |
| `tiny-tokens.txt` | `b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126` |
| `base-encoder.int8.onnx` | `0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11` |
| `base-decoder.int8.onnx` | `9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d` |
| `base-tokens.txt` | `b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126` |

Os arquivos vieram empacotados como `sherpa-onnx-whisper-tiny.tar.bz2` / `sherpa-onnx-whisper-base.tar.bz2` (nomenclatura padrão dos releases oficiais `k2-fsa/sherpa-onnx`) e `silero_vad.onnx` (modelo VAD padrão do mesmo projeto). **Pendência não bloqueante:** fixar a URL exata do release/tag e registrar os hashes acima no `ModelCatalog.android()` antes da D3 (mesmo padrão do AT-1 — "não inferir nomes"; os hashes acima são medidos, não inferidos, mas a URL de origem exata deve ser reconfirmada no momento do `mirror_models.dart`, D-c).

## 7. Pendências que não bloqueiam o gate

- ~~Repetir `es/best` no desktop com N≥5 runs~~ — **feito** (2026-07-14): mediana de N=5 idêntica à run única (69,7%; determinístico). Fecha a questão — o desvio é do baseline, sistematicamente (§4.2).
- Fixar URL/tag exatos dos assets do sherpa-onnx no catálogo Android (§6, e os das vozes Piper em §8.4).
- ~~AT-2b (TTS Piper on-device)~~ — **feito**, ver §8.
- **Para a D3 (melhorias de produção derivadas do AT-2b):** (a) extração de modelos por **streaming** (`InputFileStream` do `package:archive`) em vez de `decodeBytes` — o spike segura ~2× o tamanho do pacote em RAM transitória, irrelevante no g86 mas relevante em devices de 3–4 GB; (b) `espeak-ng-data` como **asset compartilhado** no `ModelCatalog.android()` em vez de triplicado por voz (identidade byte a byte verificada, §8.1 — ~36 MB de disco economizados).

## 8. AT-2b — TTS Piper (VITS via `sherpa_onnx`) no device — **PASSOU**

Escopo: §11.4 da spec. Reaproveitado o mesmo scaffold do AT-2 (app já instalado no moto g86, mesmo contorno de storage via `/data/local/tmp`) — só o corpo do benchmark mudou, de ASR para TTS.

### 8.1 Método

- **Vozes:** as mesmas já usadas em produção no desktop (`piper-en` = `en_US-lessac-medium`, `piper-pt-br` = `pt_BR-faber-medium`, `piper-es` = `es_ES-sharvard-medium`), carregadas pelo **mesmo caminho de código** que a produção usa: `sherpa_onnx.OfflineTts` com `OfflineTtsVitsModelConfig` (é o que `piper_synthesizer.dart:145-155` já faz no desktop — não há `piper.exe` no projeto). O que muda no device é o **binário nativo** (`.so` arm64 do `sherpa_onnx_android_arm64` em vez da `.dll` win-x64) e o caminho de extração — exatamente a premissa que o §11.4 pedia para testar em vez de presumir ("o código é praticamente o mesmo, mas premissa não testada não é gate"). Paridade de configuração verificada: `numThreads: 2` idêntico à produção, e `noiseScale: 0.667 / noiseScaleW: 0.8 / lengthScale: 1.0` (explícitos no bench) são os mesmos defaults que a produção usa implicitamente.
- **Frases:** 20 por idioma — en/pt são as 20 primeiras da suíte do AT-1 ([at1-suite/](at1-suite/)); es é a tradução literal das mesmas 20 (mesma lista usada em `at2_gen_fixture.dart`, primeiras 20 entradas) — corpus paralelo entre os três idiomas, sem inventar frases novas.
- **Pacotes:** cada voz empacotada como `.tar.gz` (modelo `.onnx` + `.onnx.json` + `tokens.txt` + `espeak-ng-data/`, 67–80 MB compactado) a partir dos mesmos arquivos já em produção no desktop. `espeak-ng-data` é **byte-idêntico** entre as 3 vozes (hash recursivo do conteúdo completo — 355 arquivos — idêntico nas três) — no catálogo real ele pode ser um asset compartilhado em vez de triplicado (~36 MB de disco economizados com 3 vozes instaladas).
- **Extração no device:** `package:archive` (`GZipDecoder` + `TarDecoder`), Dart puro — a mesma escolha já decidida para o Android (D-c) por não haver `tar` nativo.
- **Reamostragem + reabertura:** sem FFmpegKitNext (AT-3 ainda não existe), um resampler linear + writer/reader WAV PCM16 mono próprios do spike validam o round-trip para o formato final de produção (44,1 kHz).
- Código completo do benchmark versionado em [at2-evidence/at2b-bench-main.dart](at2-evidence/at2b-bench-main.dart).

### 8.2 Resultado

| Idioma | Voz | Extração `.tar.gz` | RTF | VmHWM do processo após a run | 44,1 kHz PCM16 reaberto | Cancelamento entre segmentos |
|---|---|---:|---:|---:|---|---|
| en | en_US-lessac-medium (1 speaker) | 1,90 s (67,4 MB) | 0,135 | 657 MB | ✅ | ✅ (parou em 11/20, reinstanciação limpa) |
| pt | pt_BR-faber-medium (1 speaker) | 1,88 s (67,3 MB) | 0,139 | 657 MB | ✅ | ✅ (parou em 11/20, reinstanciação limpa) |
| es | es_ES-sharvard-medium (2 speakers) | 2,28 s (80,1 MB) | 0,135 | 688 MB | ✅ | ✅ (parou em 11/20, reinstanciação limpa) |

Pico final do processo (as 3 vozes em sequência): **690 MB**. Zero frase com áudio vazio nos 60 sintetizados (20 × 3). `es_ES-sharvard-medium` reporta 2 *speakers* — modelo multi-locutor, sid=0 (o padrão usado) é uma voz válida; não afeta o resultado, só é um dado a mais para quem for escolher a voz padrão do idioma.

Duas notas de leitura sobre a coluna de memória e a evidência:

- O `VmHWM` é o pico **cumulativo do processo** (monotônico — pt mostra os mesmos 657 MB do en porque não os excedeu) e **inclui a extração em memória**: o spike usa `GZipDecoder().decodeBytes` sobre o pacote inteiro (~67–80 MB compactado + ~150 MB descomprimido em RAM transitória). Ou seja, o número é um **teto conservador** para o critério "pico de memória do `OfflineTts`" do §11.4 — que passa com folga mesmo assim.
- Os JSONs versionados em `at2-evidence/tts-device-results/` registram `numSpeakers: 0`: o campo era lido **depois** do `tts.free()` do teste de cancelamento, e o getter do sherpa devolve 0 silenciosamente sobre ponteiro nulo. O bug foi corrigido no fonte versionado (`at2b-bench-main.dart` captura o valor no load) — é a única diferença entre o fonte versionado e o binário que gerou os JSONs. Os valores corretos (en=1, pt=1, es=2) estão no `log.txt` da mesma pasta e são os citados acima.

### 8.3 Resultado formal do AT-2b

| Pergunta | Resultado |
|---|---|
| 20 frases/idioma sintetizadas no moto g86? | **PASSOU** (60/60, zero vazias) |
| RTF < 0,3? | **PASSOU** (0,135–0,139) |
| Pico de memória do `OfflineTts` registrado? | **PASSOU** (657–690 MB) |
| Saída reamostrada para PCM16 mono 44,1 kHz e reaberta com sucesso? | **PASSOU** (3/3) |
| Tempo de extração do `.tar.gz` da voz medido no device? | **PASSOU** (1,9–2,3 s para 67–80 MB) |
| Cancelamento entre segmentos encerra a síntese sem sessão órfã? | **PASSOU** (3/3 — `free()` + reinstanciação bem-sucedida) |
| **AT-2b — Piper/VITS via `sherpa_onnx` aprovado para o Android M1?** | **PASSOU** |

### 8.4 Modelos usados (proveniência a fechar antes da D3)

| Arquivo | SHA-256 (medido, arquivos já em produção no desktop) |
|---|---|
| `en_US-lessac-medium.onnx` | `4ba07d8549906668ee855fd9abf9faf66c5db74742712ff026a159f7277fca9f` |
| `piper-en/tokens.txt` | `87c8ef66eae5473ed0cc0366b3964c736ca6c5f676c979522ea31234e47430b9` |
| `pt_BR-faber-medium.onnx` | `1eecd74d1984c73922033629de08974a4cf878f0b4b150e78146331d3d37a053` |
| `piper-pt-br/tokens.txt` | `2619c1a9de1bcf928162f40c583caf39368cfd6b2340c7bcad51dc634411ec36` |
| `es_ES-sharvard-medium.onnx` | `b1281e1c9d9ddd2c4c509d85b97f75ac70d28dfc0fc784c6699af7ec21866417` |
| `piper-es/tokens.txt` | `87c8ef66eae5473ed0cc0366b3964c736ca6c5f676c979522ea31234e47430b9` |
| `espeak-ng-data/phontab` (idêntico nas 3 vozes) | `886f3fa402cb0ba73d483aa8ad000af47a6b7cc06293c75a97913fba68a530f6` |

`tokens.txt` de en e es com hash idêntico é **correto** (mesmo conjunto IPA de fonemas do espeak-ng, independente do idioma-alvo) — mesma situação já observada com os tokenizers do Whisper em §6, não um erro de cópia. Esses são os mesmos arquivos já baixados e usados em produção no desktop (`ModelManager`/`piper_synthesizer.dart`); a proveniência upstream (Hugging Face `rhasspy/piper-voices`) já está documentada lá. Pendência: registrar as entradas equivalentes no `ModelCatalog.android()` (D-c) — mesma dívida já anotada para os assets do sherpa-onnx ASR (§6).
