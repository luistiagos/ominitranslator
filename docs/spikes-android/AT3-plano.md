# AT-3 — Plano de execução detalhado (FFmpegKitNext no device)

**Para quem é este documento:** o implementador do gate AT-3 (humano ou modelo). Ele é autossuficiente: contém os comandos exatos, os critérios de aceite, os erros de ambiente já conhecidos desta máquina e os pontos onde é obrigatório parar e perguntar ao usuário. O normativo continua sendo a §12 de [../especificacao-android.md](../especificacao-android.md); este plano só o torna executável passo a passo.

**Resultado final esperado:** `docs/spikes-android/AT3.md` (relatório PASSOU/FALHOU no formato dos AT0/AT1/AT2), evidência bruta em `docs/spikes-android/at3-evidence/`, scripts de build versionados, e as atualizações de `aceite-android.md` §6, `decisoes.md` e `progresso-android.md`.

---

## 0. Regras e limites (ler antes de qualquer coisa)

1. **Não tocar em código de produção do engine.** O `FFmpegKitNextRunner` (spec §5.2/§12.3) é trabalho da fase **D3**, não deste gate. O AT-3 só **prova os primitivos** de que o runner vai precisar: sessão assíncrona, statistics→progresso, cancelamento, mapeamento de return code — num app de spike descartável.
2. **Não usar wrappers do pub.dev** (`ffmpeg_kit_flutter*` e similares): eles trazem binários de terceiros, e o requisito central do gate é validar **o nosso build LGPL** (§12.1). O caminho é: build próprio → AAR local → ponte MethodChannel mínima em Kotlin.
3. **Não inferir nomes, flags ou versões.** Onde este plano diz "verificar", é literal: rodar o comando de verificação e registrar a saída no relatório. Se a realidade divergir do plano (ex.: a tag 8.1.0 não existe, o script de build tem outro nome), **parar e perguntar ao usuário** — não improvisar.
4. **Não commitar binários** (`.aar`, `.so`, vídeos): ficam em `E:\dev_cache\` e entram no relatório como tamanho+SHA-256. O que se versiona são os **scripts** de build (§12.1: "guardar scripts de build no repositório, não o checkout inteiro do upstream") e a evidência textual (JSONs, logs, buildconf).
5. **Todo comando `adb push`/`adb shell` com path absoluto do device** precisa de `export MSYS_NO_PATHCONV=1` antes (Git Bash reescreve `/storage/...` silenciosamente — ver `decisoes.md` 2026-07-14).
6. Commits na branch `android-port`, mensagens no estilo dos commits `95a1807`/`be159a3`, rodando `tool/verify.ps1` antes de cada commit (deve continuar verde — este gate não muda o engine; piso atual: 323 testes).

## 1. Estado do ambiente (verificado em 2026-07-14)

| Item | Estado | Consequência |
|---|---|---|
| Rota de build | **GitHub Actions** (decisão do usuário, 2026-07-14) — o build é Linux-only (`android.sh`) e o WSL local está sem distro; um runner `ubuntu-latest` faz o papel da máquina Linux | O workflow da §3 é o script de build versionado (§12.1). |
| Remote GitHub | `origin = https://github.com/luistiagos/ominitranslator.git` (grafia com typo é a real). Só `main` (`b15c821`) foi enviado; **`android-port` nunca foi pushado**. `gh` CLI **não** instalado — acionar o workflow pela UI web (Actions → Run workflow) | `workflow_dispatch` só aparece na UI se o arquivo do workflow existir na **branch default** (`main`). **Checkpoint C1 obrigatório** (§2). |
| NDK (lado Windows) | `26.3.11579264` e `29.0.14206865` em `E:\DevCaches\Android\Sdk\ndk\` | Servem para o `llvm-readelf` da re-checagem 16 KB local (§3.4). O runner usa o NDK Linux dele (instalado pelo workflow). |
| adb | `E:\DevCaches\Android\Sdk\platform-tools\adb.exe` (não está no PATH) | Usar path completo. |
| Flutter/Dart | `C:\tools\flutter\bin\` (não está no PATH) | Usar path completo (`flutter.bat`). |
| Device | moto g86 5G (`ZY32LMNN9B`), Android 16, arm64-v8a, páginas de **4 KB** | Roda tudo; a validação 16 KB é **estática** (readelf), como no AT-0. |
| ffmpeg desktop | `tools/win/` no repo (LGPL, com `libopenh264`, sem `libx264`) | Usado para gerar as fixtures (§5). |
| Scaffold de bench | O `at2_bench` do AT-2/AT-2b vivia no scratchpad de sessão (efêmero) e **pode não existir mais** | §4.1 ensina a recriar do zero; o fonte de referência está versionado em [at2-evidence/at2b-bench-main.dart](at2-evidence/at2b-bench-main.dart). |
| Memória virtual do Windows | Pagefiles fixos; builds Gradle podem estourar commit charge | Usar o `gradle.properties` da §4.1 **sempre**; se um build travar, matar o java zumbi antes de tentar de novo (`decisoes.md` 2026-07-14). |

## 2. Checkpoints que EXIGEM o usuário (não prosseguir sem resposta)

- **C1 — Onde o workflow vai viver. RESOLVIDO (2026-07-14):** o workflow vive no **próprio `android-port`** (pushado ao origin como backup na mesma data), disparado por **push de tag** `at3-ffmpeg-build-*` — workflows disparados por push rodam da ref pushada e não precisam existir na branch default, então `main` fica intocada e não há repo separado. O `workflow_dispatch` permanece no YAML para o futuro (merge em `main`) ou disparo via API. Arquivo: `.github/workflows/build-ffmpeg-kit-next.yml`. Disparo: `git tag at3-ffmpeg-build-1 && git push origin at3-ffmpeg-build-1` (numerar sequencialmente a cada re-execução).
- **C2 — Minutos/billing do Actions.** Se o repo for privado, o plano gratuito dá 2.000 min/mês e este build (arm64-only, LGPL mínimo) deve consumir ~30–90 min por execução; se for público, é ilimitado. Confirmar que o usuário está ciente antes da primeira execução (e de eventuais re-execuções por tentativa e erro de flags).
- **C3 — `--enable-openh264`.** Recomendação: **incluir** (BSD, compatível com LGPL; o `muxer.dart:42` usa `libopenh264` no fallback de re-encode, então sem ele o engine precisaria de um caminho divergente no Android). Nuance a apresentar ao usuário: o patent grant da Cisco cobre o **binário deles**, não builds do fonte — o desktop já convive com essa posição (`tools/win` tem openh264), mas a decisão de manter paridade deve ser dele. Registrar a resposta em `decisoes.md`.
- **C4 — Falha estrutural.** Se o build falhar de forma não-óbvia por mais de ~3 tentativas de correção, ou o AAR resultante não carregar no device, parar, resumir o que foi tentado e perguntar. (A existência da tag já foi verificada: é `v8.1.0`, ver §3.1.)

## 3. Fase 1 — Build LGPL (via GitHub Actions)

### 3.1 O workflow (é ele o "script de build versionado" da §12.1)

**Já criado e versionado:** [`.github/workflows/build-ffmpeg-kit-next.yml`](../../.github/workflows/build-ffmpeg-kit-next.yml). Baseado em fatos **verificados no upstream em 2026-07-14** (não inferidos):

| Fato verificado | Valor real | Como foi verificado |
|---|---|---|
| Tag | **`v8.1.0`** (a spec dizia "8.1.0" — o nome real tem `v`), commit `3e223118e6e8fb6208693ecf3952e77cd096f587` | `git ls-remote --tags` |
| Sistema de build | **Nix** (`./nix-android.sh --profile android-r27d`) — **não existe mais `android.sh`**; a v8.1.0 reestruturou tudo para flakes (é a rota "Nix em Linux/CI" que a §12.1 já citava) | listagem da árvore da tag + leitura de `nix-android.sh` e `flake.nix` |
| NDK | **27.3.13750724 (r27d)**, fixado pelo próprio flake (alinha 16 KB por padrão) — o workflow não instala SDK/NDK; o Nix traz tudo | `flake.nix` (bloco `android = {...}`) |
| Flags | `--disable-arm-v7a --disable-arm-v7a-neon --disable-x86 --disable-x86-64 --api-level=28 [--enable-openh264]`; GPL só entraria com `--enable-gpl` explícito (nunca usamos); `--api-level` default é 24 | `scripts/help-android.sh` + `scripts/function.sh:926` |
| Saída | AAR "under the prebuilt folder" | `help-android.sh` |
| Binários prontos? | **Não** — a release v8.1.0 não tem assets (premissa de 2026-07-11 reconfirmada) | GitHub API `releases/tags/v8.1.0` |

O job já embute as evidências do gate: commit pinado, `buildconf.txt` com **falha dura** se `--enable-gpl` aparecer, inventário de `.so` (tamanho + SHA-256) e checagem de alinhamento 16 KB via GNU `readelf` que **reprova o build** se qualquer `LOAD != 0x4000`. Tudo sobe como artifact `ffmpeg-kit-next-arm64-lgpl`.

**Disparo** (C1): `git tag at3-ffmpeg-build-1 && git push origin at3-ffmpeg-build-1` — numerar sequencialmente a cada re-execução. Acompanhar e baixar o artifact pela UI web (Actions → run) — o `gh` CLI não está instalado.

### 3.2 Depois do download do artifact

Extrair para `E:\dev_cache\at3\` e **re-verificar localmente** (não confiar só no job):

```bash
# sha256 do aar e das .so batem com o so-inventory.txt do artifact
sha256sum /e/dev_cache/at3/ffmpeg-kit.aar
# re-checar 16 KB com o llvm-readelf do NDK Windows:
"E:\DevCaches\Android\Sdk\ndk\29.0.14206865\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-readelf.exe" -l <cada .so>
# → todos os segmentos LOAD com align 0x4000. Se algum vier 0x1000: NÃO aceitar;
#   subir a versão de NDK do workflow (r27+) ou investigar injeção de
#   -Wl,-z,max-page-size=16384 nos LDFLAGS do android.sh, e re-disparar.
```

Copiar `evidence-commit.txt`, `buildconf.txt`, `so-inventory.txt` e `alignment.txt` para `docs/spikes-android/at3-evidence/` (o `build.log` completo é grande — guardar em `E:\dev_cache\at3\` e citar; versionar só um excerto se necessário).

## 4. Fase 2 — Ponte Kotlin no app de bench

### 4.1 Recriar o scaffold (se o do AT-2 não existir mais)

```bash
cd /e/dev_cache/spikes   # local ESTÁVEL, fora do scratchpad de sessão
"/c/tools/flutter/bin/flutter.bat" create --platforms=android --org com.luistiagos.at3bench at3_bench
```

`android/gradle.properties` (obrigatório nesta máquina — commit charge):

```properties
org.gradle.jvmargs=-Xmx512m -XX:MaxMetaspaceSize=192m -XX:ReservedCodeCacheSize=48m -XX:+UseSerialGC -Xss512k
org.gradle.daemon=false
org.gradle.parallel=false
org.gradle.workers.max=1
kotlin.compiler.execution.strategy=in-process
kotlin.incremental=false
android.useAndroidX=true
android.enableJetifier=true
```

`pubspec.yaml`: adicionar `path_provider: ^2.1.0` (não precisa de `sherpa_onnx` aqui).

### 4.2 AAR local

```
at3_bench/android/app/libs/ffmpeg-kit.aar     (copiado da fase 1)
```

`android/app/build.gradle.kts`:

```kotlin
dependencies {
    implementation(files("libs/ffmpeg-kit.aar"))
    implementation("com.arthenica:smart-exception-java:0.2.1") // dependência do ffmpeg-kit; VERIFICAR versão exigida pela tag
}
```

### 4.3 MethodChannel (MainActivity.kt)

Ponte mínima com 4 métodos — é ela que prova os primitivos da §12.3:

```kotlin
package com.luistiagos.at3bench.at3_bench

import com.arthenica.ffmpegkit.FFmpegKit
import com.arthenica.ffmpegkit.FFprobeKit
import com.arthenica.ffmpegkit.FFmpegKitConfig
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "at3/ffmpeg")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // executa ffmpeg async; devolve {sessionId} na hora
                    "ffmpegStart" -> {
                        val args = (call.argument<List<String>>("args"))!!.toTypedArray()
                        val session = FFmpegKit.executeWithArgumentsAsync(args, null, null) { stat ->
                            // statistics: time (ms) → progresso é calculado no Dart
                            lastStatTimeMs = stat.time.toLong()
                        }
                        result.success(mapOf("sessionId" to session.sessionId))
                    }
                    // consulta estado/return code/logs de uma sessão
                    "ffmpegPoll" -> {
                        val id = (call.argument<Number>("sessionId"))!!.toLong()
                        val s = FFmpegKitConfig.getSession(id)
                        result.success(mapOf(
                            "state" to s?.state?.name,
                            "returnCode" to s?.returnCode?.value,
                            "logsTail" to (s?.allLogsAsString?.takeLast(4000) ?: ""),
                            "statTimeMs" to lastStatTimeMs,
                        ))
                    }
                    "ffmpegCancel" -> {
                        val id = (call.argument<Number>("sessionId"))!!.toLong()
                        FFmpegKit.cancel(id); result.success(null)
                    }
                    // ffprobe síncrono (JSON via -print_format json)
                    "ffprobe" -> {
                        val args = (call.argument<List<String>>("args"))!!.toTypedArray()
                        val s = FFprobeKit.executeWithArguments(args)
                        result.success(mapOf(
                            "returnCode" to s.returnCode.value,
                            "output" to s.output,
                        ))
                    }
                    else -> result.notImplemented()
                }
            }
    }
    companion object { @JvmStatic var lastStatTimeMs: Long = 0 }
}
```

(Nomes de API — `executeWithArgumentsAsync`, `Statistics.time`, `FFmpegKitConfig.getSession` — VERIFICAR contra o javadoc da tag; ajustar se divergirem e registrar no relatório.)

## 5. Fase 3 — Fixtures (geradas no desktop, sem mídia real)

Com o ffmpeg do repo (`tools/win/ffmpeg.exe`):

```bash
# Vídeo de teste 60 s: padrão de teste + tom senoidal, h264+aac (o -c:v copy do mux precisa de h264 real):
tools/win/ffmpeg.exe -y -f lavfi -i testsrc2=size=640x360:rate=30:duration=60 \
  -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=60" \
  -c:v libopenh264 -b:v 1M -c:a aac -b:a 128k -pix_fmt yuv420p fixture.mp4
# Segunda pista de áudio p/ amix/sidechain (voz sintética é melhor que senoide para o ducking ter o que "ouvir"):
# reaproveitar um WAV de fala do AT-2b (ex.: resample do en_last_44k.wav para estéreo) OU gerar outro tom:
tools/win/ffmpeg.exe -y -f lavfi -i "sine=frequency=880:sample_rate=44100:duration=60" -ac 2 -c:a pcm_s16le voice.wav
```

Enviar para o device em `/data/local/tmp/at3/` (o app copia para a própria pasta no primeiro start — **mesmo contorno de storage do AT-2**: nunca `adb push` direto para `Android/data/<pkg>/`).

## 6. Fase 4 — Runner Dart (a matriz)

`lib/main.dart` no molde do bench do AT-2b ([at2-evidence/at2b-bench-main.dart](at2-evidence/at2b-bench-main.dart)): app sem UI real, roda a matriz no `initState`, grava `results/<caso>.json` + `log.txt` (com `await` em cada `logLine` — o bug de `flush()` concorrente já mordeu uma vez), `summary.json` no fim.

### 6.1 A matriz — comandos EXATOS de produção

Cada linha roda encadeada sobre a saída da anterior. Os argumentos vêm do código de produção citado — **não simplificar nem "melhorar"**; a paridade é o ponto do gate.

| # | Caso | Comando (args de produção) | Fonte | Validação do output |
|---|---|---|---|---|
| 1 | probe JSON | `ffprobe -v error -print_format json -show_format -show_streams fixture.mp4` | variação JSON do `demux.dart:36-40` | JSON parseia; `streams` tem 1 vídeo h264 + 1 áudio aac; `format.duration` ≈ 60±0,5 s |
| 2 | demux PCM16 | `-y -i fixture.mp4 -vn -ac 2 -ar 44100 -c:a pcm_s16le audio_full.wav` | `demux.dart:15-18` | reabrir com probe: pcm_s16le, 2ch, 44100 Hz, duração ≈ 60 s |
| 3 | atempo | `-y -i audio_full.wav -filter:a atempo=1.2500 seg_atempo.wav` | `fitter.dart:183-187` | duração ≈ 60/1,25 = 48±0,3 s |
| 4 | asetrate/aresample | `-y -i audio_full.wav -filter:a asetrate=50715,aresample=44100,atempo=0.8696 child.wav` | `fitter.dart:212-216` com `childVoicePitchFactor=1.15` (`constants.dart:208`): rate=round(44100×1,15)=50715, tempo=(1/1,15)=0.8696. Em produção o input é o WAV 22.05 kHz do TTS; aqui aplica-se a mesma semântica sobre a fixture 44,1 kHz | 44100 Hz; duração ≈ 60±0,5 s (asetrate encurta ×1,15, atempo devolve) |
| 5+6+7 | sidechaincompress + amix + loudnorm | `-y -i audio_full.wav -i voice.wav -filter_complex "[0:a][1:a]sidechaincompress=threshold=0.02:ratio=12:attack=20:release=400[bg];[bg][1:a]amix=inputs=2:duration=first:normalize=0,loudnorm=I=-16:TP=-1.5:LRA=11[out]" -map "[out]" -ac 2 -ar 44100 -c:a pcm_s16le dubbed.wav` | `mixer.dart:109-115` (filtergraph literal de produção — os 3 filtros num comando só, como em produção) | pcm_s16le 2ch 44,1 kHz; duração ≈ 60±0,5 s (`duration=first`) |
| 8a | segment | `-y -i dubbed.wav -f segment -segment_time 10 -c copy part_%03d.wav` | §12.2 (produção ainda não usa; comando canônico) | 6 partes; soma das durações ≈ 60±0,2 s |
| 8b | concat | `-y -f concat -safe 0 -i list.txt -c copy joined.wav` (list.txt: `file 'part_000.wav'`…) | §12.2 | duração ≈ 60±0,2 s; mesmo sample count do dubbed.wav (probe `nb_samples`/duração) |
| 9 | AAC nativo | `-y -i dubbed.wav -c:a aac -b:a 192k out_aac.m4a` | `constants.dart:45` | probe: codec aac, bitrate ~192k, reabre |
| 10 | mux `-c:v copy` | `-y -i fixture.mp4 -i dubbed.wav -map 0:v:0 -map 1:a:0 -map 0:a:0 -c:v copy -c:a aac -b:a 192k -metadata:s:a:0 language=por -metadata:s:a:1 language=eng -disposition:a:0 default final.mp4` | `muxer.dart:15-25` (com `keepOriginalTrack`) | probe: v=h264 (mesmo codec do fixture — prova do copy), 2 faixas de áudio aac, tags de idioma presentes, duração ≈ 60 s |
| 11 (se C3 aprovado) | re-encode fallback | `muxer.dart:31-49` com `-c:v libopenh264 -b:v 5M` | `muxer.dart:42` | probe: v=h264, reabre |

### 6.2 Progresso, cancelamento e timeout (§12.3)

- **Progresso:** na linha 5+6+7 (a mais longa), fazer poll do `statTimeMs` durante a execução e registrar ≥3 amostras crescentes convertidas para 0..1 (`statTimeMs / durationMs`). Prova que statistics→progresso funciona.
- **Cancelamento:** repetir a linha 5+6+7 com `-stream_loop 10` no primeiro input (execução longa), chamar `ffmpegCancel` após ~2 s, e validar: a sessão termina com estado/return code **distinguível** de sucesso e de erro comum (no ffmpeg-kit, cancel → `ReturnCode.isCancel()`; registrar o valor bruto), e o processo não fica rodando (poll do estado até `COMPLETED`/`FAILED`/cancel, com prazo).
- **Timeout:** mesma execução longa, mas o lado Dart aplica um timeout próprio de 3 s → chama cancel → registra que o resultado é distinguível de erro normal (campo `timedOut: true` no JSON do caso). É o comportamento que o `FFmpegKitNextRunner` da D3 vai reproduzir.

## 7. Fase 5 — Execução no device

Mesma coreografia do AT-2b (ver comandos exatos em [AT2.md](AT2.md) §8 e nos gotchas de `decisoes.md` 2026-07-14):

1. `flutter build apk --profile --target-platform android-arm64` (com o `gradle.properties` da §4.1; primeiro build pode levar >10 min — é normal nesta máquina).
2. `export MSYS_NO_PATHCONV=1` + `adb install -r`, `adb push` das fixtures para `/data/local/tmp/at3/`, `am start`.
3. Acompanhar por `adb shell cat .../files/at3/results/log.txt` (não por screenshot).
4. `adb pull` de `results/` ao final.

## 8. Fase 6 — Relatório e docs

1. **`docs/spikes-android/AT3.md`** no formato dos anteriores: método → tabela de resultados (uma linha por caso da matriz, com validação e tempo) → progresso/cancelamento/timeout → build (tag, commit, flags, buildconf resumido, prova de ausência de `--enable-gpl`, inventário de `.so` com tamanho/SHA-256/alinhamento 16 KB) → licenças (LGPL + openh264/BSD se incluído) → veredito formal → pendências.
2. **`docs/spikes-android/at3-evidence/`**: JSONs por caso + `log.txt` + `summary.json` do device, `buildconf.txt` completo, inventário de `.so`, e o `main.dart`/`MainActivity.kt` do bench (`at3-bench-main.dart`, `at3-bench-mainactivity.kt`).
3. **`aceite-android.md`**: preencher a tabela da §6 (todas as linhas), o campo "Configuração FFmpeg completa", os 3 checkboxes, a linha AT-3 da tabela de gates da §3, e o campo "FFmpegKitNext tag/commit" da §1.
4. **`decisoes.md`**: entrada com data, tag+commit, decisão C3 (openh264), resultado do gate e achados de ambiente novos (se houver).
5. **`progresso-android.md`**: linha AT-3 na tabela §1 → ✅/❌; nova seção §3.3e com o resumo; atualizar o parágrafo-resumo da §1.
6. **Memória do projeto** (se o implementador for um agente com memória): atualizar `at2-asr-passou.md` ou criar `at3-ffmpeg-passou.md` com os achados não-óbvios.

## 9. Critérios de PASSOU (todos obrigatórios)

- [ ] As 10 linhas da matriz produzem output validado no moto g86 (11 se C3 aprovado).
- [ ] Progresso: ≥3 amostras crescentes de statistics numa execução real.
- [ ] Cancelamento: sessão cancelada termina, com return code distinguível de erro.
- [ ] Timeout: distinguível de erro normal no resultado.
- [ ] `buildconf` registrado, **sem** `--enable-gpl` e sem libs GPL (`grep -i gpl` limpo, exceto menções a "LGPL").
- [ ] Todas as `.so` do AAR com `LOAD align 0x4000` (16 KB).
- [ ] Tag + commit do upstream registrados; script de build versionado e reproduzível.
- [ ] Relatório + evidência + 3 docs atualizados + verify.ps1 verde.

Qualquer critério não atingido → o relatório sai como **FALHOU/PARCIAL** com a causa documentada — nunca ajustar o critério para caber no resultado (precedente: o es/best do AT-2 foi documentado como exceção com evidência, não escondido).
