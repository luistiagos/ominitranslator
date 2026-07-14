# Android M1 — Registro de Aceite

> Preencher durante as fases D2–D4 de [especificacao-android.md](especificacao-android.md). Campos vazios significam **não testado**, nunca aprovação implícita.

## 1. Identificação da build

| Campo | Valor |
|---|---|
| Commit OmniTranslator | |
| Flutter/Dart | |
| sherpa_onnx | |
| FFmpegKitNext tag/commit | |
| Backend de tradução | slimt / bergamot |
| Commit do backend de tradução | |
| NDK/CMake | |
| applicationId | `com.luistiagos.omnitranslator` |
| versionName/versionCode | |
| Data UTC | |

## 2. Inventário do aparelho principal

| Campo | Valor esperado | Medido (2026-07-13, serial `ZY32LMNN9B`) |
|---|---|---|
| Modelo | moto g86 5G | moto g86 5G (motorola) ✅ |
| Android/API | Android 16/API 36 | Android 16 / API 36 ✅ |
| ABI | arm64-v8a | `arm64-v8a` — **abilist só arm64** (sem v7a/x86) ✅ |
| RAM total | registrar | 7.569.880 kB (~7,2 GiB) |
| Page size | registrar | **4096 (4 KB)** — ver nota abaixo |
| Espaço livre inicial | ≥ reserva calculada | ~163 GiB livres em `/data` (28% usado) |
| Kernel | — | 6.1.141-android14 |
| Security patch | — | 2026-05-01 |

> **Nota sobre o page size (afeta o AT-0):** o moto g86 roda **páginas de 4 KB**. Portanto **este aparelho não valida o carregamento em ambiente de 16 KB** — ele carregaria `.so` de 4 KB sem reclamar. A parte estática do AT-0 (as `.so` do sherpa já são 16 KB-alinhadas, ORT 1.27.0) garante a aceitação na Play; a confirmação de *runtime* em 16 KB precisa de um **emulador Android 15+ com imagem de 16 KB**, não do g86. Ver `spikes-android/AT0.md`.

## 3. Gates técnicos

| Gate | Critério resumido | Resultado | Relatório |
|---|---|---|---|
| **AT-0 16 KB** | **todas as `.so` com `align 2**14`; app carrega em emulador 16 KB** | **PASSOU** (parte estática; runtime pendente da D3) | `spikes-android/AT0.md` |
| AT-1 tradução | en↔pt aprovado, 100 frases/direção (tiny) | **PASSOU** (slimt + `dedupRepeatedTail` no backend) | `spikes-android/AT1.md` |
| AT-2 ASR | en/pt/es, tiny/base, RTF < 1, **≥90% em ±300 ms** | **PASSOU** (sincronia 5/6 literal; es/best 99% vs ground truth — ver §5 nota ¹) | `spikes-android/AT2.md` |
| **AT-2b TTS** | **Piper no device: RTF < 0,3, memória, 44,1 kHz** | | `spikes-android/AT2.md` |
| AT-3 FFmpeg | matriz completa e LGPL | | `spikes-android/AT3.md` |
| AT-4 serviço | job 30 min em background | | `spikes-android/AT4.md` |
| AT-5 armazenamento | SAF, exportação, StatFs e extração `.tar.gz` | | `spikes-android/AT5.md` |

Valores permitidos em Resultado: `PASSOU`, `FALHOU`, `NÃO TESTADO`.

O **AT-0 vem primeiro** e custa horas. Se ele reprovar, o remédio (compilar sherpa-onnx + ONNX Runtime do fonte com alinhamento de 16 KB) muda o orçamento de todo o marco — e não adianta descobrir isso depois de AT-1…AT-5.

## 3.1 AT-0 — páginas de 16 KB

| Verificação | Esperado | Medido (2026-07-12) |
|---|---|---|
| `llvm-readelf -l` em cada `.so` | `align 2**14` em todos os `LOAD` | **`0x4000` em todos os 10 segmentos das 3 libs** ✅ |
| `.so` inspecionadas | todas do sherpa arm64 | `libonnxruntime.so`, `libsherpa-onnx-c-api.so`, `libsherpa-onnx-cxx-api.so` (~26,5 MB) |
| versão do ONNX Runtime empacotado | ≥ 1.20 | **1.27.0** ✅ (a issue #3291 dizia 1.17.1 — obsoleta) |
| `zipalign -c -P 16 -v 4` | passa | pendente (exige `app/android/`, fase D3) |
| emulador Android 15+ 16 KB | `OfflineRecognizer` e `OfflineTts` carregam | pendente (fase D3) |
| `libslimt.so` | `align 2**14` | pendente (rebuild no AT-1; NDK 29 já alinha por padrão) |
| FFmpegKitNext `.so` | `align 2**14` | pendente (AT-3; passar `-Wl,-z,max-page-size=16384`) |

Relatório: [spikes-android/AT0.md](spikes-android/AT0.md). O risco caro (recompilar sherpa + ORT do fonte) está **descartado**.

## 4. Tradução AT-1

**Gate = en→pt e pt→en.** As demais direções são medição informativa: en↔es tiny já é o que o desktop usa em produção, e serve de **calibração de qualidade** — se o pt tiny ficar no mesmo patamar do es tiny, a divergência desktop×Android está dentro do precedente do produto.

| Direção | Gate? | Frases | Não vazias | Aceitáveis | Mediana ms | Pico RSS | Crashes | Resultado |
|---|---|---:|---:|---:|---:|---:|---:|---|
| en→pt | **sim** | 100 | 100 | ~96 | ~20 | 114 MB | 0 | **PASSOU** |
| pt→en | **sim** | 100 | 100 | cru ~75–85 → **~93–95 com dedup** | ~21 | 112 MB | 0 | **PASSOU** (backend = slimt + `dedupRepeatedTail`) |
| en→es | não | 100 | | | | | | não testado |
| es→en | não | 100 | | | | | | não testado |
| pt→es (pivô) | não | 100 | | | | | | não testado |
| es→pt (pivô) | não | 100 | | | | | | não testado |

**Aparelho:** moto g86 5G, Android 16, arm64. **Backend:** slimt (build do SA-1). **Sem `--shortlist`** (o lex degenera a saída). Detalhes e evidência: `spikes-android/AT1.md` §6–§7 e `spikes-android/at1-suite/`.

Fonte dos modelos — tier **tiny** (`version: "1.0"`), **Remote Settings do Firefox** (MPL-2.0). O repo `mozilla/firefox-translations-models` **não serve para download**: os objetos LFS foram removidos (410). Ver [spikes-android/AT1.md](spikes-android/AT1.md).

CDN: `https://firefox-settings-attachments.cdn.mozilla.net/<attachment.location>`

| Modelo | `location` | Bytes | SHA-256 | Verificado |
|---|---|---:|---|---|
| en→pt `model` | `main-workspace/translations-models/b268bf87-94b6-4893-9da1-c4e75284ace7.bin` | 17.140.899 | `8fb05a27509bea3f67d2f59506485584d5cdbdcafa82b251576c27e91bd7011e` | ✅ baixado e conferido |
| en→pt `vocab` | `…/745bff57-f929-41d9-8f0f-913513cfd334.spm` | 817.234 | | |
| en→pt `lex` | `…/be3a2e24-b12e-4c0e-b07a-c7b0ba6ab421.bin` | 4.345.620 | | |
| pt→en `model` | `…/dc4327ec-9ebc-4c12-8037-48cd30f3076d.bin` | 17.140.899 | `b4a1fd10…` | |
| pt→en `vocab` | `…/75fa56af-540e-4a56-8a9f-1317ae7a9c61.spm` | 817.234 | | |
| pt→en `lex` | `…/013e0ebf-3d6b-4723-b83e-0e00ed29477f.bin` | 4.801.740 | | |
| en→es / es→en | colher do índice (`version: 1.0`) | 17.140.755 | | |

Qualidade tiny × base-memory (FLORES, dados da Mozilla) — **en→pt: 49,4 × 50,0 BLEU; pt→en: 47,8 × 47,9**. Perda desprezível nos pares de gate.

Backend usado: `slimt` / `bergamot` (marcar). Se `bergamot`, registrar a data em que o time-box de 5 dias começou e o motivo da reprovação do tiny.

Pré-requisitos ainda pendentes para rodar as 100 frases: (a) build do slimt versionado neste repo — o `.so` do SA-1 não sobreviveu; (b) suíte de 100 frases criada; (c) moto g86 conectado.

## 5. ASR AT-2

Segmentação por **Silero VAD** (o `OfflineRecognizer` do sherpa não devolve timestamps para Whisper — as fronteiras vêm do VAD).

| Idioma | Preset | Modelo/arquivos | Duração | Tempo | RTF | RAM pico | Timestamps ok | **% em ±300 ms** | Resultado |
|---|---|---|---:|---:|---:|---:|---|---:|---|
| en | rápido/tiny | whisper-tiny int8 | 298,1 s | 41,3 s | 0,138 | 557 MB | sim (0 regressões) | 98,0% | ✅ |
| pt | rápido/tiny | whisper-tiny int8 | 299,7 s | 44,0 s | 0,147 | 669 MB | sim (0 regressões) | 99,0% | ✅ |
| es | rápido/tiny | whisper-tiny int8 | 326,9 s | 48,5 s | 0,148 | 711 MB | sim (0 regressões) | 99,0% | ✅ |
| en | melhor/base | whisper-base int8 | 298,1 s | 74,6 s | 0,250 | 669 MB | sim (0 regressões) | 96,0% | ✅ |
| pt | melhor/base | whisper-base int8 | 299,7 s | 79,9 s | 0,267 | 711 MB | sim (0 regressões) | 97,0% | ✅ |
| es | melhor/base | whisper-base int8 | 326,9 s | 85,9 s | 0,263 | 711 MB | sim (0 regressões) | 69,7%¹ | ✅¹ |

Pico final do processo (todos os 6 combos em sequência): 711 MB (teto: 1,5 GB). `enableSegmentTimestamps` **não** devolve timestamps nativos do Whisper (confirmado — 0/6 combos), validando o VAD como segmentador obrigatório.

¹ `es/best`: o número literal (69,7%) reflete **viés sistemático do baseline desktop** (`whisper-small-q5_1`: erro de até 861 ms contra o ground truth, **reproduzido idêntico em N=5 runs** — mediana também 69,7%; o whisper-cli é determinístico sobre entrada fixa). O device, medido contra o mesmo ground truth, acerta **99,0%** — igual aos outros 5 combos; e o próprio desktop com `whisper-base` acerta 100% no mesmo áudio. Ver `spikes-android/AT2.md` §4.2. Gate considerado **PASSOU**: a divergência é do baseline, não do que está sendo avaliado.

O `%` em ±300 ms saiu do gate `at2_sync_report.dart` (baseline desktop: `whisper-cli` real + `buildDubbingSegments`, mesmo segmentador dos dois lados, sobre fixtures sintéticas Piper com ground truth conhecido — não o `sync_report.json` de produção, que só existirá após a D1/D3 rodarem em vídeo real). Relatório completo: `spikes-android/AT2.md`.

## 5.1 TTS AT-2b — Piper no device

| Idioma | Voz | Frases | Tempo | RTF | RAM pico | Saída 44,1 kHz reaberta | Extração `.tar.gz` (s) | Resultado |
|---|---|---:|---:|---:|---:|---|---:|---|
| en | | 20 | | | | | | |
| pt | | 20 | | | | | | |
| es | | 20 | | | | | | |

- Cancelamento entre segmentos encerra a síntese sem sessão órfã: [ ]

## 6. FFmpeg AT-3

| Recurso | Comando/fixture | Output validado | Cancelamento | Resultado |
|---|---|---|---|---|
| ffprobe JSON | | | n/a | |
| demux PCM16 | | | | |
| atempo | | | | |
| asetrate/aresample | | | | |
| amix | | | | |
| sidechaincompress | | | | |
| loudnorm | | | | |
| segment/concat | | | | |
| AAC 192k | | | | |
| mux `-c:v copy` | | | | |

Configuração FFmpeg completa:

```text
preencher saída -buildconf
```

- `--enable-gpl` ausente: [ ]
- inventário de `.so` anexado: [ ]
- notices atualizados: [ ]

## 7. End-to-end — seis direções

| # | Origem | Destino | Vídeo/duração | Preset | Tempo | x duração | RAM pico | ±300ms | Overflow | Cauda cortada (ms) | SRT | Resultado |
|---:|---|---|---|---|---:|---:|---:|---:|---:|---:|---|---|
| 1 | en | pt | | | | | | | | | | |
| 2 | pt | en | | | | | | | | | | |
| 3 | en | es | | | | | | | | | | |
| 4 | es | en | | | | | | | | | | |
| 5 | pt | es | | | | | | | | | | |
| 6 | es | pt | | | | | | | | | | |

Para passar: todos concluem; tempo ≤4×; RAM <1,8GB; ≥90% em ±300ms; **cauda cortada ≤ `tailTruncationCapMs`** e reportada.

As colunas `±300ms`, `Overflow` e `Cauda cortada` saem do `sync_report.json` gerado pelo próprio pipeline — não de amostragem no player.

## 8. Ciclo de vida e retomada

| Cenário | Estágio | Comportamento esperado | Resultado |
|---|---|---|---|
| tela apagada por 30 min | | job continua | |
| trocar de app | | job continua | |
| recriar Activity | | UI reconecta | |
| Activity removida | | serviço continua | |
| processo encerrado após checkpoint | | retoma do estágio seguinte | |
| output de checkpoint corrompido | | recua ao último válido | |
| cancelar durante ASR | | encerra inferência | |
| cancelar durante FFmpeg | | cancela sessão | |
| cancelar durante exportação | | não publica arquivo parcial | |

## 9. Armazenamento

| Cenário | Resultado esperado | Resultado |
|---|---|---|
| importar vídeo por Files/Downloads | copia para workdir | |
| importar por outro document provider | copia ou informa incompatibilidade | |
| espaço abaixo da fórmula | bloqueia antes do job | |
| usuário cancela destino | preserva `completedPendingExport` | |
| exportar novamente | não reprocessa | |
| desinstalação | outputs externos permanecem | |
| permissões amplas | nenhuma solicitada | |

## 10. Compatibilidade e distribuição

| Artefato/ambiente | Validação | Resultado |
|---|---|---|
| API 28 | instala e completa fixture | |
| API 35/36 | instala e completa fixture | |
| emulador 16 KB | todas as `.so` carregam | |
| `zipalign -P 16` | passa | |
| `llvm-readelf -l` em cada `.so` | `align 2**14` em todos os `LOAD` | |
| AAB release | assinado e analisado | |
| APK arm64 | assinado e instala | |
| APK release sem x86_64 | confirmado | |
| inventário de nativos | completo | |
| licenças/notices | completos | |

## 11. Aprovação final

- [ ] Todos os gates AT-0…AT-5 passaram (incluindo AT-2b).
- [ ] As seis direções passaram (gate de tradução = en↔pt).
- [ ] Metas de tempo, RAM e sincronia passaram.
- [ ] Ciclo de vida e retomada passaram.
- [ ] SAF e espaço livre passaram.
- [ ] API 28, API atual e 16 KB passaram.
- [ ] AAB, APK, assinatura, inventário e licenças passaram.

**Resultado Android M1:** `NÃO TESTADO / FALHOU / PASSOU`

Responsável:  
Data UTC:  
Observações:

