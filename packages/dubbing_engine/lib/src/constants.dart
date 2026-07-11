import 'package:dubbing_engine/src/models.dart';

const mergeMaxPause = Duration(milliseconds: 600);
const mergeMaxChars = 220;
const mergeMaxDur = Duration(seconds: 12);
const minTarget = Duration(milliseconds: 400);
const vitsSpeedMax = 1.35;
const atempoMax = 1.25;
// Teto TOTAL de aceleração de uma fala (VITS × atempo). Acima de ~1.5× a
// fala fica ininteligível — melhor aceitar atraso do que passar disso.
const maxTotalSpeed = 1.5;
// Piso de DESACELERAÇÃO: traduções mais curtas que a fala original são
// esticadas até 15% para preencher a janela (evita a dublagem terminar
// cedo e deixar silêncio enquanto o personagem ainda fala).
const minTotalSpeed = 0.85;
// Silêncios do original com pelo menos esta duração são pausas reais
// (respiração, corte de cena) e devem permanecer em silêncio na dublagem.
const pausePreserveSeconds = 1.0;
// Quanto a dublagem pode invadir uma pausa real, no máximo.
const pauseSpillSeconds = 0.8;
// Lacunas originais menores que isto dentro de fala contínua não geram
// silêncio na dublagem: o segmento seguinte cola no fim do anterior
// (interrupções artificiais de 0.2-0.6s soam como defeito).
const seamlessGapSeconds = 0.25;
// Agendamento das falas dubladas: cada fala entra no seu tempo original ou
// depois (nunca sobrepondo a anterior). O atraso acumulado ("drift") pode
// chegar a este teto antes de acelerarmos a fala — traduções mais longas
// preferem atrasar um pouco a soar atropeladas.
const maxDubDriftSeconds = 1.5;
// Acelerações menores que isso não valem uma nova síntese (imperceptíveis).
const minResynthSpeed = 1.05;
const ttsSampleRate = 22050;
const mixSampleRate = 44100;
const asrSampleRate = 16000;
const aacBitrate = '192k';
const toolTimeout = Duration(minutes: 30);
// sherpa-onnx processa o WAV inteiro em memória: pico medido de ~300 MB
// base + ~11 MB por segundo de áudio (120s ≈ 1,7 GB; 300s ≈ 3,6 GB, que já
// estoura). 30s (~680 MB) cabe em máquinas com pouca RAM; se ainda assim
// faltar memória, o separador tenta de novo com chunks pela metade até o piso.
const separationChunkSeconds = 30;
const minSeparationChunkSeconds = 10;
const whisperModelId = {Preset.fast: 'whisper-base-q5_1', Preset.best: 'whisper-small-q5_1'};
const piperModelId = {Lang.en: 'piper-en', Lang.pt: 'piper-pt-br', Lang.es: 'piper-es'};
const spleeterModelId = 'spleeter-2stems-fp16';

// Diarização de falantes (multi-vozes). Quando os dois modelos estão
// instalados, cada falante detectado recebe uma voz diferente; sem eles,
// a dublagem usa uma voz única.
const diarizationSegmentationModelId = 'diarization-segmentation';
const diarizationEmbeddingModelId = 'diarization-embedding';
// Threshold do clustering automático: maior = funde mais (menos falantes).
// 0.5 fragmentava vozes parecidas (dois homens) em clusters fantasma;
// 0.65 prioriza estabilidade — errar fundindo é menos ruim que errar
// criando um falante inexistente.
const diarizationThreshold = 0.65;
// Falantes com pouco tempo de fala (absoluto E relativo) são quase sempre
// clusters fantasma da diarização ("terceira voz"): seus turnos são
// absorvidos pelo falante real mais próximo no tempo.
const minSpeakerAirtimeSeconds = 3.0;
const minSpeakerAirtimeFraction = 0.08;
// Sobreposição mínima (fração da duração do segmento transcrito) para
// aceitar o falante indicado pela diarização; abaixo disso o segmento
// herda o falante do segmento anterior (continuidade da conversa).
const minSegmentOverlapRatio = 0.3;
// Um segmento curto com falante diferente dos dois vizinhos (que são
// iguais entre si) é quase sempre erro de fronteira da diarização.
const maxSpeakerFlapSegment = Duration(seconds: 2);
// Modelos multi-falante (ex.: libritts_r tem ~900 vozes) contribuem no
// máximo este número de vozes, para manter o elenco consistente.
const maxVoicesPerModel = 4;
// Modelos de voz por idioma, em ordem de prioridade. O primeiro é o modelo
// obrigatório (mesmo comportamento de voz única de antes); os demais são
// opcionais e só entram no elenco multi-vozes se estiverem instalados.
const piperVoiceBank = {
  Lang.pt: [
    'piper-pt-br',
    'piper-pt-br-dii',
    'piper-pt-br-edresson',
    'piper-pt-br-cadu',
    'piper-pt-br-jeff',
    'piper-pt-br-miro',
  ],
  Lang.en: [
    'piper-en',
    'piper-en-hfc-female',
    'piper-en-hfc-male',
    'piper-en-amy',
    'piper-en-ryan',
    'piper-en-kristin',
    'piper-en-joe',
    'piper-en-libritts',
  ],
  Lang.es: [
    'piper-es',
    'piper-es-davefx',
    'piper-es-daniela',
    'piper-es-claude',
    'piper-es-ald',
  ],
};

// Detecção de sexo do falante pelo pitch (F0 mediano). Entre os dois
// limiares o resultado é "indeterminado" (recebe qualquer voz livre).
const genderMaleMaxHz = 155.0;
const genderFemaleMinHz = 175.0;

// Classificador de sexo/idade por audio tagging (AudioSet: "Male speech" /
// "Female speech" / "Child speech"). É o método PRIMÁRIO quando instalado:
// o pitch falha em fala enfática (homens de YouTube falam a 190-240 Hz) e
// com música de fundo. O pitch fica como fallback.
const genderTaggingModelId = 'gender-tagging';
// Pontuação mínima somada da classe vencedora para aceitar a classificação
// do tagging; abaixo disso cai para o pitch.
const genderTaggingMinScore = 0.05;
// Quantos turnos (os mais longos) e quantos segundos de cada um alimentam
// o tagging por falante.
const genderTaggingMaxTurns = 3;
const genderTaggingMaxSecondsPerTurn = 10.0;

// F0 mediano acima disso → criança (vozes infantis ficam bem acima da
// faixa feminina adulta). Mulheres muito agudas podem cair aqui — ajuste
// o limiar se acontecer com frequência.
const ageChildMinHz = 250.0;
// Falas de criança são dubladas com voz feminina + pitch-shift por este
// fator (1.15 ≈ +2,4 semitons). Maior = mais infantil, porém mais
// artificial ("desenho animado").
const childVoicePitchFactor = 1.15;

/// Vozes que o usuário pode escolher manualmente, por idioma. Cada item é
/// (modelId, sid, rótulo). Só aparecem na UI as de modelos instalados.
const pickableVoices = <Lang, List<(String, int, String)>>{
  Lang.pt: [
    ('piper-pt-br', 0, 'Faber — masculina'),
    ('piper-pt-br-dii', 0, 'Dii — feminina'),
    ('piper-pt-br-edresson', 0, 'Edresson — masculina'),
    ('piper-pt-br-cadu', 0, 'Cadu — masculina'),
    ('piper-pt-br-jeff', 0, 'Jeff — masculina'),
    ('piper-pt-br-miro', 0, 'Miro'),
  ],
  Lang.en: [
    ('piper-en', 0, 'Lessac'),
    ('piper-en-hfc-female', 0, 'HFC — feminina'),
    ('piper-en-hfc-male', 0, 'HFC — masculina'),
    ('piper-en-amy', 0, 'Amy — feminina'),
    ('piper-en-ryan', 0, 'Ryan — masculina'),
    ('piper-en-kristin', 0, 'Kristin — feminina'),
    ('piper-en-joe', 0, 'Joe — masculina'),
    ('piper-en-libritts', 0, 'LibriTTS 1'),
    ('piper-en-libritts', 1, 'LibriTTS 2'),
    ('piper-en-libritts', 2, 'LibriTTS 3'),
    ('piper-en-libritts', 3, 'LibriTTS 4'),
    ('piper-en-libritts', 4, 'LibriTTS 5'),
    ('piper-en-libritts', 5, 'LibriTTS 6'),
    ('piper-en-libritts', 6, 'LibriTTS 7'),
    ('piper-en-libritts', 7, 'LibriTTS 8'),
  ],
  Lang.es: [
    ('piper-es', 0, 'Sharvard A'),
    ('piper-es', 1, 'Sharvard B'),
    ('piper-es-davefx', 0, 'DaveFX — masculina'),
    ('piper-es-daniela', 0, 'Daniela — feminina (AR)'),
    ('piper-es-claude', 0, 'Claude (MX)'),
    ('piper-es-ald', 0, 'Ald (MX)'),
  ],
};

/// Sexo de cada voz TTS, por sid (índice da lista = sid). Modelos fora do
/// mapa ou sids além da lista contam como `unknown`. Curadoria manual —
/// se alguma voz soar com o sexo trocado, basta corrigir aqui.
const voiceSidGenders = <String, List<VoiceGender>>{
  'piper-pt-br': [VoiceGender.male], // faber
  'piper-pt-br-edresson': [VoiceGender.male],
  'piper-pt-br-dii': [VoiceGender.female],
  'piper-pt-br-cadu': [VoiceGender.male],
  'piper-pt-br-jeff': [VoiceGender.male],
  'piper-pt-br-miro': [VoiceGender.unknown],
  'piper-en': [VoiceGender.unknown], // lessac — gênero ambíguo
  'piper-en-hfc-female': [VoiceGender.female],
  'piper-en-hfc-male': [VoiceGender.male],
  'piper-en-amy': [VoiceGender.female],
  'piper-en-ryan': [VoiceGender.male],
  'piper-en-kristin': [VoiceGender.female],
  'piper-en-joe': [VoiceGender.male],
  // sharvard tem 2 falantes (F+M); confirmar por audição a ordem dos sids.
  'piper-es': [VoiceGender.female, VoiceGender.male],
  'piper-es-davefx': [VoiceGender.male],
  'piper-es-daniela': [VoiceGender.female],
  'piper-es-claude': [VoiceGender.unknown],
  'piper-es-ald': [VoiceGender.unknown],
};
