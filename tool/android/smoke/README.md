# Smoke test on-device — D3.2 (backends Android) + D3.3 (foreground service)

Fecha a pendência "smoke test funcional no device" registrada desde a D3.1
(bloqueada pelo USB do moto g86 não autenticando — ver `decisoes.md`,
2026-07-15/16). Roda quando o device voltar a responder ao `adb`.

## Pré-requisitos

1. `tool/android/fetch_native_libs.ps1` (P2 + F2) já rodado — sem isso o
   `AndroidTranslator` não encontra `libslimt.so`, nem o `MediaProcessingService`
   encontra o AAR do FFmpegKitNext.
2. Device conectado e autorizado (`adb devices` mostra `device`, não vazio).

## Itens 1–4 — harness Flutter (`smoke_main.dart`)

Ver o cabeçalho de `smoke_main.dart` para o procedimento completo (swap
temporário do `app/lib/main.dart`, nunca commitado — mesmo padrão já usado
e revertido na D3.1). Cobre:

1. **Catálogo real**: baixa `mt-tiny-enpt`, `whisper-android-tiny`,
   `silero-vad`, `piper-android-pt-br`, `espeak-ng-data` via
   `ModelManager.download()` contra a Release `android-models-v1` — prova
   download+hash+extração streaming de verdade no device (e mede o tempo,
   fechando o achado da D3.1 sobre progresso de extração).
2. **`AndroidTranslator` (FFI real)**: traduz 5 frases de
   `docs/spikes-android/at1-suite/en.txt` en→pt; critério objetivo: saída
   não-vazia e sem eco degenerado óbvio (regex de repetição), mais leitura
   humana na tela.
3. **`AndroidTranscriber` (FFI real)**: precisa de (a) uma fixture WAV
   **44,1kHz estéreo** empurrada via `adb push` (ver comentário no código —
   gerar com `tool/at2_gen_fixture.dart` + um passo de ffmpeg pra
   upsample/estéreo) e (b) o handler Kotlin temporário de
   `smoke_ffmpeg_handler.kt.snippet` — colado em `MainActivity.kt` (splice
   temporário, revertido depois). O AAR do FFmpegKitNext já está declarado
   no `build.gradle.kts` desde F1-F4 (revisão de 2026-07-16). Valida
   especificamente o fix do bug B1 (revisão de 2026-07-16): confirma que o
   `asr_in.wav` é gerado e que os timestamps saem plausíveis.
4. **`AndroidSynthesizer` (FFI real)**: sintetiza 1 frase em pt, salva WAV
   em armazenamento externo pra `adb pull` e conferir no desktop (duração >
   0, reabre em 22050Hz — taxa nativa do Piper medium).

## Item 5 — `slimt-cli` direto (fora do app, prova de equivalência com o SA-1)

Não faz parte do harness Flutter — é uma comparação direta do binário
publicado pelo `build-slimt.yml` (P1, `at-slimt-build-4`) contra os
resultados originais do SA-1 (`docs/spikes-android/SA1.md` §7.1), pra provar
que o build novo (com a C-API do §10.3 embutida) ainda traduz igual ao
binário original do SA-1:

```bash
ADB="/e/DevCaches/Android/Sdk/platform-tools/adb.exe"
export MSYS_NO_PATHCONV=1

# slimt-cli da Release do P1 (permanente, não expira como o artifact)
curl -sL -o slimt-cli \
  "https://github.com/luistiagos/ominitranslator/releases/download/at-slimt-build-4/slimt-cli"
"$ADB" push slimt-cli /data/local/tmp/slimt-cli
"$ADB" shell chmod 755 /data/local/tmp/slimt-cli

# Modelo en-de (cache de sessão anterior — mesmo par do SA1.md §7.1)
MODEL="/e/dev_cache/temp/claude/e--projects-omnitranslator/f4b09cb8-ac5a-4123-af2f-61cb770d7f0e/scratchpad/models/ende.student.tiny11"
"$ADB" push "$MODEL/model.intgemm.alphas.bin" /data/local/tmp/model.bin
"$ADB" push "$MODEL/vocab.deen.spm" /data/local/tmp/vocab.spm

echo "The weather is beautiful today." | "$ADB" shell \
  "/data/local/tmp/slimt-cli --model /data/local/tmp/model.bin --vocabulary /data/local/tmp/vocab.spm"
# Esperado (SA1.md §7.1): "Das Wetter ist heute schön."
```

Repetir para as 5 frases do SA1.md §7.1 en→de. Critério: saída idêntica
(ou equivalente) à registrada no SA-1 — prova que os patches 0001–0004
(remoção do `-Werror`, fix do PCRE2, e a C-API nova) não mudaram o
comportamento de tradução do `slimt-cli` em si.

## D3.3 — `MediaProcessingService` (foreground service, §14/AT-4)

Harness separado (`smoke_service_main.dart`), mesmo padrão de swap
temporário. Ver o cabeçalho do arquivo para o procedimento completo
(inclui `adb shell pm grant ... POST_NOTIFICATIONS`, já que a UI de
produção ainda não pede essa permissão em runtime — isso é D3.4). Cobre:

1. **`startJob`/`cancelJob`/`listRecoverableJobs`** (§14.3) contra o
   serviço de verdade — não mocks.
2. **Notificação** (§14.5): canal "Processamento de vídeo", estágio +
   percentual, ação Cancelar, toque abre o app.
3. **Os 5 cenários de ciclo de vida do §14.6** — roteiro manual completo no
   cabeçalho do arquivo (tela apaga, troca de app, rotação, Activity morta
   com o serviço vivo, e morte forçada do processo via
   `adb shell am force-stop`).

**Escopo do MVP (decisão do usuário, revisão de 2026-07-16):** o serviço só
*grava* checkpoints a cada transição de estágio — não pula estágios já
concluídos ao retomar. Os primeiros 4 cenários do §14.6 são cobertos de
verdade pela arquitetura do serviço (não dependem de retomada). O 5º
(morte forçada do processo) tem crédito parcial: `listRecoverableJobs()`
mostra o job depois do `force-stop`, mas "retomar" hoje significa rodar
`runDubbingJob` do zero de novo (reaproveitando modelos já baixados, não
computação já feita) — lacuna documentada, não um bug.

## Ao terminar

Preencher os campos pendentes em `docs/spikes-android/slimt-build.md` §6,
`docs/progresso-android.md` §3.3h/§3.3j/§3.3m e `docs/decisoes.md` com os
resultados reais.
