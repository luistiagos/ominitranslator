# SA1 — Tradução on-device via NDK + FFI

**Data:** 2026-07-11  
**Aparelho:** moto g86 5G, Android 16/API 36, arm64-v8a  
**Resultado:** **PASSOU PARCIALMENTE** — slimt e modelos tiny funcionam; português `base-memory` continua bloqueado.

> Este relatório foi migrado do protótipo `E:\projects\omnitranslator-android`. A especificação normativa e os próximos gates estão em [../especificacao-android.md](../especificacao-android.md), seção 10.

> ## ⚠ Adendo de 2026-07-12 — a conclusão de produto deste spike estava errada
>
> **O que o SA1 mediu continua válido**: o slimt compila para arm64, carrega tiny, preserva UTF-8 latino e cirílico, é rápido, e gera uma `.so` de 3 MB. Nada disso muda.
>
> **O que muda é a interpretação.** Duas verificações posteriores contradizem as seções 8, 10 e 11 abaixo:
>
> 1. **O slimt só implementa a arquitetura `tiny`** (decoder SSRU). O README do projeto diz textualmente *"Eventual support for `base` models are planned"*. A falha da §8.3 **não era configuração de hiperparâmetros** — era arquitetura ausente. Nenhum valor de `--encoder-layers`/`--decoder-layers` faria o `base-memory` carregar. Portanto o passo 2 da §11 ("inspecionar todos os hiperparâmetros `base-memory`") e o passo 3 ("repetir slimt com configuração completa") **não devem ser executados**.
> 2. **Português nunca esteve bloqueado.** O repo `mozilla/firefox-translations-models` publica `enpt` e `pten` em **`models/tiny/`** — o mesmo tier que este spike já provou que funciona. A premissa "português depende do `base-memory`" era artefato de olhar só para os modelos **já instalados** na máquina do desktop (`%LOCALAPPDATA%\translateLocally\`), em vez de para o catálogo público.
>
> O AT-1 foi reescrito na §10 da especificação: baixar os tiny `enpt`/`pten`, rodar as 100 frases por direção com a `libslimt.so` que **este spike já produziu**, e só ir para bergamot-via-NDK se a qualidade reprovar. O que era o item mais caro do programa Android passou a custar horas.
>
> A §9 deste relatório ("risco adicional de distribuição") também se resolve: o repositório da Mozilla foi **arquivado em 15/12/2025** e é read-only — as URLs não mudam mais, o que é exatamente o que se pedia para fixar SHA-256 e ter download reproduzível.

## 1. Objetivo

Provar que é possível executar tradução Marian/Bergamot 100% offline em Android, compilada pelo NDK, preservando UTF-8 e com desempenho adequado para dublagem.

O spike precisava responder:

1. a engine nativa compila para arm64;
2. o binário carrega modelos compactos;
3. caracteres acentuados e scripts não latinos permanecem corretos;
4. a velocidade é suficiente;
5. os pares obrigatórios en↔pt são compatíveis.

Os quatro primeiros itens passaram. O quinto não passou e bloqueia o Android M1.

## 2. Decisão experimental: slimt

Foi usado [slimt](https://github.com/jerinphilip/slimt) em vez de compilar imediatamente bergamot-translator + Marian completos.

Motivos:

- consome os mesmos modelos tiny da família Bergamot/Firefox;
- possui dependências vendorizadas;
- oferece roteiro de build Android;
- usa ruy/NEON para GEMM int8 em aarch64;
- não exige BLAS externo;
- gera biblioteca pequena.

Essa escolha é válida somente para o spike. A escolha de produção depende do gate AT-1 da especificação Android.

## 3. Ambiente usado

- Flutter 3.44.6;
- Dart 3.12.2;
- Android SDK com API 36;
- NDK 29.0.14206865;
- clang 21.0.0;
- CMake 3.22.1 do Android SDK;
- Ninja 1.10.2;
- host Windows, build NDK via Ninja;
- aparelho arm64 real conectado por adb.

O CMake 3.22.1 do SDK foi usado porque o CMake 4 do host rejeitou subprojetos com `cmake_minimum_required` antigo.

## 4. Ajustes necessários no slimt

### 4.1 Warnings do clang 21

Remover `-Werror` de `SLIMT_COMPILE_OPTIONS`. O clang atual emitiu warnings novos em código que compilava com toolchains anteriores; warnings não deveriam impedir o spike.

### 4.2 ExternalProject do PCRE2

O `FindPCRE2.cmake` precisava:

- herdar o gerador Ninja do build pai;
- receber `CMAKE_MAKE_PROGRAM` explícito;
- desabilitar `pcre2grep` e testes;
- declarar a biblioteca gerada em `BUILD_BYPRODUCTS`.

Sem isso, o sub-build no Windows selecionava Visual Studio, encontrava outro NDK no ambiente e tentava misturar artefatos x86_64 e arm64.

Opções acrescentadas ao subprojeto:

```text
-G${CMAKE_GENERATOR}
-DCMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}
-DPCRE2_BUILD_PCRE2GREP=OFF
-DPCRE2_BUILD_TESTS=OFF
```

## 5. Configuração reproduzida

```bash
cmake -G Ninja \
  -DCMAKE_MAKE_PROGRAM=<android-sdk>/cmake/3.22.1/bin/ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=<ndk>/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-28 \
  -DANDROID_ARM_NEON=TRUE \
  -DWITH_RUY=ON \
  -DWITH_INTGEMM=OFF \
  -DWITH_GEMMOLOGY=OFF \
  -DWITH_BLAS=OFF \
  -DUSE_BUILTIN_SENTENCEPIECE=ON \
  -DSLIMT_USE_INTERNAL_PCRE2=ON \
  -DBUILD_JNI=OFF \
  -DWITH_TESTS=OFF \
  -DBUILD_SHARED=ON \
  -DBUILD_STATIC=ON \
  -S slimt -B build

cmake --build build --target pcre2
cmake --build build --target all
```

Os patches e versões deverão ser transformados em script versionado antes de qualquer uso de produção. Não depender de alterações manuais em checkout externo.

## 6. Artefatos arm64

| Artefato | Antes de strip | Após strip |
|---|---:|---:|
| `libslimt.so` | 28,8 MB | 3,0 MB |
| `slimt-cli` | 32,5 MB | 2,1 MB |

Dependências `NEEDED` observadas na `libslimt.so`:

- `liblog`;
- `libm`;
- `libdl`;
- `libc`.

O runtime C++ foi ligado estaticamente; não foi necessária outra `.so` para esse teste.

## 7. Teste no aparelho

Arquivos de modelos tiny usados:

- `model.intgemm.alphas.bin`;
- vocabulários `vocab.*.spm`;
- shortlist `lex.s2t.bin`.

Invocação equivalente:

```bash
./slimt-cli \
  --root <model-dir> \
  --model model.intgemm.alphas.bin \
  --vocabulary vocab.*.spm \
  --shortlist lex.s2t.bin < s2_en.txt
```

### 7.1 Inglês → alemão

| Entrada | Saída no aparelho |
|---|---|
| The weather is beautiful today. | Das Wetter ist heute schön. |
| I would like a cup of coffee. | Ich möchte eine Tasse Kaffee. |
| The train leaves at seven in the morning. | Der Zug fährt um sieben Uhr morgens ab. |
| She bought three books yesterday. | Sie kaufte gestern drei Bücher. |
| We are going to the beach this weekend. | Wir fahren an diesem Wochenende an den Strand. |

Resultado: acentos e qualidade adequados para comprovar integração.

### 7.2 Inglês → búlgaro

Exemplos:

- “The weather is beautiful today.” → “Времето днес е много хубаво.”
- “The train leaves at seven in the morning.” → “влакът тръгва в 7 часа сутринта.”

Resultado: cirílico preservado. Algumas frases repetiram termos ou mantiveram palavras inglesas; isso foi atribuído à qualidade do modelo tiny, não ao encoding ou build.

### 7.3 Desempenho

As cinco frases, incluindo carga do modelo, levaram aproximadamente **180 ms** no moto g86.

Warnings `Failed to ingest` relacionados a pesos/configurações opcionais apareceram, mas não impediram a saída correta nos modelos tiny. Esses warnings não podem ser ignorados automaticamente para modelos de outra arquitetura.

## 8. Investigação do português

### 8.1 Correção de uma hipótese inicial

Os registros públicos consultados inicialmente não exibiam en↔pt. Isso levou à hipótese de que os modelos não existiam. A hipótese estava errada para a instalação desktop atual.

`translateLocally -l` mostrou:

```text
English-Portuguese  type: base-memory  version: 1  id: en-pt-base
Portuguese-English  type: base-memory  version: 1  id: pt-en-base
```

Os dois modelos traduzem normalmente no desktop. Exemplos:

- “The weather is beautiful today.” → “O tempo está lindo hoje.”
- “I would like a cup of coffee.” → “Gostaria de uma xícara de café.”

### 8.2 Arquivos instalados

`enpt`:

```text
config.intgemm8bitalpha.yml
lex.50.50.enpt.s2t.bin
model.enpt.intgemm.alphas.bin
model_info.json
vocab.enpt.spm
```

`pten` possui estrutura equivalente.

`model_info.json` identifica ambos como `base-memory`.

### 8.3 Falha no slimt

Com parâmetros padrão tiny:

- várias camadas `decoder_l3_*`/`decoder_l4_*` não foram ingeridas;
- a saída ficou degenerada, com repetição de palavras.

Com `--encoder-layers 6 --decoder-layers 6` sem todos os demais hiperparâmetros corretos:

- o processo encerrou com segfault (`exit 139`).

Conclusão: o problema comprovado é incompatibilidade/configuração de arquitetura entre o preset tiny do slimt e os modelos `base-memory`. Não é prova de que português seja impossível e não é ausência do modelo na instalação atual.

## 9. Risco adicional de distribuição

Os modelos en↔pt instalados não aparecem mais na lista online atual consultada pelo translateLocally. Um `-d` executado numa máquina onde o modelo já existe não comprova que uma instalação limpa consegue baixá-lo.

Antes do Android M1 é obrigatório:

1. localizar uma fonte pública reproduzível;
2. confirmar licença e redistribuição;
3. registrar URL e SHA-256;
4. testar download numa instalação limpa;
5. não apagar os modelos atuais do usuário para fazer esse teste.

## 10. Resultado formal

| Pergunta | Resultado |
|---|---|
| NDK arm64 compila engine local? | PASSOU |
| Biblioteca tem tamanho aceitável? | PASSOU |
| UTF-8 latino/cirílico funciona? | PASSOU |
| Desempenho tiny é suficiente? | PASSOU |
| en↔pt funciona no slimt testado? | FALHOU |
| fonte limpa/reproduzível de en↔pt confirmada? | PENDENTE |

Portanto, SA1 não autoriza integrar tradução no app. Ele apenas reduz o risco técnico e alimenta o gate AT-1.

## 11. Próximos passos normativos

Seguir a seção 10 de `especificacao-android.md`:

1. encontrar fonte/licença dos modelos pt;
2. inspecionar todos os hiperparâmetros `base-memory`;
3. repetir slimt com configuração completa;
4. executar 100 frases en→pt e pt→en;
5. se qualquer critério falhar, compilar bergamot-translator completo;
6. expor a C-API `ot_translator_*` definida na especificação;
7. registrar o resultado em `docs/spikes-android/AT1.md`.

