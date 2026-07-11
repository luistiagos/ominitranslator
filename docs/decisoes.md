# Decisões de Implementação

<!-- Registre aqui decisões não cobertas pela spec, conforme regra de ouro #2. -->

| Data | Decisão |
|---|---|
| 2026-07-08 | `_addProcess` renomeado para `addProcess` (público) porque o prefixo `_` no Dart torna o método privado à biblioteca, e `process_runner.dart` está em arquivo diferente de `models.dart`. |
| 2026-07-08 | Número de threads dinâmico: `max(2, Platform.numberOfProcessors - 2)` implementado em `_threadCount()` nos backends whisper e sherpa. |
| 2026-07-08 | Arquivos temporários do translateLocally movidos para `Directory.systemTemp` em vez de `Directory.current` para evitar poluição do diretório de trabalho. |
| 2026-07-08 | `runTool` agora faz polling a cada 200ms do `CancellationToken` para matar o processo se cancelado (spec seção 6.1). |
