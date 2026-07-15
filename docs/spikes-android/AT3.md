# AT-3 — FFmpegKitNext LGPL no device

**Data:** 2026-07-15
**Escopo:** §12 de [../especificacao-android.md](../especificacao-android.md)
**Resultado:** **PASSOU.** Build LGPL próprio (arm64-v8a, sem `--enable-gpl`, com `--enable-libopenh264`) da tag `v8.1.0`; os 13 casos da matriz obrigatória rodaram no moto g86 sobre esse build, cada output validado com ffprobe; progresso/cancelamento/timeout provados. Plano de execução detalhado (com o histórico de diagnóstico): [AT3-plano.md](AT3-plano.md).

---

## 1. Build LGPL (Fase 1)

- **Fonte:** `arthenica/ffmpeg-kit-next`, tag **`v8.1.0`**, commit **`3e223118e6e8fb6208693ecf3952e77cd096f587`** (verificado — a tag é `v8.1.0`, não `8.1.0`).
- **Rota:** GitHub Actions (`ubuntu-latest`) — decisão do usuário; o `nix-android.sh` do upstream é Linux-only e o WSL local está sem distro. O workflow versionado ([`.github/workflows/build-ffmpeg-kit-next.yml`](../../.github/workflows/build-ffmpeg-kit-next.yml)) é o "script de build reproduzível" que a §12.1 exige. Run final: `at3-ffmpeg-build-6`.
- **Comando:** `./nix-android.sh --profile android-r27d --disable-arm-v7a --disable-arm-v7a-neon --disable-x86 --disable-x86-64 --api-level=28 --enable-openh264`.
- **Prova de licença (LGPL, C3):** a linha real de `./configure`, extraída com `strings` de dentro do `libavutil.so` compilado (não da árvore-fonte — ver §4), contém `--enable-version3 ... --enable-libopenh264` e **nenhuma ocorrência de `--enable-gpl`**. Evidência: [at3-evidence/build-ffmpeg-configuration.txt](at3-evidence/build-ffmpeg-configuration.txt).
- **Licenças embutidas no AAR:** `res/raw/license.txt` = LGPL v3; `res/raw/license_openh264.txt` = BSD (openh264). Sem libs GPL (x264/x265/vidstab/rubberband ausentes).
- **NDK do build:** r27 (`ndk/27.3.13750724`), que alinha 16 KB por padrão.

### 1.1 Inventário de `.so` (arm64-v8a) e alinhamento 16 KB

Todas as 10 `.so` do AAR têm **todos** os segmentos `LOAD` com `Align = 0x4000` (16 KB), verificado com `llvm-readelf -lW` (SHA-256 completos em [at3-evidence/build-so-inventory.txt](at3-evidence/build-so-inventory.txt)):

| `.so` | Bytes | `.so` | Bytes |
|---|---:|---|---:|
| libavcodec.so | 9.445.272 | libffmpegkit.so | 560.864 |
| libavfilter.so | 2.914.384 | libavutil.so | 558.184 |
| libavformat.so | 2.225.528 | libswscale.so | 545.376 |
| libc++_shared.so | 1.794.776 | libswresample.so | 72.392 |
| libavdevice.so | 56.112 | libffmpegkit_abidetect.so | 38.072 |

## 2. Matriz de comandos (Fase 4) — §12.2

Rodada no **moto g86 5G** (Android 16, arm64-v8a) via app de bench descartável (`at3_bench`), com a ponte Kotlin MethodChannel sobre o AAR local. Comandos **copiados literais do código de produção** (não simplificados); cada output reaberto e validado com `ffprobe`. Fixtures sintéticas geradas no desktop (`fixture.mp4` h264+aac 60s, `voice.wav` pcm_s16le estéreo 60s). Evidência bruta: [at3-evidence/device-results/](at3-evidence/device-results/).

| # | Caso | Comando (fonte de produção) | Validação | Resultado |
|---|---|---|---|---|
| 1 | probe JSON | `ffprobe -print_format json -show_format -show_streams` (`demux.dart:36`) | h264+aac, dur 60,0 s | ✅ |
| 2 | demux PCM16 | `-vn -ac 2 -ar 44100 -c:a pcm_s16le` (`demux.dart:15-18`) | pcm_s16le/2ch/44100, 60,0 s | ✅ |
| 3 | atempo | `-filter:a atempo=1.2500` (`fitter.dart:186`) | dur 48,0 s (60/1,25) | ✅ |
| 4 | asetrate/aresample | `asetrate=50715,aresample=44100,atempo=0.8696` (`fitter.dart:216`, pitch 1,15) | 44100 Hz, dur 59,99 s | ✅ |
| 5+6+7 | sidechaincompress + amix + loudnorm | filtergraph literal de `mixer.dart:109-111` | pcm_s16le/44100, 60,0 s, **10 amostras de progresso** | ✅ |
| 8a | segment muxer | `-f segment -segment_time 10 -c copy` (§12.2) | 6 partes | ✅ |
| 8b | concat demuxer | `-f concat -safe 0 -c copy` (§12.2) | dur 60,0 s | ✅ |
| 9 | AAC nativo | `-c:a aac -b:a 192k` (`constants.dart:45`) | codec aac | ✅ |
| 10 | mux `-c:v copy` | `-map 0:v:0 -map 1:a:0 -map 0:a:0 -c:v copy -c:a aac ... language` (`muxer.dart:15-25`) | **v=h264 (copy), 2 faixas de áudio**, tags de idioma, 60,0 s | ✅ |
| 11 | re-encode fallback | `-c:v libopenh264 -b:v 5M` (`muxer.dart:42`) | v=h264 | ✅ |

## 3. Progresso, cancelamento e timeout (§12.3)

| Primitivo | Como foi provado | Resultado |
|---|---|---|
| **statistics → progresso** | `StatisticsCallback` alimenta `Statistics.time`; o Dart faz poll e converte para 0..1. Na execução longa (caso 5): **10 amostras crescentes** | ✅ |
| **cancelamento** | `FFmpegKit.cancel(sessionId)` a meio de uma execução longa (`-stream_loop 200`). Sessão termina em `state=COMPLETED` com **`returnCode=255`, `isCancel=true`, `isSuccess=false`** — distinguível de sucesso (0) e de erro comum | ✅ |
| **timeout** | O lado Dart aplica timeout de 3 s numa execução longa → `cancel` → resultado marcado `timedOut=true`, distinguível de erro normal | ✅ |

O return code de cancelamento (**255** com `isCancel=true`) é exatamente o sinal que o `FFmpegKitNextRunner` da D3 vai mapear para `ToolResult` — o gate confirma que o primitivo existe e é distinguível.

## 4. Achados de execução (não-óbvios)

- **A prova de licença precisa vir do binário, não da árvore-fonte.** Um `grep "configuration:"` na árvore de build pega *format strings* do próprio código do FFmpeg (`av_log(..., "%s configuration: %s\n", ...)`), não a linha real de configure. Os gates de CID passaram por coincidência antes de eu **baixar o AAR e inspecionar manualmente** — a linha verdadeira está embutida no `.so` (`FFMPEG_CONFIGURATION`), extraível com `strings`. Lição registrada em `decisoes.md` e no plano: "step não falhou" ≠ "step checou o que devia".
- **`readelf -l` quebra cada `LOAD` em duas linhas**; a coluna `Align` fica na segunda. Sem `-W`, um `grep LOAD` compara a coluna errada e reprova por falso-positivo. Use `-lW`.
- **API do ffmpeg-kit v8.1.0 (Kotlin) tem acessores mistos:** a interface `Session` expõe **funções** (`getSessionId()`, `getReturnCode()`, `getState()`, `getAllLogsAsString()`, `getOutput()` — `.sessionId` como propriedade não resolve e é `protected` nas classes concretas), enquanto `ReturnCode.value` e `Statistics.time` são **propriedades** Kotlin (têm campo privado no bytecode). Verificado via `javap` antes de compilar.
- **Só metadados do Actions são legíveis anonimamente** (nomes/conclusões de steps, listagem de artifacts, anotações `::error::`) — download de log e de artifact exige auth admin. Diagnóstico de CI sem token foi feito via anotações `::error::` e, para os dois casos que precisavam do conteúdo, baixando o artifact manualmente.
- **Custo desta máquina:** o build do APK do bench estourou disco (`MergeNativeLibsTask` sem espaço em E:) e memória virtual (daemons Java zumbis) várias vezes — não é problema do gate, é o ambiente. Limpar caches de gates concluídos + matar zumbis resolve.

## 5. Resultado formal do AT-3

| Pergunta (§12.4) | Resultado |
|---|---|
| Build LGPL do fonte, sem `--enable-gpl`? | **PASSOU** (configuração extraída do binário; `--enable-version3`, sem GPL) |
| Só arm64-v8a no release? | **PASSOU** (AAR só tem `jni/arm64-v8a`) |
| Todas as `.so` com alinhamento 16 KB? | **PASSOU** (`Align=0x4000` em todos os `LOAD`, `readelf -lW`) |
| Cada comando real da matriz roda no device (não só `-version`)? | **PASSOU** (13/13, output reaberto e validado) |
| Progresso convertido de statistics? | **PASSOU** (10 amostras) |
| Cancelamento aguarda término e é distinguível? | **PASSOU** (rc=255, isCancel) |
| Timeout distinguível de erro normal? | **PASSOU** (timedOut=true) |
| Configuração, tamanho das `.so`, licenças e ausência de GPL no relatório? | **PASSOU** (§1) |
| **AT-3 — FFmpegKitNext LGPL aprovado para o Android M1?** | **PASSOU** |

## 6. Pendências que não bloqueiam o gate

- O `FFmpegKitNextRunner` (§5.2/§12.3) que traduz `MediaToolRunner` → sessão FFmpegKit é trabalho da **D3**, não deste gate — este spike provou os primitivos, o runner de produção vem depois. O return code 255 de cancelamento e o padrão async/poll estão prontos para ele.
- Confirmação de runtime 16 KB num emulador de página 16 KB continua sendo item da D3/AT-0 (o moto g86 é 4 KB; a validação aqui é estática, como no AT-0).
- Fixar no `ModelCatalog.android()`/config de build o commit + SHA-256 das `.so` (já medidos, §1.1) quando a casca Android (D3) integrar o AAR.
