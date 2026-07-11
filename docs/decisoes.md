# Decisões de Implementação

<!-- Registre aqui decisões não cobertas pela spec, conforme regra de ouro #2. -->

| Data | Decisão |
|---|---|
| 2026-07-08 | `_addProcess` renomeado para `addProcess` (público) porque o prefixo `_` no Dart torna o método privado à biblioteca, e `process_runner.dart` está em arquivo diferente de `models.dart`. |
| 2026-07-08 | Número de threads dinâmico: `max(2, Platform.numberOfProcessors - 2)` implementado em `_threadCount()` nos backends whisper e sherpa. |
| 2026-07-08 | Arquivos temporários do translateLocally movidos para `Directory.systemTemp` em vez de `Directory.current` para evitar poluição do diretório de trabalho. |
| 2026-07-08 | `runTool` agora faz polling a cada 200ms do `CancellationToken` para matar o processo se cancelado (spec seção 6.1). |
| 2026-07-11 | Expansão de idiomas (3→23): `enum Lang` virou *enhanced enum* (Dart 3) com metadados (`code`, `label`, `iso639_2`, `isDubTarget`, `whisperCode`) em vez de switches exaustivos espalhados — com 23 valores, um switch por local de uso seria muito mais frágil que um construtor obrigatório por valor. |
| 2026-07-11 | Islandês usa o valor de enum `isl` (não `is`, palavra reservada em Dart) com `code: 'is'` — é por isso que `code` (não `Lang.name`) alimenta o whisper, o muxer e os nomes de arquivo. |
| 2026-07-11 | Pares de tradução viraram tabela declarativa (`translation_catalog.dart`) com `translationPath()` generalizando o pivô via inglês (antes só pt↔es) para qualquer par sem modelo direto — inclui suporte a três chaves apontando para o mesmo id (`hr-en`/`sr-en`/`bs-en` → `hbs-eng-tiny`, macrolíngua sérvio-croata no catálogo do translateLocally). |
| 2026-07-11 | **Achado empírico**: o I/O do translateLocally por arquivo (`-i`/`-o`) usa o encoding local do sistema (cp1252 no Windows) — mas por **stdin/stdout** ele é UTF-8 puro (testado com bg-en-tiny e caracteres cirílicos). O tradutor foi migrado para stdin/stdout (`runToolWithStdin` em `process_runner.dart`), eliminando os arquivos temporários e destravando idiomas com scripts não-latinos (búlgaro, ucraniano, grego, sérvio). |
| 2026-07-11 | Sérvio: o modelo `hbs-eng-tiny` só traduz corretamente em script latino — cirílico produz saída sem sentido (testado: "Мачка спава на каучу." → "I'm on it."). Como o alfabeto cirílico sérvio tem correspondência 1:1 com o latino (reforma de Vuk Karadžić), o texto de origem sérvio é transliterado cirílico→latino antes da tradução (`_serbianCyrillicToLatin` em `translatelocally_translator.dart`), sem perdas. |
| 2026-07-11 | Búlgaro (`bg`) tem tradução `en↔bg` mas **nenhuma voz piper mirrorada** no release `tts-models` do sherpa-onnx (confirmado por HEAD 404 nas duas variantes de nome + ausência na documentação oficial) — por isso ficou como língua só-origem (`isDubTarget: false`), diferente do plano inicial que previa 5 alvos novos (ficaram 4: de/fr/pl/cs). |
| 2026-07-11 | Vozes piper novas validadas via HEAD contra o release do sherpa-onnx (não a API do GitHub, que tem rate limit agressivo para requisições anônimas) — script `packages/dubbing_engine/tool/gen_voice_manifest.dart`. IDs de voz legados (`piper-pt-br`, `piper-en` etc.) são imutáveis: são nomes de diretório em disco e ficam persistidos em `settings.voiceModelId`. |
