# Build versionado da `libslimt.so` — dívida do SA-1/AT-1 paga

**Data:** 2026-07-15
**Escopo:** pré-requisito da D3.2 (`docs/progresso-android.md`, `AT1.md` §"pendências")
**Resultado:** **PASSOU estruturalmente.** Build reproduzível via GitHub Actions ([`.github/workflows/build-slimt.yml`](../../.github/workflows/build-slimt.yml)), 4/4 gates automatizados passam, e a `.so`/`.cli` baixadas foram reverificadas de forma independente (não só confiando no self-report da CI). O smoke test funcional no device ficou pendente por indisponibilidade momentânea do moto g86 (§4) — não bloqueia o gate porque a evidência estrutural (hash, alinhamento, dependências) já é forte o bastante para desbloquear a D3.2.

---

## 1. O que este build fecha

O SA1 (2026-07-11) e o AT-1 (2026-07-12/13) produziram e usaram uma `libslimt.so` real no moto g86, mas o build nunca virou script versionado — só sobrevivia em cache local (`E:\dev_cache\temp`), e o checkout fonte usado (com os dois patches aplicados manualmente) só existia no protótipo irmão `omnitranslator-android`. Isso bloqueava a D3.2 (`AndroidTranslator`): sem build reproduzível, o `.so` que a D3.2 vai empacotar não teria proveniência auditável.

## 2. Fonte, commit e patches

- **Fonte:** `jerinphilip/slimt`, commit **`9f0b1a20d14871cc94dbe65b7a3df128e5e81f55`** (2024-04-11) — o mesmo checkout usado no SA-1, recuperado ainda intacto do cache de uma sessão anterior (`scratchpad/slimt`, com os patches como diff não commitado).
- **Licença:** `LICENSE` do repo é **GPLv2 genuíno** (não LGPL) — achado, registrado e risco aceito em `decisoes.md` (2026-07-15, ver também `docs/spikes-android/AT5.md` para contexto da sessão). Conflita com a regra §16/#6 da spec ("sem GPL no binário distribuído"); decisão do usuário foi prosseguir mesmo assim, linkando in-process como a §10.3 especifica. **Isto precisa ser revisitado antes do release.**
- **Patches** (extraídos do diff não commitado do SA-1, versionados em [`tool/android/slimt-patches/`](../../tool/android/slimt-patches/)):
  - `0001-remove-werror.patch`: remove `-Werror` do `CMakeLists.txt` (SA1.md §4.1 — clang mais novo emite warnings que toolchains antigas não emitiam).
  - `0002-pcre2-ninja-generator.patch`: `FindPCRE2.cmake` ganha `-G${CMAKE_GENERATOR}`/`-DCMAKE_MAKE_PROGRAM` (herdar o gerador do build pai) e `BUILD_BYPRODUCTS` (sem isso o Ninja não sabe a regra que produz a lib do PCRE2 vendorizado e o link falha).
  - Os dois patches foram **verificados localmente** contra um clone novo do commit pinado antes de subir o workflow (`git apply --verbose` limpo nos dois).

## 3. Configuração de build

Combinação de duas fontes independentes, ambas verificadas (nenhuma inferida):

- **SA1.md §5** — a configuração que rodou de verdade no moto g86 e traduziu corretamente: `BUILD_JNI=OFF` (a integração real usa `dart:ffi` direto sobre a C-API do `libslimt.so`, §10.3 da spec — não JNI/Java), `BUILD_SHARED=ON` + `BUILD_STATIC=ON`, `WITH_RUY=ON`/`WITH_INTGEMM=OFF`/`WITH_GEMMOLOGY=OFF`/`WITH_BLAS=OFF`, `USE_BUILTIN_SENTENCEPIECE=ON`, `SLIMT_USE_INTERNAL_PCRE2=ON`.
- **`scripts/ci/android/02-build.sh` do próprio `jerinphilip/slimt`** — confirma independentemente `ANDROID_ABI=arm64-v8a`, `ANDROID_PLATFORM=android-28` (bate com o `minSdk=28` da spec) e `ANDROID_STL=c++_static`.
- **NDK r27 (27.0.12077973)** — a mesma versão já pinada em `app/android/app/build.gradle.kts` (D3.0), para manter um único NDK em todo o projeto.

## 4. Achado: NDK r27 base **não** alinha 16 KB por padrão

A primeira tentativa (`at-slimt-build-1`, run `29446177326`) reprovou o **Gate 3** (alinhamento): `llvm-readelf -lW` na `.so` produzida mostrou **`Align=0x1000` (4 KB)** em todos os `LOAD`, não 16 KB.

Isso **contradiz uma suposição registrada várias vezes nesta sessão** ("NDK ≥ r27 alinha por padrão", D3.0/AT-3) — suposição que nunca tinha sido testada contra um build **próprio, do zero**, com o NDK r27 **base** (27.0.12077973). As confirmações anteriores usavam ou `.so` prebuilt de terceiros (sherpa/ORT, compiladas por quem sabe qual toolchain) ou o NDK **29** (SA-1, local) ou o **r27d** via Nix (AT-3, cujo próprio script de build pode estar pedindo a flag por conta própria, não necessariamente por confiar no default do NDK).

**Correção:** passar a flag de linker explicitamente em vez de confiar no default por versão de NDK:

```
-DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
-DCMAKE_EXE_LINKER_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
```

A segunda tentativa (`at-slimt-build-2`, run `29446614383`) passou com essa flag — ver §5. **Esta é a lição levada para qualquer build C++/CMake própria no projeto daqui pra frente: nunca assumir 16 KB "de graça" pela versão do NDK sem testar; pedir explicitamente.**

## 5. Resultado (build-2, run `29446614383`)

| Gate | Critério | Resultado |
|---|---|---|
| Gate 1 | `libslimt.so` produzida | ✅ |
| Gate 2 | commit pinado é o esperado | ✅ (`9f0b1a20d14871cc94dbe65b7a3df128e5e81f55`) |
| Gate 3 | todas as `LOAD` com `Align` múltiplo de 16384 | ✅ (`0x4000` nas 3 `LOAD`, confirmado) |
| Gate 4 | dependências dinâmicas só as esperadas | ✅ (`liblog.so`, `libm.so`, `libdl.so`, `libc.so` — idêntico ao SA1.md §6) |

**Reverificação independente** (artifact baixado manualmente pelo usuário, mesmo padrão do AT-3 — não confiar só no self-report da CI): `llvm-readelf -lW`/`-dW` locais reproduzem exatamente os mesmos 3 `LOAD` em `0x4000` e as mesmas 4 dependências; `file` confirma `ELF 64-bit ... ARM aarch64 ... for Android 28, built by NDK r27 (12077973)`; SHA-256 do artifact baixado bate com o `digest` reportado pela API do GitHub.

| Artefato | Tamanho | SHA-256 |
|---|---:|---|
| `libslimt.so` (stripped) | 3.096.040 bytes (~3,0 MB) | `d127cf0fd7dd8bfbef0aa1bed6281a53a222e3ded21280645c3c4f35ca25392d` |
| `libslimt.unstripped.so` | 26.711.800 bytes (~26,7 MB) | `649632d0568d5a928da15ea61a4338573314a7ca045c78d93531565a096fa426` |
| `slimt-cli` | 30.537.344 bytes (~30,5 MB, não stripped) | — |

Tamanhos consistentes com o SA1.md §6 (3,0 MB stripped, 32,5 MB CLI antes do strip) — a pequena diferença nos brutos é esperada entre versões de toolchain (SA-1 usou NDK 29 localmente; este build usa r27).

## 6. Pendência — smoke test funcional no device — **RESOLVIDA (2026-07-17), por caminho mais forte**

O plano original era rodar `slimt-cli` (o binário standalone desta build) no moto g86 e comparar as 5 frases en→de do SA1.md §7.1. Quando o device voltou a responder ao `adb` (2026-07-17), os modelos `en-de` tiny do cache local de sessão antiga já não existiam — e o smoke da D3.2 tornou essa comparação redundante: o **`AndroidTranslator` de produção**, via `dart:ffi` contra a **`libslimt.so` desta MESMA build** (Release `at-slimt-build-4`, baixada por `fetch_native_libs.ps1` e empacotada no APK), traduziu **5/5 frases en→pt corretamente no device em 436ms** (ver `decisoes.md` 2026-07-17 e `progresso-android.md` §3.3j). Isso exercita o caminho de código que o M1 realmente usa (C-API dos patches 0003/0004 + FFI), que é estritamente mais forte que o `slimt-cli` standalone (que não passa pela C-API). A comparação en→de com o SA-1 fica dispensada.

## 7. Resultado formal

| Pergunta | Resultado |
|---|---|
| Build reproduzível e versionado no repo? | **PASSOU** (`.github/workflows/build-slimt.yml`, patches em `tool/android/slimt-patches/`) |
| Commit fonte pinado e documentado? | **PASSOU** (`9f0b1a20d14871cc94dbe65b7a3df128e5e81f55`) |
| `libslimt.so` alinhada em 16 KB? | **PASSOU** (confirmado por CI e reverificação local independente) |
| Dependências dinâmicas conferem com o SA-1? | **PASSOU** (liblog/libm/libdl/libc, idêntico) |
| Smoke test funcional no device (mesma saída do SA-1)? | **PASSOU** (2026-07-17, via caminho mais forte: `AndroidTranslator`/FFI de produção no moto g86, 5/5 en→pt — ver §6) |
| **Pré-requisito da D3.2 — pago?** | **SIM**, integralmente |
