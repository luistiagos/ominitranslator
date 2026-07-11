# OmniTranslator — Plano de Avaliação e Desenvolvimento

> **Especificação técnica detalhada**: [especificacao-tecnica.md](especificacao-tecnica.md) — documento de implementação (Fases 0–1 em micro-detalhe, Fase 2 em detalhe médio). **Nota**: a spec refina a stack do MVP desktop em relação a este plano: integrações via **subprocessos CLI** em vez de FFI (Bergamot-FFI → **translateLocally CLI**), TTS padrão **Piper** em vez de Kokoro (Kokoro não tem suporte oficial pt/es no sherpa-onnx) e separação de fontes via executável CLI do sherpa-onnx (o binding Dart não a expõe). Em caso de divergência, a spec prevalece.

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
| Mux/demux de vídeo | **FFmpeg** | — | ⚠ FFmpegKit foi aposentado (2025): no desktop, empacotar binário LGPL e invocar como processo; no Android, compilar via NDK ou usar Media3 Transformer |
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

Princípio: **todo o pipeline vive num pacote Dart puro** com backends plugáveis — portar para Android vira uma troca de modelos/binários, não uma reescrita.

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

### Fase 3 — Android (3–5 semanas)
- Port do app (mesmo código Flutter); trocar presets para modelos leves (Whisper tiny/base, Piper, Kroko).
- FFmpeg via NDK ou Media3 Transformer para demux/mux.
- Dublagem de arquivo com processamento em background (WorkManager/foreground service) + modo tempo real no player embutido.

### Fase 4 — Fontes extras e iOS (contínuo)
- `AudioPlaybackCapture` (Android) e modo microfone (com denoise).
- iOS (player embutido e arquivos; sem captura de outros apps).
- Melhorias: voz por gênero do falante, diarização (sherpa-onnx já suporta), mais idiomas (basta adicionar modelos Kroko/Bergamot/Piper).

## Riscos e mitigações

| Risco | Mitigação |
|---|---|
| Bergamot sem binding Dart (maior risco técnico) | Spike S2 primeiro; plano B: NLLB-600M int8 via onnxruntime (aceitar CC-BY-NC) ou OPUS-MT via CTranslate2 |
| Qualidade do Kokoro em pt-BR abaixo do esperado | Fallback Piper; avaliar no spike S3 antes de comprometer |
| Kroko CC-BY-SA: modelos comunitários gratuitos, tiers pagos existem | Confirmar cobertura pt/es nos modelos gratuitos durante S1; plano B: Whisper tiny em janelas deslizantes |
| Desempenho em celulares medianos | Presets por hardware; medir em aparelho de entrada na Fase 3, não só em flagship |
| Licenças (NLLB é CC-BY-NC; FFmpeg LGPL) | Stack recomendada evita NLLB; FFmpeg em build LGPL invocado como processo |
| Tradução pt↔es via pivô inglês perde nuance | Aceitável no MVP; avaliar modelo direto es↔pt depois |

## Verificação (fim de cada fase)

- **Fase 0**: cada spike tem critério de aceite acima; guardar amostras de áudio/vídeo geradas em `docs/spikes/`.
- **Fase 1**: dublar 3 vídeos reais (~5min) nas 6 direções entre en/pt/es; conferir a olho/ouvido: sincronia labial aproximada (início/fim de falas), trilha de fundo preservada, loudness consistente; medir tempo total de processamento (< 2× duração do vídeo no desktop).
- **Fase 2**: latência fim-a-fim medida < 4s; assistir 10min de stream sem dessincronizar.
- **Fase 3**: mesmos testes da Fase 1 em um Android de entrada e um intermediário; consumo de RAM < 2GB.
