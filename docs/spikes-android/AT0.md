# AT-0 — Páginas de 16 KB

**Data:** 2026-07-12
**Escopo:** §16.1 de [../especificacao-android.md](../especificacao-android.md)
**Resultado:** **PASSOU (parte estática).** As três `.so` de terceiros que o app vai empacotar já são compatíveis com páginas de 16 KB. Restam as verificações que exigem um APK montado (§5).

---

## 1. Por que este gate existe

A §13.1 exige `targetSdk ≥ 35`, faixa em que o Google Play torna o suporte a 16 KB obrigatório (desde novembro de 2025). E o problema não é só de loja: um device com páginas de 16 KB **não carrega** uma `.so` cujos segmentos `LOAD` estejam alinhados a 4 KB — o app simplesmente não roda.

O risco levantado na auditoria (PEND-2, `revisao-especificacao-android.md`) era que o `sherpa_onnx` empacotasse **ONNX Runtime 1.17.1** (de 2024, sem alinhamento), conforme a issue [k2-fsa/sherpa-onnx#3291](https://github.com/k2-fsa/sherpa-onnx/issues/3291) de março de 2026. Se fosse verdade, o remédio — compilar sherpa-onnx + ORT do zero com `-Wl,-z,max-page-size=16384` — não estava previsto em nenhum lugar do plano, do orçamento ou do checklist.

Pela ordem original da §17, isso só seria descoberto na **fase D4**, depois de todos os spikes e da integração inteira.

## 2. O que foi medido

As `.so` não precisaram ser extraídas de um APK: elas já estão no pub cache, exatamente como serão empacotadas.

Pacote: `sherpa_onnx_android_arm64` **1.13.4** (resolvido a partir de `sherpa_onnx: ^1.12.0` no `packages/dubbing_engine/pubspec.yaml`).
Caminho: `<pub-cache>/hosted/pub.dev/sherpa_onnx_android_arm64-1.13.4/android/src/main/jniLibs/arm64-v8a/`
Ferramenta: `llvm-readelf` do NDK 29.0.14206865.

```bash
llvm-readelf -l <lib>.so | grep LOAD    # exigir align 0x4000 (= 16384) em todos
```

## 3. Alinhamento — todos os segmentos `LOAD`

| Biblioteca | Segmentos `LOAD` | Alinhamento | Veredito |
|---|---:|---|---|
| `libonnxruntime.so` | 4 | `0x4000` em todos | ✅ 16 KB |
| `libsherpa-onnx-c-api.so` | 3 | `0x4000` em todos | ✅ 16 KB |
| `libsherpa-onnx-cxx-api.so` | 3 | `0x4000` em todos | ✅ 16 KB |

`0x4000` = 16384 bytes. **Nenhum segmento a 4 KB.**

## 4. Por que a issue #3291 não se aplica

Duas razões, e as duas importam:

1. **A versão do ORT mudou.** O `libonnxruntime.so` empacotado contém a string de versão **`1.27.0`**, não 1.17.1. Confere com as notas do release sherpa-onnx v1.13.4 (07/07/2026): *"Update onnxruntime to 1.27.0"*. A issue descreve um estado anterior do projeto.

2. **A biblioteca reclamada nem existe neste caminho.** A #3291 (e a #2641) tratam de **`libonnxruntime4j_jni.so`** — o binding **Java/JNI** do ONNX Runtime. O pacote Flutter/Dart usa a **C API** e não empacota nenhuma lib `*4j*`. Confirmado: `find` por `*4j*` e por `*.aar` no pacote não retorna nada.

Ou seja: o risco existia para quem consome o sherpa via Java/Kotlin. Pelo caminho Dart, não.

## 5. Inventário de nativos (§16.2)

Base do `tool/check_native_libs.dart`. Nenhuma dessas libs precisa de `libc++_shared.so` — o runtime C++ está ligado estaticamente.

| Biblioteca | Tamanho (bytes) | SHA-256 | `NEEDED` |
|---|---:|---|---|
| `libonnxruntime.so` | 21.688.920 | `994848008526a934dfb579ac773b00e5867929234852b061005d45aacaee9533` | libdl, liblog, libm, libc |
| `libsherpa-onnx-c-api.so` | 4.441.504 | `cb0fe5f4d26e8f66a5466cfc760caafaf50c60128321e491f538d60857324f56` | libandroid, liblog, **libonnxruntime**, libm, libdl, libc |
| `libsherpa-onnx-cxx-api.so` | 437.896 | `f961acd4fc2582ed8bea395c941e8c7b51fd8b41cffb2855779103764d6e7247` | **libsherpa-onnx-c-api**, libandroid, liblog, **libonnxruntime**, libm, libdl, libc |

Total arm64 do sherpa: **~26,5 MB** de `.so`.

## 6. O que ainda falta (exige `app/android/`, que não existe)

Estes itens não podem ser executados antes da fase D3 e **não bloqueiam** o programa — o risco caro (recompilar sherpa + ORT do fonte) está descartado.

| Item | Status | Observação |
|---|---|---|
| `zipalign -c -P 16 -v 4 app-release.apk` | NÃO TESTADO | Depende do APK. É controlado pela nossa config Gradle (`useLegacyPackaging=false`, default no AGP 8+), não por terceiros. |
| Emulador Android 15+ com 16 KB carregando `OfflineRecognizer` e `OfflineTts` | NÃO TESTADO | Confirmação de runtime. O check de ELF acima é o que decide; este é o que prova. |
| `libslimt.so` (AT-1) | NÃO TESTADO | O artefato do SA-1 não foi versionado. O SA-1 usou **NDK 29**, e o NDK ≥ r27 já alinha a 16 KB por padrão — verificar no rebuild. |
| FFmpegKitNext (AT-3) | NÃO TESTADO | Compilado do fonte por nós; passar `-Wl,-z,max-page-size=16384` explicitamente e reconferir. |

## 7. Resultado formal

| Pergunta | Resultado |
|---|---|
| As `.so` de terceiros (sherpa + ORT) suportam páginas de 16 KB? | **PASSOU** |
| O ORT empacotado é recente o bastante? | **PASSOU** (1.27.0) |
| O remédio caro (compilar sherpa + ORT do fonte) é necessário? | **NÃO** |
| APK release passa no `zipalign -P 16`? | NÃO TESTADO (D3) |
| App carrega num device/emulador de 16 KB? | NÃO TESTADO (D3) |

**PEND-2 está encerrada** como pendência de decisão. O que resta são verificações de confirmação, que entram no aceite normal (§10 de [../aceite-android.md](../aceite-android.md)) e não mudam o custo do marco.

## 8. Reprodução

```bash
RE=$ANDROID_HOME/ndk/29.0.14206865/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf
DIR=$LOCALAPPDATA/Pub/Cache/hosted/pub.dev/sherpa_onnx_android_arm64-1.13.4/android/src/main/jniLibs/arm64-v8a

for f in "$DIR"/*.so; do
  echo "== $(basename $f)"
  "$RE" -l "$f" | awk '/^  LOAD/ {print "   align =", $NF}'   # exigir 0x4000
done
```
