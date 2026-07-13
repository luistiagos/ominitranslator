# Suíte fixa do AT-1 (§10.2)

Frases-fonte para o gate de tradução Android, versionadas para reprodutibilidade.

- `en.txt` — 100 frases em inglês (entrada de **en→pt**)
- `pt.txt` — 100 frases em português (entrada de **pt→en**)
- `out_enpt.txt` / `out_pten.txt` — saída CRUA do `slimt-cli` no moto g86
  (2026-07-13), sem o cabeçalho de config.
- `out_pten_dedup.txt` — a mesma saída após o `dedupRepeatedTail` de produção
  (gerada por `tool/at1_recount.dart`): é o que o backend entrega ao pipeline.

Reproduzir (modelos tiny v1.0 do Firefox Remote Settings, sem `--shortlist`):

    slimt-cli --root enpt --model model.enpt.intgemm.alphas.bin \
      --vocabulary vocab.enpt.spm < en.txt
    dart run tool/at1_recount.dart   # aplica o dedup e reconta

Veredito final: **PASSOU** — slimt + `dedupRepeatedTail` no backend
(pt→en cru reprovava por eco degenerado da decodificação gulosa; o dedup
elimina 17→0 degeneradas sem tocar em frase limpa). Ver `../AT1.md` §6–§9.
