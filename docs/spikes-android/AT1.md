# AT-1 — Tradução en↔pt no Android

**Data:** 2026-07-12 (fonte/qualidade) · 2026-07-13 (execução no moto g86)
**Escopo:** §10 de [../especificacao-android.md](../especificacao-android.md)
**Resultado:** **REPROVOU.** en→pt passa; **pt→en reprova** por repetição degenerada — decodificação gulosa do slimt, não qualidade do modelo. §10.4 → decidir entre corrigir o decodificador do slimt ou o fallback bergamot. Ver §6–§7.

---

## 1. Passos 1–2 da §10.2 — fonte pública, licença e SHA-256

### 1.1 O repositório arquivado NÃO serve para download (correção)

A auditoria (PEND-1) e a primeira redação da §10 apontavam `mozilla/firefox-translations-models` como a fonte, argumentando que o arquivamento em 15/12/2025 tornava as URLs imutáveis. **Isso está errado na parte que importa:** os arquivos de modelo estão em **Git LFS**, e os objetos LFS **foram removidos do servidor**:

```
POST https://github.com/mozilla/firefox-translations-models.git/info/lfs/objects/batch
→ { "error": { "code": 410, "message": "Object does not exist on the server" } }
```

`raw.githubusercontent.com` devolve o **ponteiro** LFS (131–133 bytes), não o modelo. `media.githubusercontent.com` devolve 404. Um repositório arquivado preserva o histórico, **não** o armazenamento LFS.

O que o repositório **ainda** serve, e que é valioso: os `metadata.json` de cada modelo (arquivos pequenos, versionados normalmente, fora do LFS). Eles contêm arquitetura, hash, tamanho e métricas de qualidade.

### 1.2 A fonte real: Remote Settings do Firefox

Os mesmos modelos são distribuídos ao Firefox por **Remote Settings**, com CDN pública, versionamento e SHA-256 no próprio registro:

```
índice:  https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/translations-models/records
CDN:     https://firefox-settings-attachments.cdn.mozilla.net/<attachment.location>
```

Cada registro traz `fromLang`, `toLang`, `fileType` (`model` | `vocab` | `lex`), `version`, e um `attachment` com `location`, `size` e `hash` (SHA-256). São 679 registros no total.

### 1.3 O mapeamento tiny ↔ versão (fechado por hash)

| Versão no Remote Settings | Arquitetura | `byteSize` do modelo |
|---|---|---|
| **v1.0** | **`tiny`** (dec-cell `ssru`, `dec-depth: 2`, `enc-depth: 6`, `dim-emb: 256`) | 17.140.899 |
| v2.0 / v2.1 | `base-memory` | 31.561.787 |

Não é inferência por tamanho: o `metadata.json` de `models/tiny/enpt` declara `"architecture": "tiny"`, `"byteSize": 17140899` e `"hash": "8fb05a27…"` — **exatamente** o `attachment.hash` do registro **v1.0** do Remote Settings. Os dois catálogos descrevem o mesmo arquivo.

A `dec-cell: ssru` + `dec-depth: 2` é precisamente a arquitetura que o slimt implementa (e a única — ver `docs/decisoes.md`, 2026-07-12).

### 1.4 Download verificado

```
GET https://firefox-settings-attachments.cdn.mozilla.net/main-workspace/translations-models/b268bf87-94b6-4893-9da1-c4e75284ace7.bin
→ HTTP 200, 17.140.899 bytes, 0,8 s
  sha256 = 8fb05a27509bea3f67d2f59506485584d5cdbdcafa82b251576c27e91bd7011e   ✅ confere
```

### 1.5 Licença

MPL-2.0 (`mozilla/firefox-translations-models`). Atribuição obrigatória nos notices (§16.3).

## 2. Qualidade — tiny × base-memory, com números da própria Mozilla

Cada `metadata.json` publica BLEU e COMET no FLORES. Isso responde, **sem rodar nada**, a pergunta que a decisão D-a deixara em aberto ("a divergência de qualidade desktop×Android é aceitável?").

| Par | tiny BLEU | base BLEU | Δ | tiny COMET | base COMET | Δ |
|---|---:|---:|---:|---:|---:|---:|
| **en→pt** | **49,4** | 50,0 | **−0,6** | **0,8895** | 0,8910 | **−0,0015** |
| **pt→en** | **47,8** | 47,9 | **−0,1** | **0,8866** | 0,8887 | **−0,0021** |
| en→es | 25,9 | 27,7 | −1,8 | 0,8414 | 0,8527 | −0,0113 |
| es→en | 27,5 | 27,5 | 0,0 | 0,8513 | 0,8568 | −0,0055 |

Nos pares que são **gate** (en↔pt), a perda é de **0,6 e 0,1 BLEU** — ruído. O tiny custa metade do tamanho (17 MB × 31,5 MB) e roda numa engine que já sabemos compilar para arm64.

Comparar BLEU **entre pares diferentes** não significa nada (o FLORES tem dificuldade distinta por idioma); o que vale é a coluna Δ, dentro do mesmo par.

## 3. Efeito colateral: a fonte do desktop também está resolvida

O `decisoes.md` registrava o risco de que uma instalação limpa não conseguisse mais baixar `en-pt-base` (o par sumiu do `translateLocally -a`).

O modelo instalado hoje em `%LOCALAPPDATA%\translateLocally\enpt\` foi hasheado e é **bit a bit idêntico** ao registro **v2.1** do Remote Settings:

```
local  : 07892fd2544ee79dcb643615d8f2debb9793fae16842e87c328e27a3dd26a770
RS v2.1: 07892fd2544ee79dcb643615d8f2debb9793fae16842e87c328e27a3dd26a770   ✅
```

Os três arquivos batem em tamanho (`model` 31.561.787, `lex` 3.970.340, `vocab` 816.726). Portanto existe fonte pública, pinável e hasheável para o pt **também no Windows** — o risco está encerrado.

## 4. Entradas de catálogo (Android, tier tiny, v1.0)

Base CDN: `https://firefox-settings-attachments.cdn.mozilla.net/`

| ID | Par | Arquivo | `location` (sob `main-workspace/translations-models/`) | Bytes | SHA-256 |
|---|---|---|---|---:|---|
| `mt-tiny-enpt` | en→pt | `model.enpt.intgemm.alphas.bin` | `b268bf87-94b6-4893-9da1-c4e75284ace7.bin` | 17.140.899 | `8fb05a27509bea3f67d2f59506485584d5cdbdcafa82b251576c27e91bd7011e` |
| | | `vocab.enpt.spm` | `745bff57-f929-41d9-8f0f-913513cfd334.spm` | 817.234 | *(colher do registro)* |
| | | `lex.50.50.enpt.s2t.bin` | `be3a2e24-b12e-4c0e-b07a-c7b0ba6ab421.bin` | 4.345.620 | *(colher do registro)* |
| `mt-tiny-pten` | pt→en | `model.pten.intgemm.alphas.bin` | `dc4327ec-9ebc-4c12-8037-48cd30f3076d.bin` | 17.140.899 | `b4a1fd10…` (metadata) |
| | | `vocab.pten.spm` | `75fa56af-540e-4a56-8a9f-1317ae7a9c61.spm` | 817.234 | *(colher do registro)* |
| | | `lex.50.50.pten.s2t.bin` | `013e0ebf-3d6b-4723-b83e-0e00ed29477f.bin` | 4.801.740 | *(colher do registro)* |

`mt-tiny-enes` / `mt-tiny-esen`: colher do mesmo índice (registros `fromLang`/`toLang` = en/es, `version` `1.0`).

**Peso total do pacote de tradução en/pt/es no Android:** ~4 modelos × 17 MB + vocabs + lex ≈ **90 MB**.

> **Atenção — os `location` são UUIDs por versão.** Não são estáveis entre versões do registro; são estáveis para uma versão dada. Fixar `location` **e** `hash` juntos no catálogo, e validar o hash após o download (o `_verifyAndWriteSha256` já sabe comparar quando `entry.sha256 != null`).

## 5. Resultado formal dos passos 1–2

| Pergunta | Resultado |
|---|---|
| Existe fonte pública e reproduzível para en↔pt? | **PASSOU** (Remote Settings / CDN Mozilla) |
| O repo arquivado serve como fonte? | **NÃO** — LFS removido (410) |
| Os modelos tiny são a arquitetura que o slimt suporta? | **PASSOU** (`ssru`, `dec-depth: 2`) |
| Licença permite redistribuição? | **PASSOU** (MPL-2.0) |
| SHA-256 registrado e verificado no download? | **PASSOU** |
| A qualidade do tiny é aceitável ante o `base-memory`? | **PASSOU** (−0,6 / −0,1 BLEU nos pares de gate) |
| Fonte reproduzível para o `base-memory` do desktop? | **PASSOU** (bit a bit idêntico ao v2.1) |

## 6. Execução no device — moto g86 5G (2026-07-13)

**Aparelho:** moto g86 5G, Android 16, arm64-v8a. **Binário:** o `slimt-cli` (32,5 MB) e a `libslimt.so` (3,0 MB, ELF AARCH64) do build do SA-1, recuperados do cache (`E:\dev_cache\temp`). **Modelos:** tiny v1.0 baixados do Remote Settings (SHA-256 conferido). **Suíte:** 100 frases por direção, versionadas em [at1-suite/](at1-suite/) (`en.txt`, `pt.txt`).

**Invocação:** sem `--shortlist` (ver §6.1). Uma direção = uma passada do `slimt-cli` com stdin/stdout.

### 6.1 Achado de configuração — o shortlist (lex) degenera a saída

Com o shortlist (`--shortlist lex.50.50.*.s2t.bin`), as duas direções produzem lixo (palavras não traduzidas, `......`, repetição). **Sem o shortlist, a tradução fica correta.** O lex restringe o vocabulário de saída por token de origem e, no formato destes modelos, incompatibiliza com o slimt. Consequência: **o pacote Android não precisa dos arquivos `lex`** — só `model` + `vocab` (economiza ~4,3 MB por par).

Os warnings `Failed to ingest Wemb_QuantMultA` e `special:model.yml` aparecem sempre, mas são **benignos**: o modelo en→de (§6.3) mostra os mesmos e traduz limpo.

### 6.2 Métricas (§10.4)

| Direção | Frases | Não vazias | Tempo total | ms/frase | Pico RSS | Crashes |
|---|---:|---:|---:|---:|---:|---:|
| **en→pt** | 100 | 100 | 1978 ms | ~20 | 114 MB | 0 |
| **pt→en** | 100 | 100 | 2110 ms | ~21 | 112 MB | 0 |

Velocidade e memória passam com folga enorme (teto: 300 ms/frase e 500 MB). **O gargalo é só qualidade.**

### 6.3 Qualidade — a assimetria que reprova o gate

| Direção | Limpas (4-gram estrito) | Leitura humana | Veredito §10.4 |
|---|---:|---|---|
| **en→pt** | **100/100** | ~96 boas (erros isolados: "deleitado", "regogo", 2 repetições curtas) | ✅ **passa** |
| **pt→en** | **85/100** | ~75 boas — **repetição degenerada pervasiva** | ❌ **reprova** (< 90) |

O padrão do pt→en é sempre "tradução correta + cauda repetida":

- `Eu gostaria de uma xícara de café.` → `I would like a cup of coffee. I would like a cup of coffee.`
- `Ela fala quatro idiomas fluentemente.` → `She speaks four languages fluently. She speaks four languages fluently.`
- `Eu rego as plantas dia sim, dia não.` → `I water the plants day out day, day out, I revel in the plants day out. Day, I re…` (severa)

**Não é problema de qualidade do modelo nem de arquitetura:**

- as traduções em si estão corretas — é a decodificação que não pára no EOS e repete;
- `--limit-tgt` só corta o comprimento, não desfaz o loop (testado com 1.2 / 1.5 / 3.0);
- o slimt-cli decodifica **guloso** (beam 1), sem normalização de comprimento nem penalidade de repetição — nenhuma dessas é exposta na CLI;
- **en→de tiny (mesma arquitetura, mesma fonte, mesmos warnings) traduz limpo, sem repetir.** Logo o defeito é a interação do decodificador guloso do slimt com os modelos **pt** especificamente.

## 7. Resultado formal do AT-1

| Pergunta | Resultado |
|---|---|
| slimt roda no moto g86 e carrega os tiny? | **PASSOU** |
| en→pt: 100/100 não vazias, ≥90 aceitáveis, sem crash/degeneração? | **PASSOU** |
| Velocidade ≤ 300 ms/frase e RSS ≤ 500 MB? | **PASSOU** (~20 ms, ~114 MB) |
| pt→en: ≥90 aceitáveis, sem repetição degenerada? | **REPROVOU** (~85% limpo; repetição pervasiva) |
| **slimt aprovado no AT-1 (as duas direções)?** | **NÃO** — pt→en reprova |

### 7.1 Consequência (§10.4) e recomendação

A regra do §10.4 é clara: se qualquer critério falhar, **usar bergamot-translator completo**. pt→en falha, então o slimt **não é aprovado** como está.

Mas o diagnóstico aponta um caminho barato antes do fallback caro: **o problema é o decodificador guloso do slimt**, não os modelos (que traduzem certo) nem a arquitetura (en→de idêntico funciona). Duas saídas, em ordem de custo:

1. **Corrigir a decodificação do slimt** (temos o source do build): adicionar penalidade de repetição / normalização de comprimento / EOS mínimo antes de repetir. Menor esforço, alta chance — o modelo já produz a tradução certa antes de entrar em loop.
2. **bergamot-translator via NDK** (o fallback do §10.2): usa beam search + normalização de comprimento do Marian, que tratam o EOS corretamente. Carrega **estes mesmos modelos**, então quase certamente resolve — mas é o item caro (time-box de 5 dias).

**Decisão pendente do usuário** antes de investir em (1) ou (2). Registrado em `docs/decisoes.md`.
