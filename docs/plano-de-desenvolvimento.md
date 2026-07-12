# OmniTranslator — Plano de Avaliação e Desenvolvimento

> **Especificações técnicas detalhadas**: [especificacao-tecnica.md](especificacao-tecnica.md) para Windows/Fases 0–2 e [especificacao-android.md](especificacao-android.md) para o port Android. A spec desktop refina a stack do MVP para subprocessos CLI, Piper e separação via executável sherpa. A spec Android define runtimes in-process, redução de memória, checkpoints, serviço foreground e gates de release. Em caso de divergência sobre uma plataforma, sua spec prevalece.

## Contexto

Avaliar e planejar (sem codificar ainda) um app de **tradução e dublagem de vídeos**, incluindo modo **tempo real (streaming)**, com modelos **leves, gratuitos e 100% locais** — rodando até em celulares. Idiomas obrigatórios: **inglês, português e espanhol** (extensível a outros).

Decisões do usuário:
- **Plataforma**: Desktop Windows primeiro, mobile (Android → iOS) depois.
- **MVP**: dublagem de **arquivo de vídeo** (qualidade máxima); tempo real vem em seguida.
- **Fontes no modo tempo real** (todas): player embutido no app, captura de áudio de outros apps (Android), microfone/ambiente.
- **Vozes**: neurais fixas de qualidade (sem clonagem no MVP — clonagem leve on-device ainda não é viável com qualidade).

## Veredito de viabilidade: ✅ VIÁVEL

Todos os blocos existem como projetos open-source maduros, gratuitos e que rodam on-device (inclusive Android/iOS). O precedente direto é o **RTranslator** (Whisper-small + NLLB-600M int8 rodando em celular, ~1,2GB de modelos). O que **não** é viável hoje com modelos leves locais: clonagem do timbre original e lip-sync — "dublagem perfeita" aqui significa timing preciso, trilha de fundo preservada e vozes neurais naturais.

## Stack tecnológica recomendada

| Bloco | Solução | Idiomas | Observações |
|---|---|---|---|
| Runtime de fala (guarda-chuva) | **Sherpa-ONNX** (Apache-2.0) | — | Um único runtime cobre ASR, TTS, VAD e separação de fontes; roda em Windows/Linux/macOS/Android/iOS; bindings oficiais para Dart/Flutter, C++, Kotlin, Swift etc. |
| ASR offline (arquivos) | **Whisper** (small/base int8 via sherpa-onnx ou whisper.cpp) | en/pt/es +90 | Timestamps por palavra, melhor precisão; small no desktop, tiny/base no mobile |
| ASR streaming (tempo real) | **Kroko ASR** (Zipformer2, CC-BY-SA) | en/pt/es/fr/de/it/nl | Streaming de baixa latência, mais leve que Whisper; via sherpa-onnx |
| Tradução (MT) | **Bergamot/Marian** — modelos Firefox Translations (~20–40MB/direção) | en↔pt, en↔es (pt↔es via pivô en) | CPU int8, muito rápido; alternativa de maior qualidade: NLLB-600M int8 (⚠ CC-BY-NC, restringe uso comercial) |
| TTS | **Kokoro 82M** ONNX (Apache-2.0) | en, es, **pt-BR** + 6 | Qualidade próxima de dublagem profissional; fallback leve: **Piper/VITS** (~20–60MB/voz, tem pt-BR/es/en) |
| VAD | **Silero VAD** (~2MB) | — | Via sherpa-onnx |
| Separação voz/fundo | **Spleeter** ONNX (rápido em 1 thread de CPU) via sherpa-onnx | — | Preserva música/efeitos na dublagem; UVR é opção de mais qualidade (10× mais lento, só desktop) |
| Mux/demux de vídeo | **FFmpeg** | — | Desktop usa binário LGPL como subprocesso. Android usa **FFmpegKitNext** oficial, compilado do código-fonte em variante LGPL; Media3 não substitui os filtros de áudio exigidos pelo pipeline. |
| Framework de app | **Flutter** | — | Um código para Windows + Android + iOS; pacote `sherpa_onnx` oficial no pub.dev; player via `media_kit` (libmpv) |

**Orçamento de modelos (desktop, en+pt+es)**: ~1,0–1,5GB. **Mobile** (tiny/base + Piper): ~300–600MB. Baixados sob demanda por idioma (gerenciador de modelos), nunca embutidos no instalador.

## Arquitetura

```
┌────────────────────── Flutter UI (Windows → Android → iOS) ──────────────────────┐
│  Tela de dublagem de arquivo │ Player embutido c/ dublagem ao vivo │ Config/Modelos │
└──────────────────────────────────┬───────────────────────────────────────────────┘
                    ┌──────────────▼──────────────┐
                    │  dubbing_engine (Dart puro)  │  ← pipeline, orquestração, timing
                    │  - pipeline offline (arquivo)│
                    │  - pipeline streaming        │
                    │  - gerenciador de modelos    │
                    └──┬──────────┬──────────┬────┘
              sherpa_onnx (FFI)   │      FFmpeg (processo no desktop /
         ASR·TTS·VAD·separação    │       lib no mobile)
                                  │
                        bergamot_ffi (FFI, a criar)
                        tradução Marian int8
```

Princípio: **todo o pipeline vive num pacote Dart compartilhado** com runtimes plugáveis. Antes do Android, o engine precisa remover imports de backends concretos e buffers proporcionais ao vídeo; o port troca backends e casca de plataforma sem duplicar as regras de dublagem.

### Pipeline de dublagem de arquivo (MVP)

1. **Demux** (FFmpeg): extrai áudio 16kHz mono (para ASR) + estéreo original (para mixagem).
2. **Separação** (Spleeter): voz × trilha de fundo (música/efeitos).
3. **VAD + ASR** (Silero + Whisper sobre a faixa de voz): segmentos com timestamps por palavra.
4. **Segmentação em frases** + pontuação.
5. **Tradução** (Bergamot; pivô en para pt↔es).
6. **TTS** (Kokoro) por segmento.
7. **Ajuste de duração**: time-stretch (WSOLA/rubberband, ±20%) para encaixar a fala dublada na janela do segmento original — o coração da "dublagem perfeita".
8. **Mixagem**: trilha de fundo + voz dublada, ducking de resíduos, normalização de loudness.
9. **Mux** (FFmpeg): vídeo final com faixa dublada (+ faixa original secundária e legendas SRT nos dois idiomas como bônus).

### Pipeline tempo real (fase 2)

Captura → buffer circular → Kroko ASR streaming → tradução incremental (a cada frase fechada) → Kokoro/Piper TTS → reprodução com **atraso alvo de 2–4s**. No player embutido, o truque-chave: **atrasar o próprio vídeo** em N segundos para a dublagem sair perfeitamente sincronizada. Fontes:
- **Player embutido** (URL/HLS/arquivo) — via `media_kit`, acesso direto ao PCM decodificado. Desktop e mobile.
- **Áudio de outros apps** — Android 10+ `AudioPlaybackCapture` (não funciona com apps DRM tipo Netflix; sem equivalente iOS).
- **Microfone** — TV/palestras; uso com fone; pipeline igual, com denoise (speech enhancement do sherpa-onnx) antes do ASR.

## Roadmap

### Fase 0 — Spikes de validação (1–2 semanas)
Provas de conceito descartáveis, cada uma com critério de aceite mensurável:
- **S1**: `sherpa_onnx` Dart no Windows: Whisper small int8 transcreve 5min de vídeo pt/es/en com timestamps (aceite: WER perceptualmente ok, < 0,5× tempo real no desktop).
- **S2**: **Bergamot via FFI** — o maior risco de integração (não há binding Dart pronto; criar wrapper C fino sobre a lib C++). Aceite: traduzir 100 frases en→pt e pt→es com qualidade aceitável.
- **S3**: Kokoro pt-BR/es/en via sherpa-onnx: qualidade e velocidade (aceite: < 0,3× tempo real).
- **S4**: Spleeter via sherpa-onnx: separar voz/fundo de um trecho real de filme.
- **S5**: time-stretch de fala (rubberband/sonic via FFI ou filtro `atempo` do FFmpeg) sem artefatos até ±20%.

### Fase 1 — MVP desktop: dublagem de arquivo (3–5 semanas)
- Pacote `dubbing_engine` com o pipeline offline completo (passos 1–9 acima).
- App Flutter Windows: importar vídeo → escolher idioma destino → barra de progresso por etapa → salvar vídeo dublado + SRT.
- Gerenciador de download de modelos por idioma (com verificação de hash e retomada).
- Presets de qualidade: "Rápido" (base/Piper) × "Melhor" (small/Kokoro).

### Fase 2 — Tempo real no desktop (2–4 semanas)
- Pipeline streaming (Kroko + tradução incremental + TTS) no player embutido com vídeo atrasado.
- Métrica de latência exposta na UI; ajuste do atraso pelo usuário.

### Fase 3 — Android M1 (incremental, orientada por gates)
- Um único repositório e app Flutter: gerar `app/android/` no app existente; o protótipo irmão é apenas fonte dos spikes.
- **Primeiro de tudo, o gate AT-0**: páginas de 16 KB em todas as `.so`. Custa horas e, se reprovar, muda o orçamento do marco inteiro — não pode ser descoberto no fim.
- Depois refatorar o engine no Windows: `DubbingRuntime`, mídia em disco, writer WAV sequencial, checkpoints, retomada — mais a correção da cauda da última fala e do split do segmentador, que hoje degradam a sincronia **no desktop também**.
- Validar separadamente tradução portuguesa, Whisper ONNX + Silero VAD, TTS Piper, FFmpegKitNext, foreground service e Storage Access Framework no aparelho real.
- Entregar arquivo local en/pt/es, voz Piper fixa, voice-over com ducking e SRT. Separação, múltiplos locutores, YouTube e tempo real ficam para marcos posteriores.
- Executar job em foreground service direto do tipo `mediaProcessing`; não usar WorkManager para o pipeline longo.
- Detalhamento normativo: [especificacao-android.md](especificacao-android.md).

### Fase 4 — Paridade Android e além (contínuo)
- Android M2: separação Spleeter, diarização e múltiplas vozes.
- Android M3: YouTube após spike próprio.
- Android M4–M5: player/tempo real, `AudioPlaybackCapture` e microfone.
- iOS depois da estabilização do runtime móvel, sem captura de outros apps.

## Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Tradução Android en↔pt | Gate AT-1: o slimt só suporta a arquitetura `tiny`, então os pares `enpt`/`pten` **tiny** (Mozilla, MPL-2.0, repo arquivado) são o caminho — não os `base-memory` do desktop. Se o tiny reprovar em qualidade, bergamot-translator via NDK com time-box de 5 dias. Português bloqueia release. |
| ~~`.so` do sherpa/ONNX Runtime sem alinhamento de 16 KB~~ | **RESOLVIDO (AT-0, 2026-07-12):** as 3 `.so` arm64 do sherpa 1.13.4 já têm todos os `LOAD` em `align 0x4000`, e o ORT é 1.27.0. Não é preciso compilar sherpa+ORT do fonte. Restam confirmações de runtime na D3. |
| Sincronia no Android: o sherpa não devolve timestamps para Whisper (o desktop usa `whisper-cli -ml 1 -sow`, um segmento por palavra) | Silero VAD como segmentador; `sync_report.json` gerado pelo pipeline mede `%` em ±300 ms, com baseline colhido no Windows antes de existir Android. |
| Qualidade do Kokoro em pt-BR abaixo do esperado | Fallback Piper; avaliar no spike S3 antes de comprometer |
| Kroko CC-BY-SA: modelos comunitários gratuitos, tiers pagos existem | Confirmar cobertura pt/es nos modelos gratuitos durante S1; plano B: Whisper tiny em janelas deslizantes |
| Memória cresce com a duração do vídeo | Áudio por segmento em disco, leitura WAV por janela e construção sequencial da faixa dublada antes do port. |
| Desempenho em celulares medianos | Whisper tiny/base, limites explícitos de janela e testes no moto g86 mais API 28/16 KB. |
| Licenças (NLLB é CC-BY-NC; FFmpeg LGPL) | Evitar NLLB; fixar FFmpegKitNext compilado sem `--enable-gpl` e inventariar todas as `.so`. |
| Tradução pt↔es via pivô inglês perde nuance | Aceitável no MVP; avaliar modelo direto es↔pt depois |

## Verificação (fim de cada fase)

- **Fase 0**: cada spike tem critério de aceite acima; guardar amostras de áudio/vídeo geradas em `docs/spikes/`.
- **Fase 1**: dublar 3 vídeos reais (~5min) nas 6 direções entre en/pt/es; conferir a olho/ouvido: sincronia labial aproximada (início/fim de falas), trilha de fundo preservada, loudness consistente; medir tempo total de processamento (< 2× duração do vídeo no desktop).
- **Fase 2**: latência fim-a-fim medida < 4s; assistir 10min de stream sem dessincronizar.
- **Fase 3**: seis direções en/pt/es; ≤4× a duração no moto g86; RAM pico <1,8GB; ≥90% dos segmentos em ±300ms; job de 30min em background; API 28/35/36, AAB/APK arm64 e ambiente de páginas 16 KB.
