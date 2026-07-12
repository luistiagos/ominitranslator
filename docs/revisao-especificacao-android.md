# Revisão da Especificação Android — auditoria de prontidão

**Data:** 2026-07-12
**Escopo:** `especificacao-android.md`, `aceite-android.md`, `spikes-android/SA1.md`, `decisoes.md`, `plano-de-desenvolvimento.md`
**Método:** cada afirmação da spec sobre o código foi conferida contra o código real (com `arquivo:linha`); cada pressuposto sobre fonte externa foi conferido contra a fonte (com URL). Ver §8.

---

## 1. Veredito

A especificação é **boa**: normativa, bem estruturada, com ordem de trabalho e critérios de aceite explícitos. O diagnóstico de acoplamento e memória da §3.2 foi conferido item por item e está **factualmente correto em todos eles** — inclusive subestimando o problema (§6).

Mas ela **ainda não está pronta para um agente menor executar sem redesenhar**, por três motivos:

| Categoria | Qtd. | Efeito |
|---|---:|---|
| **Pendências** (pressupostos externos que a verificação contradiz) | 2 | Podem inverter o custo do AT-1 e inviabilizar o release na Play |
| **Lacunas de contrato** (a §5 se declara normativa, mas está incompleta) | 7 | O implementador teria de *inventar* interfaces — exatamente o que a spec quis evitar |
| **Imprecisões factuais** | 6 | Erros pontuais; nenhum fatal |
| **Riscos sem gate** | 6 | Descobertos tarde demais (fase D4) pelo plano atual |

Além disso, a auditoria encontrou **um bug latente no código desktop atual** (§5, R-5) que a spec herda sem perceber.

---

## 2. Pendências — decisão adiada, documentadas para resolver depois

### PEND-1 — O AT-1 está ancorado no tier de modelo errado (possível economia de semanas)

**O que a spec assume.** O SA1 e a §10 partem de que o português depende dos modelos que estão instalados no desktop — `en-pt-base` e `pt-en-base`, do tipo **`base-memory`** — e que o slimt (preset tiny) não consegue carregá-los. Daí a ordem obrigatória do §10.2: inspecionar a arquitetura do `base-memory` → rodar o slimt com todos os hiperparâmetros → **se falhar, compilar o `bergamot-translator` completo via NDK arm64** (passos 5–6). Esse fallback é o item mais caro de todo o programa Android, e não tem time-box.

**O que a verificação encontrou.** O repositório `mozilla/firefox-translations-models` publica os pares **`enpt` e `pten` dentro de `models/tiny/`** — o mesmo tier que o SA1 **já provou** que o slimt carrega (passou com de/bg tiny: UTF-8 latino e cirílico preservados, ~180 ms para 5 frases incluindo carga, `libslimt.so` de 3 MB).

Listagem completa observada em `models/tiny/`: `azen, been, bgen, bnen, bsen, caen, csen, daen, deen, elen, enaz, enbg, enbn, enca, encs, enda, ende, enel, enes, enet, enfa, enfi, enfr, engu, enhe, enhi, enhr, enhu, enid, enit, enkn, enlt, enlv, enml, enms, ennl, enpl, **enpt**, enro, enru, ensk, ensl, ensq, ensv, enta, ente, entr, enuk, esen, eten, faen, fien, fren, guen, heen, hien, hren, huen, iden, isen, iten, knen, lten, lven, mlen, msen, mten, nben, nlen, nnen, plen, **pten**, roen, ruen, sken, slen, sqen, sren, sven, taen, teen, tren, uken, vien`.

**Por que isso importa.** A premissa central do SA1 — "português está bloqueado" — pode ser um artefato de ter olhado só para os modelos que *já estavam instalados na máquina do desktop*, em vez de para o catálogo público. O `base-memory` não é o único caminho para pt; é apenas o que estava em `%LOCALAPPDATA%\translateLocally\`.

**Consequência prática.** O AT-1 pode fechar em **horas** com um passo 0 — "baixar `enpt`/`pten` tiny, rodar as 100 frases por direção no slimt já compilado" — e o fallback bergamot-via-NDK pode **nunca ser necessário**.

**Fato favorável à distribuição.** O repositório foi **arquivado em 15/12/2025** e está read-only. Isso é bom, não ruim: as URLs não mudam mais, o que é ideal para fixar SHA-256 e ter download reproduzível — exatamente o que a §9 do SA1 e a §16.3 da spec exigem, e que hoje é o risco em aberto ("os modelos en↔pt sumiram do `translateLocally -a`").

**O que ainda precisa ser decidido (a pendência propriamente dita):**

1. **Qualidade.** O tier tiny é, por construção, pior que o `base-memory` que o desktop usa hoje. Isso cria uma **divergência de qualidade de tradução entre plataformas** (desktop = base, Android = tiny). É aceitável? A spec já aceita divergência análoga no ASR (desktop small, Android tiny/base), então há precedente — mas precisa ser uma decisão consciente, registrada em `decisoes.md`, e não um efeito colateral.
2. **Licença.** Confirmar a licença dos modelos do repo arquivado e o direito de redistribuição, conforme exigem a regra #4 e a §16.3.
3. **Reordenação do §10.2.** Se aceito, o §10.2 passa a ser: (0) baixar tiny `enpt`/`pten`; (1) rodar as 100 frases/direção; (2) só se reprovar em qualidade é que se investiga `base-memory`/bergamot. O critério de decisão do §10.4 continua valendo sem mudanças.
4. **Efeito colateral positivo no desktop.** Se o tiny for aprovado, ele também resolve o risco documentado em `decisoes.md:18` (o `-d en-pt-base` pode não funcionar numa instalação limpa, porque o par sumiu do registro online) — passaria a existir uma fonte pública, versionada e hasheável para pt também no Windows.

**Nada disso invalida o SA1.** O SA1 continua correto no que mediu: o slimt compila, carrega tiny, preserva UTF-8 e é rápido. O que muda é a *conclusão de produto* que se tirou dele.

---

### PEND-2 — O gate de 16 KB pode ser inalcançável com o `sherpa_onnx` fixado (risco de bloquear a Play)

**O que a spec exige.** A §19.4 faz "APK/AAB carregarem em ambiente 16 KB" um **critério de release** do Android M1, a §16.1 manda validar todas as `.so` (próprias e de terceiros), e a §13.1 exige `targetSdk` "nunca menor que 35" — faixa em que o Google Play torna o suporte a páginas de 16 KB **obrigatório** (desde novembro de 2025).

**O que a verificação encontrou.** O sherpa-onnx empacota **ONNX Runtime 1.17.1** (de 2024). A issue [k2-fsa/sherpa-onnx#3291](https://github.com/k2-fsa/sherpa-onnx/issues/3291), aberta em **11 de março de 2026**, ainda reporta que a `.so` arm64 **não é alinhada a 16 KB**, e pede o upgrade para ORT 1.20.x+ compilado com o alinhamento. As issues anteriores ([#2413](https://github.com/k2-fsa/sherpa-onnx/issues/2413), [#2641](https://github.com/k2-fsa/sherpa-onnx/issues/2641)) estão fechadas, mas a PR [#2657](https://github.com/k2-fsa/sherpa-onnx/pull/2657) associada **não mexe em alinhamento** — ela só ajusta a detecção de biblioteca no CMake e uma condição de workflow. Ou seja: **não há prova de correção**, e o relato mais recente é de que o problema persiste.

**Por que isso é grave no plano atual.** A spec fixa `sherpa_onnx` em 1.13.4 (§11.1) e usa esse mesmo pacote para **ASR e TTS**. Pela ordem da §17, a validação de 16 KB só acontece na **fase D4** — depois de AT-1…AT-5, da refatoração do engine e da integração inteira. Se a `.so` reprovar ali, o remédio (compilar sherpa-onnx + ONNX Runtime do zero, com alinhamento de 16 KB) **não está previsto em lugar nenhum** do plano, do checklist §20 ou do orçamento de risco.

**Mitigação sugerida — um gate AT-0, custo de horas:**

Antes de qualquer outro spike, montar um APK mínimo que apenas linke `sherpa_onnx` 1.13.4 e:

1. rodar `zipalign -c -P 16 -v 4 app-release.apk`;
2. rodar `llvm-readelf -l` em **cada** `.so` do APK, procurando `align 2**14` nos segmentos `LOAD` (ver §4 — o `zipalign` sozinho **não** basta);
3. carregar o app num emulador Android 15+ configurado para 16 KB e chamar de fato o `OfflineRecognizer` e o `OfflineTts`.

Isso responde, em horas, uma pergunta que hoje só seria respondida depois de semanas de trabalho.

**Saídas possíveis, a registrar quando a decisão for tomada:**

| Saída | Custo | Efeito no M1 |
|---|---|---|
| (a) Compilar sherpa-onnx + ORT do fonte com 16 KB | Alto; não está no plano | M1 mantém AAB/Play |
| (b) Rebaixar 16 KB de gate de release para risco conhecido | Baixo | M1 entrega **só APK arm64 assinado**; AAB/Play migra para o M2 |
| (c) Esperar o upstream resolver | Zero, mas sem prazo | M1 fica bloqueado por terceiro |

A escolha entre (a), (b) e (c) muda o §13.2, o §19.4 e o formulário de aceite — por isso é pendência, não detalhe.

---

## 3. Lacunas nos contratos normativos

A §5 se declara normativa ("os nomes abaixo são normativos"), e o objetivo editorial da spec é que "a implementação possa ser executada por um agente menor, sem precisar redesenhar a solução". Nos 7 pontos abaixo, o agente **seria obrigado a redesenhar**.

### G-1 — `JobCheckpointStore` nunca é definido (a lacuna mais séria)

`DubbingRuntime` declara `final JobCheckpointStore checkpoints;` como campo **obrigatório** (`especificacao-android.md:157`, e `required this.checkpoints` na linha 167). Mas não existe nenhuma subseção que declare essa interface: a §5 define `DubbingRuntime` (5.1), `MediaToolRunner` (5.2), `ArchiveExtractor` (5.3), `DiskSpaceProbe` (5.4), preparação do tradutor (5.5) e áudio em disco (5.6) — e **para**.

Os *estados* existem (§9.1) e a *política de retomada* existe (§9.4), mas o **contrato** não. O implementador teria de inventar: como se lê/grava um checkpoint, qual a chave, quem valida a saída do estágio, se é a mesma abstração no desktop e no Android, como se relaciona com o `job.json` da §9.3.

Agrava: a §17/D1 manda "adicionar checkpoints" **na fase Windows**, então a interface precisa existir antes mesmo do Android.

### G-2 — `CancellationToken` é acoplado a `dart:io` e não pode cumprir a regra #10

A regra obrigatória #10 exige: *"Cancelamento cooperativo: loops Dart, sherpa, tradução e FFmpeg devem observar o mesmo `CancellationToken`."*

Mas o `CancellationToken` atual (`models.dart:173-186`) é, literalmente:

```dart
class CancellationToken {
  bool _cancelled = false;
  final List<Process> _processes = [];   // <-- dart:io Process
  bool get isCancelled => _cancelled;
  void cancel() {
    _cancelled = true;
    for (final p in _processes) { p.kill(); }
  }
  void addProcess(Process p) { _processes.add(p); }
}
```

Ele só sabe cancelar **processos do sistema operacional**. No Android não há `Process`: o FFmpegKit precisa de `cancel(sessionId)` e o sherpa precisa de um flag cooperativo lido dentro do loop de inferência. Do jeito que está, a regra #10 é **impossível de cumprir**.

Falta na §5 uma generalização — algo como `void addCancellable(void Function() onCancel)`, com `addProcess` reescrito em cima dela. É uma mudança pequena, mas é um **contrato público** que atravessa engine, runners e backends, e não pode ser deixado para o implementador improvisar.

### G-3 — `SeparationOutcome` não tem reason code, e a UI hoje faz o contrário do que a §8/P2 pede

A §8/P2 exige que o `VoiceOverSeparator` retorne `SeparationOutcome.failure` **com reason code `notSupportedInAndroidM1`**, e que isso seja tratado como *"comportamento esperado, não erro nem warning técnico"*.

O contrato real (`interfaces.dart:6-14`) não tem código nenhum — só uma string livre:

```dart
const SeparationOutcome.failure(String this.failureReason) : files = null;
```

E os motivos produzidos hoje são prosa em português (`'Modelo $spleeterModelId não está pronto'`, `'Cancelado pelo usuário'`, …). Pior: o pipeline **emite um warning** quando a separação falha (`pipeline.dart:120-133`) — precisamente o comportamento que a §8/P2 proíbe no Android.

Portanto a §8/P2 exige duas mudanças que a §5 não especifica: (1) um enum de reason code em `SeparationOutcome`; (2) uma mudança de comportamento no pipeline/UI para distinguir "voice-over esperado" de "falha técnica".

### G-4 — A §6 introduz `ModelCatalog` mas não diz como o `ModelManager` o consome

A §6 propõe `enum ModelPlatform { windows, android }` e uma classe `ModelCatalog` com `asrModelIds` e `defaultVoiceIds` por plataforma. Mas não diz **como isso se conecta ao `ModelManager` existente**, e a distância é maior do que parece:

- `ModelManager.manifest` é hoje `static List<ModelEntry> get manifest` (`model_manager.dart:75`) — **estático**, uma lista Dart literal com ~60 entradas hardcoded;
- `ModelEntry` (`model_manager.dart:41-67`) **não tem nenhum campo de plataforma/arquitetura**;
- o estágio `prepare` do pipeline (`pipeline.dart:56-83`) faz o readiness check com **IDs hardcoded** (whisper, voz alvo, spleeter).

Tornar o catálogo dependente de plataforma exige **tornar o manifest de instância**, o que atinge `model_manager_test.dart` (31 testes) e a tela de modelos do app. Nada disso aparece na §17, na §20 ou na §19.1. É um item de trabalho invisível no plano.

### G-5 — Duas fontes de verdade para `ModelManager`

As factories da §5.1 **não recebem** `ModelManager` nem `Tools`:

```dart
typedef TranscriberFactory = Transcriber Function(Preset preset);
typedef TranslatorFactory  = Translator  Function();
```

Mas os backends concretos precisam deles (`WhisperTranscriber(tools, models, preset)`, `TranslateLocallyTranslator(tools, models)`). Logo, o bootstrap teria de capturá-los **por closure**. Só que a nova assinatura de `runDubbingJob` (§5.1) **continua exigindo** `required ModelManager models`.

Resultado: dois caminhos para o mesmo objeto, sem nada que garanta que sejam a mesma instância — exatamente o tipo de "caminho divergente" que a própria §5.1 diz querer evitar ("Um único mecanismo evita caminhos divergentes"). Ou o `ModelManager` entra no `DubbingRuntime`, ou a spec precisa dizer explicitamente que o bootstrap captura a mesma instância que passa a `runDubbingJob`.

### G-6 — O downloader (YouTube) não tem lugar no `DubbingRuntime`

O pipeline importa `youtube.dart` e tem um estágio `download` condicionado a `config.youtubeUrl != null` (`pipeline.dart:85-101`). A regra #3 proíbe executáveis no Android, e o M1 exclui YouTube — mas a §5.1 **não prevê** um downloader entre as dependências do runtime.

A spec precisa dizer como o runtime Android expressa essa ausência: factory nula? estágio removido? `DubbingJobConfig.youtubeUrl` proibido na casca Android? Sem isso, o `pipeline.dart` continua importando um backend concreto — violando a própria regra da §3.2 ("`pipeline.dart` importa backends concretos → receber `DubbingRuntime` obrigatório").

### G-7 — `DiskSpaceProbe` muda de síncrono para assíncrono e a UI não é mencionada

A §5.4 define `Future<int?> freeBytes(String path)`. Mas o `freeBytesForPath` atual (`disk_space.dart:19`) é **síncrono** (`int?`), e é usado sincronamente em **4 pontos da UI** (`home_screen.dart:337, 358, 374, 397`) além do pipeline.

A migração para async é correta (o Android precisa de MethodChannel), mas **toca a UI**, e a spec não menciona isso em lugar nenhum. É pequeno, mas é trabalho não contabilizado.

---

## 4. Imprecisões factuais

- **§16.1 — o check de 16 KB é necessário, mas insuficiente.** `zipalign -c -P 16` verifica se as `.so` estão alinhadas **dentro do zip**; ele **não** verifica o alinhamento do segmento `LOAD` do próprio ELF. O check que realmente importa é `llvm-readelf -l` procurando `align 2**14` em cada `.so`, mais `useLegacyPackaging=false` no Gradle. Um APK pode passar no `zipalign` e ainda assim falhar ao carregar num device de 16 KB. Isso interage diretamente com a **PEND-2**.

- **§16.2 — exige CI, mas não existe CI.** A §16.2 manda "gerar na CI uma lista de todas as `.so` por ABI, tamanho, hash e origem" e "falhar a build" em caso de ABI não autorizada. **Não existe nenhuma CI no repositório** (sem `.github/`, sem qualquer outro arquivo de CI). Criar a CI não aparece na §17 nem no checklist da §20. Ou se adiciona "criar CI" como item de trabalho, ou se troca a exigência por um script local + verificação manual no aceite.

- **§3.2 e §17 — "199 testes" está correto, mas não é verificado por nada.** A contagem confere exatamente: **199** chamadas `test(` em 22 arquivos do engine (o app tem +1 `testWidgets`, totalizando 200). Mas, sem CI, esse número é uma afirmação de documento, não uma barreira. O "Gate" da fase D1 ("199 testes anteriores mais novos testes") depende de alguém rodar e conferir à mão.

- **§10.4 vs `aceite-android.md` §4 — inconsistência de escopo.** A §10.4 condiciona a escolha do slimt **apenas** a en→pt e pt→en. O formulário de aceite pede 100 frases em **6 direções** (incluindo en↔es e os pivôs pt↔es). Os dois documentos precisam concordar sobre o que é gate e o que é medição informativa.

- **§5.2 — `toolTimeout` não é o default real.** A assinatura do `MediaToolRunner` usa `Duration timeout = toolTimeout`. É Dart válido (é `const`), mas hoje o `process_runner.dart` **ignora** `toolTimeout` e hardcoda `Duration(minutes: 30)` em 4 lugares (`:31, :50, :97, :153`). Dívida a alinhar durante a D1 — não é erro da spec, mas o implementador vai tropeçar nisso.

- **SHA-256 — a regra #4 se lê como já cumprida, e não está.** A regra #4 diz que os modelos são "validados por SHA-256", e a §16.3 diz que "nenhum modelo pode entrar no manifest de produção sem URL, SHA-256, licença e atribuição". Na prática, **nenhuma das ~60 entradas do manifest preenche `sha256`**: o `_verifyAndWriteSha256` (`model_manager.dart:744-758`) *calcula* o hash e grava um arquivo sentinela `.sha256`, mas como `entry.sha256` é sempre `null`, **nunca compara nada**. É *trust-on-first-use*, não verificação.
  **Decidido nesta revisão:** o backfill de SHA-256 fica limitado às **entradas novas do Android** (Whisper ONNX e modelos de tradução). As entradas desktop existentes seguem sem verificação. A spec precisa dizer isso explicitamente, para que a regra #4 não seja lida como um fato já verdadeiro.

---

## 5. Riscos no caminho crítico, sem gate

### R-1 — Não existe spike/gate para o TTS (Piper) no Android

Os gates AT-1…AT-5 cobrem tradução, ASR, FFmpeg, foreground service e SAF. O **TTS não tem gate** — é assumido "de graça" por vir do mesmo pacote `sherpa_onnx`. É um backend inteiro no caminho crítico, com consumo de memória próprio (`OfflineTts` carregando um VITS) e dependência da extração de modelos (ver R-2). A premissa é provavelmente verdadeira, mas é **premissa não testada num gate de produto que se diz orientado por gates**.

### R-2 — Descompressão bz2 em Dart puro pode ser lenta o bastante para virar problema de UX

As vozes Piper e os modelos do sherpa são distribuídos como **`.tar.bz2`** (hoje extraídos com o `tar` do Windows: `model_manager.dart:721`, `tar -xjf`). A §5.3 manda, corretamente, injetar um `ArchiveExtractor` e usar `package:archive` no Android — mas o `BZip2Decoder` do `package:archive` é **Dart puro** e notoriamente lento. Dezenas de MB podem custar minutos no celular, e o `ArchiveExtractor` da §5.3 já prevê `onProgress` (bom sinal), mas **não há métrica de aceite** para isso em lugar nenhum.

Sugestão: medir o tempo de extração no AT-2/AT-5 e, se for inaceitável, preferir espelhos `.tar.gz` (o `GZipDecoder` é ordens de grandeza mais rápido) ou arquivos soltos.

### R-3 — Timestamps do Whisper via sherpa: o risco mais subestimado da spec

O pipeline precisa de `TranscriptSegment` com `start`/`end` reais. No desktop, o `whisper-cli` entrega segmentos **já com timestamps**. No Android, o `OfflineRecognizer` do sherpa entrega **texto por janela** — então os timestamps passam a vir das **fronteiras da janela/VAD**, e não do modelo. É exatamente o que a §8/P3 descreve ("converter timestamps locais da janela em timestamps absolutos"), mas a consequência não é enfrentada: **a granularidade do timestamp passa a ser a da janela de VAD.**

E o critério **de release** da §19.4 exige **≥90% dos segmentos dentro de ±300 ms**.

O aceite do AT-2 (§11.3) **não mede isso**. Ele mede RTF, pico de memória, timestamps não-regressivos e "diferença perceptual contra whisper-cli documentada e aceitável" — uma formulação vaga demais para um gate. O resultado é que a spec pode aprovar o AT-2, construir o pipeline inteiro, e só descobrir na fase D4 que a sincronia não fecha.

**Mitigação (barata e alta):** mover a métrica de ±300 ms **para dentro do AT-2** — transcrever o mesmo clipe de 5 min com whisper-cli (desktop) e com sherpa (device), alinhar as fronteiras de fala e medir a distribuição do erro. Isso valida o gate de release **antes** de haver pipeline.

*Atenuante:* o `trimDubbingSegmentsToSpeech` (`speech_trim.dart:51`) já reancora as fronteiras dos segmentos na energia real do áudio, o que corrige parte do erro de janela. Mas isso precisa ser **medido**, não presumido.

### R-4 — O VAD não está no manifest, e o fallback sem VAD não tem algoritmo

A §8/P3 diz "processar janelas de até 30 s, **preferencialmente delimitadas por VAD**". Mas:

- **Se usar VAD:** o Silero VAD é um *modelo*, e **não está no manifest atual** (que tem whisper ggml, spleeter, ~55 vozes Piper, `gender-tagging` e `diarization-*`). Precisa de nova entrada com URL, SHA-256 e licença — e isso interage com a G-4 (o manifest não é por plataforma).
- **Se não usar VAD:** o fallback especificado é "30 s com overlap de 1 s e **deduplicar tokens/texto no overlap**". Deduplicação de texto em overlap de ASR é um problema **notoriamente difícil** (repetição parcial, cortes no meio de palavra, alucinação de borda do Whisper), e a spec **não fornece o algoritmo**. Um agente menor não tem como acertar isso por conta própria.

É um ponto de decisão real, não um detalhe de implementação.

### R-5 — `amix=duration=first` trunca a última fala — **bug latente no desktop hoje**

Este achado não é sobre o Android: é sobre o código atual, e a spec o herda sem perceber.

O `buildDubTrack` **deliberadamente estende** o buffer além do fim do vídeo, com um comentário explícito (`mixer.dart:16-24`):

```dart
// A última fala pode ultrapassar o fim do vídeo por causa do atraso
// acumulado do agendamento; reserva espaço para não cortá-la.
var totalSamples = (videoDurationSec * mixSampleRate).round();
for (final seg in segments) { ... if (end > totalSamples) totalSamples = end; }
```

E então, **no mesmo arquivo**, o mix final joga isso fora (`mixer.dart:57-61`):

```dart
'-i', p.join(workDir, 'audio_full.wav'),   // [0:a] = original, exatamente a duração do vídeo
'-i', p.join(workDir, 'dub_voice.wav'),    // [1:a] = dublagem, possivelmente mais longa
'[0:a][1:a]sidechaincompress=...[bg];'
'[bg][1:a]amix=inputs=2:duration=first:normalize=0,'   // <-- "first" = [0:a] = o original
```

`duration=first` amarra a duração da saída ao **input 0** (o áudio original). Portanto qualquer cauda de dublagem que ultrapasse o fim do original é **cortada pelo ffmpeg** — anulando exatamente o cuidado tomado 40 linhas acima. As duas funções do `mixer.dart` se contradizem.

Isso colide de frente com o critério de release da §19.4: **"nenhuma fala for truncada"**. E a §7.2 (writer sequencial) reproduz o mesmo cuidado do `buildDubTrack` ("completar silêncio até a duração necessária") sem tocar no mix — ou seja, a refatoração proposta **preserva o bug**.

**A spec precisa decidir:** o mix final deve ser estendido (`duration=longest`, com pad do vídeo no mux)? Ou o overflow no fim é aceitável e o critério da §19.4 deve ser reescrito para excluí-lo? Hoje a spec quer as duas coisas.

*(Vale conferir se algum dos 8 testes de `mixer_test.dart` cobre o caso da cauda; a existência do comentário sugere que o cenário foi pensado, mas não que foi testado ponta a ponta.)*

### R-6 — O fallback bergamot não tem time-box

"Compilar `bergamot-translator` completo via NDK arm64" (§10.2, passo 6) é aberto: sem estimativa, sem critério de desistência, sem plano B. É o único caminho previsto se o AT-1 falhar, e a spec proíbe explicitamente um terceiro backend ("Não criar um terceiro backend no M1"). Se a **PEND-1** se confirmar, este risco praticamente desaparece.

---

## 6. O que a spec acerta (verificado)

Vale registrar, porque dá confiança no resto e porque parte disso é contraintuitivo:

- **O filtro de ducking da §8/P8 está correto — e é cópia exata do código atual.** Conferido caractere por caractere contra `mixer.dart:60-62`. E o grafo faz sentido no modo voice-over: sem separação, `[0:a]` **é** mesmo o áudio original completo (voz + música), que é *duckado* usando a dublagem como sidechain. A spec não errou ao reaproveitá-lo.

- **A invariável de não-sobreposição do §7.2 é real.** A spec afirma que "o scheduler atual não permite sobreposição" e propõe construir o writer sequencial em cima disso. **Confere** (`fitter.dart:198-207`): `placementSec = max(segStart, cursorSec)`, e o cursor retornado é `placementSec + finalDurSec`, encadeado serialmente em `pipeline.dart:270-278`. Logo, cada `placedStart` ≥ fim da fala anterior.
  *Nuance a registrar:* a invariável mora no **fitter**, não no `planDubSchedule` (que só devolve `({speed, clamped})`, sem timestamps). E o `buildDubTrack` atual **tolera** sobreposição (soma aditivamente, `mixer.dart:32`). O writer novo, ao lançar erro em `startSamples < cursorSamples` (§7.2, passo 4), passa a ser **mais estrito** que o código atual — o que é bom, mas é uma mudança de contrato que merece um teste dedicado (a §19.1 já prevê: "writer rejeita overlap"). ✔

- **A tabela de acoplamentos da §3.2 está inteiramente correta.** Todos conferidos: `tools/win` (`tool_locator.dart:61-71`), `tar` (`model_manager.dart:721`), `APPDATA` (`main.dart:19`), `cmd`/`explorer` (`home_screen.dart:177`, `progress_screen.dart:134`), `buildDubTrack` alocando um `Float32List` do vídeo inteiro (`mixer.dart:25`), `readWav` lendo o arquivo inteiro (`wav.dart:51`), `fittedAudio` como `Float32List` (`models.dart:91`).

- **O problema de memória é pior do que a spec argumenta.** Dois agravantes que a §3.2 não menciona:
  1. `writeWavPcm16` (`wav.dart:114`) monta o arquivo com um spread — `[...header.buffer.asUint8List(), ...int16.buffer.asUint8List()]` — materializando uma `List<int>` *boxed* do arquivo inteiro, muito pior que o `Int16List` que a acompanha.
  2. No estágio `mix`, o processo segura **simultaneamente**: todos os `naturalAudios` (22 kHz), todos os `fittedAudio` (44,1 kHz), o buffer `Float32List` do vídeo inteiro **e** a cópia `Int16List` — mais a lista boxed acima.
  Ou seja: a refatoração da §7 é **mais urgente** do que a própria spec faz parecer. Isso é um argumento a favor da spec, não contra.

- **A fórmula de espaço da §15.1 é sã.** Os `500_000` bytes/s conferem com a soma real dos intermediários: `audio_full` (176 KB/s) + `asr_in` (32 KB/s) + `dub_voice` (88 KB/s) + `dubbed` (176 KB/s) ≈ **472 KB/s**, mais os WAVs por segmento. A margem é apertada, mas correta.

- **A versão do `sherpa_onnx` bate.** O engine declara `^1.12.0` e o lock resolve **1.13.4** — exatamente o que a §11.1 pede. Os lockfiles já puxam `sherpa_onnx_android_arm64`. (O que **não** bate é o 16 KB — ver PEND-2.)

- **FFmpegKitNext: a spec está certa em exigir build do fonte.** Verificado: a tag **8.1.0 existe**, e todos os releases declaram explicitamente que *"FFmpegKitNext does not provide prebuilt binaries"*. Não há atalho via Maven/AAR — o build LGPL do fonte (§12.1) é **obrigatório**, não uma preferência de pureza.

---

## 7. Coerência entre documentos

- ✔ **Repositório único.** `decisoes.md:19` (2026-07-11) e a §2.1 da spec concordam: Android e Windows no mesmo repo e no mesmo app Flutter, engine por dependência de path. O `plano-de-desenvolvimento.md` (Fase 3) repete a mesma coisa. Sem divergência.

- ⚠ **Higiene — duas cópias do documento normativo.** `E:\projects\omnitranslator-android` existe como **repositório git irmão** e mantém **sua própria cópia** de `docs/especificacao-android.md` e de `docs/spikes-android/`. Duas cópias de um documento normativo divergem por construção — e a spec só diz que o protótipo é "somente fonte de spikes" (§2.1 / `decisoes.md:19`), sem mandar apagar ou neutralizar a cópia. Recomendação: reduzir os docs do protótipo a um `README` apontando para o repo principal.

- ✔ **SA1 é consistente com a spec.** O §10 do SA1 ("en↔pt no slimt: FALHOU"; "fonte limpa/reproduzível: PENDENTE") casa com o §10 da especificação. O que muda é o **contexto** — ver PEND-1.

---

## 8. Como esta auditoria foi feita

- **Código:** 3 varreduras independentes sobre `packages/dubbing_engine` — (a) contratos e pipeline (`interfaces.dart`, `pipeline.dart`, `models.dart`), (b) acoplamento de plataforma (`tool_locator.dart`, `process_runner.dart`, `model_manager.dart`, `disk_space.dart`, app), (c) caminho de áudio e memória (`wav.dart`, `mixer.dart`, `fitter.dart`, `segmenter.dart`, `speech_trim.dart`). Todas as citações `arquivo:linha` deste relatório foram lidas diretamente no arquivo.
- **Fontes externas:**
  - FFmpegKitNext — <https://github.com/arthenica/ffmpeg-kit-next/releases> (tags e ausência de binários).
  - sherpa-onnx — issues [#2413](https://github.com/k2-fsa/sherpa-onnx/issues/2413), [#2641](https://github.com/k2-fsa/sherpa-onnx/issues/2641), [#3291](https://github.com/k2-fsa/sherpa-onnx/issues/3291) e PR [#2657](https://github.com/k2-fsa/sherpa-onnx/pull/2657).
  - Modelos de tradução — <https://github.com/mozilla/firefox-translations-models> (listagem de `models/tiny/`).

---

## 9. Resumo acionável

| Item | Tipo | Ação sugerida |
|---|---|---|
| **PEND-1** — tiny `enpt`/`pten` existem | Pendência | Decidir tier antes de investir no bergamot. Pode economizar semanas. |
| **PEND-2** — 16 KB vs. ORT 1.17.1 | Pendência | Criar gate **AT-0** (horas) antes de qualquer outro spike. |
| **G-1** — `JobCheckpointStore` indefinido | Lacuna | Definir a interface na §5 antes da fase D1. |
| **G-2** — `CancellationToken` só cancela `Process` | Lacuna | Generalizar (`addCancellable`) — a regra #10 depende disso. |
| **G-3** — `SeparationOutcome` sem reason code | Lacuna | Adicionar enum + mudar o warning do pipeline. |
| **G-4** — `ModelCatalog` vs. manifest estático | Lacuna | Especificar a migração; contabilizar os 31 testes afetados. |
| **G-5** — dupla fonte de `ModelManager` | Lacuna | Mover para dentro do `DubbingRuntime` ou explicitar a captura. |
| **G-6** — downloader fora do runtime | Lacuna | Dizer como o Android expressa a ausência de YouTube. |
| **G-7** — `DiskSpaceProbe` async | Lacuna | Contabilizar os 4 pontos da UI. |
| **R-3** — sincronia dos timestamps | Risco | Mover a métrica de ±300 ms para dentro do AT-2. |
| **R-5** — `duration=first` trunca a cauda | **Bug atual** | Decidir o comportamento; hoje o código se contradiz. |
| **R-2** — bz2 em Dart puro | Risco | Medir a extração no device; considerar `.tar.gz`. |
| **R-1** — TTS sem gate | Risco | Anexar um teste de TTS ao AT-2. |
| **R-4** — VAD sem modelo/algoritmo | Decisão | Escolher VAD (nova entrada no manifest) ou especificar a dedup. |
| **§16.2** — CI inexistente | Imprecisão | Adicionar "criar CI" ao plano, ou trocar por script local. |
