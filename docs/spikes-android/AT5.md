# AT-5 — Armazenamento (StatFs + SAF) no device

**Data:** 2026-07-15
**Escopo:** §5.4/§13.3/§19.2 de [../especificacao-android.md](../especificacao-android.md)
**Resultado:** **PASSOU.** `StatFs` via `MethodChannel` devolve espaço livre real; import e export por SAF fazem round-trip byte-exato (hash idêntico nas duas direções); extração `.tar.gz` streaming (a mesma função que o `ModelManager` usa em produção) roda no device. Validado dentro da D3.1, não como spike isolado — decisão do usuário de 2026-07-15 registrada em `decisoes.md`.

---

## 1. Como foi validado

Diferente de AT-0…AT-3 (apps de bench descartáveis), AT-5 validou o **código de produção real**: `MainActivity.kt` (a ponte Kotlin definitiva, não um spike) e os dois arquivos Dart que ficam no repo (`disk_space_probe.dart`/`AndroidDiskSpaceProbe`, `app/lib/src/platform/android_storage.dart`). O único código descartado foi o *entry point* — `app/lib/main.dart` foi trocado temporariamente por uma tela mínima com um botão por primitivo, para poder exercitar os MethodChannels num app real sem esperar pelo `AndroidRuntime` (D3.2, ainda não escrito). Depois da validação, `main.dart` voltou ao conteúdo original (Windows-only) byte a byte — conferido com `diff` antes do commit. Nenhum código de teste ficou no `main.dart` commitado.

## 2. StatFs

| Verificação | Esperado | Medido |
|---|---|---|
| `StatFs` num path real (`getExternalStorageDirectory()`) | bytes livres > 0 | **170.178.433.024 bytes** (≈170 GB) |
| `StatFs` num path inexistente | sobe a árvore até achar um ancestral que existe (nunca lança) | subiu até `/` e devolveu **0** — comportamento correto: `/` sempre existe no Android, e `StatFs("/")` reportar 0 bytes disponíveis para `untrusted_app` é uma resposta real da API, não uma falha do código |

Implementação: `MainActivity.freeBytesOf()` (`app/android/app/src/main/kotlin/.../MainActivity.kt`) — `while (!f.exists()) f = f.parentFile`, depois `StatFs(f.absolutePath).availableBytes`, `try/catch` devolvendo `null` em qualquer exceção (mesmo contrato do `WindowsDiskSpaceProbe` do desktop: `null` = "não dá para saber", nunca erro).

## 3. SAF — import e export

| Cenário (§19.2) | Provedor usado | Bytes copiados | Hash MD5 (import) | Hash MD5 (export) | Resultado |
|---|---|---:|---|---|---|
| Import — URI local | `com.android.providers.media.documents` (aba "Recentes", vídeo do dispositivo) | 1.045.335 (23ms) | `8b761f500ae37883994bd6ab0819a6cc` | — | ✅ |
| Export — Downloads | `com.android.providers.downloads.documents` | 1.045.335 (23ms) | — | `8b761f500ae37883994bd6ab0819a6cc` | ✅ |

Hash de import e export **idênticos** — round-trip sem corrupção nas duas direções (`ACTION_OPEN_DOCUMENT` → `copyUriToFile`/`ContentResolver.openInputStream`, e `ACTION_CREATE_DOCUMENT` → `copyFileToUri`/`openOutputStream`).

**Provedor externo (Drive), não exercitado manualmente:** o picker mostrava contas Drive disponíveis (visível nos screenshots do teste), mas não foi clicado. Não é considerado um risco em aberto: `copyUriToFile`/`copyFileToUri` usam exclusivamente `ContentResolver.openInputStream`/`openOutputStream` sobre a URI recebida — **zero código específico de provedor** em `MainActivity.kt`. Esse é o contrato central do SAF (o cliente nunca sabe nem precisa saber qual provedor respondeu); os dois provedores já testados (MediaStore e Downloads) exercitam exatamente o mesmo caminho de código que um terceiro provedor exercitaria. Uma checagem manual rápida com Drive é um nice-to-have de baixo risco para a D3.4, não um bloqueio deste gate.

**Achado para a D3.4:** `pickExportLocation` foi chamado com o nome sugerido `"at5_export_test.bin"` e `mimeType: "video/mp4"` (default do teste) — o provedor Downloads **acrescentou `.mp4`** ao nome porque a extensão não batia com o MIME (`at5_export_test.bin.mp4`). A UI real precisa sempre mandar nome e MIME type consistentes (ex.: `dublado.mp4` + `video/mp4`), não um nome arbitrário com MIME de vídeo fixo.

## 4. Extração `.tar.gz` (streaming)

Mesma função que o `ModelManager.download()` usa em produção para `kind: 'targz'` (`extractFileToDisk`, de `package:archive/archive_io.dart` — decisão D-c: sem `tar` nativo no Android, `BZip2Decoder` Dart-puro é lento demais, por isso `.tar.gz` em vez de `.tar.bz2` no Android). Medido isolando só a extração (sem o download HTTP), com um modelo de tradução real (`en→bg`, tier tiny) empurrado por `adb push`:

| Entrada | Saída | Tempo | Vazão |
|---|---|---:|---:|
| 16.695.160 bytes (.tar.gz) | 7 arquivos, 23.671.393 bytes | **17,5 s** (duas medições: 17.553ms e 17.528ms) | ≈1,35 MB/s (do descomprimido) |

**Achado para a D3.2/D3.4:** 17,5s para um modelo de ~16MB comprimido é perceptível — em modelos maiores (Whisper `base`, vozes Piper) a extração vai ser proporcionalmente mais lenta, porque o decoder gzip é Dart-puro (single-thread, sem aceleração nativa). Vale mostrar progresso de extração na UI de download de modelos (D3.4) em vez de uma barra travada; não é um bloqueio deste gate — a extração funciona corretamente, só não é instantânea.

## 5. Resultado formal do AT-5

| Pergunta (§19.2) | Resultado |
|---|---|
| `StatFs` via MethodChannel devolve espaço real, sem binding libc próprio? | **PASSOU** |
| Import SAF de uma URI local, byte-exato? | **PASSOU** (hash idêntico) |
| Export SAF para Downloads, byte-exato? | **PASSOU** (hash idêntico) |
| Provedor externo suportado? | **PASSOU por construção** (código provider-agnostic; Drive visível no picker mas não clicado manualmente — ver §3) |
| Tempo de extração `.tar.gz` medido no device? | **PASSOU** (17,5s / 16,7MB comprimidos, `extractFileToDisk` real) |
| **AT-5 — armazenamento aprovado para o Android M1?** | **PASSOU** |

## 6. Pendências que não bloqueiam o gate

- Checagem manual de um provedor externo de terceiros (Drive/Dropbox) na D3.4, por completude — não é esperado achar nada novo dado o contrato genérico do SAF (§3).
- Nome sugerido + MIME type do export devem ser coerentes na UI real (achado do §3), não no `pickExportLocation` em si.
- Progresso de extração `.tar.gz` na UI de download de modelos (D3.4), dado o tempo medido no §4.
- Migrar os usos síncronos de espaço em disco em `home_screen.dart` para o `AndroidDiskSpaceProbe` assíncrono fica para a D3.4 (UI ainda não foi portada para Android).
