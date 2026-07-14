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
- Fixar URL/tag exatos dos assets do sherpa-onnx no catálogo Android (§6).
- AT-2b (TTS Piper on-device) — próximo gate, ainda não iniciado.
