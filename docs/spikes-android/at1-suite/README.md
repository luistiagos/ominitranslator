# Suíte fixa do AT-1 (§10.2)

Frases-fonte para o gate de tradução Android, versionadas para reprodutibilidade.

- `en.txt` — 100 frases em inglês (entrada de **en→pt**)
- `pt.txt` — 100 frases em português (entrada de **pt→en**)
- `out_enpt.txt` / `out_pten.txt` — saída do `slimt-cli` no moto g86 (2026-07-13),
  já sem o cabeçalho de config. Evidência do resultado documentado em `../AT1.md`.

Reproduzir (modelos tiny v1.0 do Firefox Remote Settings, sem `--shortlist`):

    slimt-cli --root enpt --model model.enpt.intgemm.alphas.bin \
      --vocabulary vocab.enpt.spm < en.txt

Veredito: en→pt passa; pt→en reprova por repetição degenerada (decodificação
gulosa do slimt). Ver `../AT1.md` §6–§7.
