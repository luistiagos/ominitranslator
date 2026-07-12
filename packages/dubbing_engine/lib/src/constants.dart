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
// O mix final amarra a saída à duração do áudio original (`amix duration=first`),
// então o fim do vídeo é um prazo do qual não há como escapar: o que passar dele
// é cortado pelo ffmpeg. Um run que ameace ultrapassá-lo pode acelerar até este
// teto — acima do maxTotalSpeed normal — porque uma fala um pouco atropelada é
// melhor que uma fala cortada no meio. É o máximo que os clamps existentes
// alcançam (vitsSpeedMax × atempoMax = 1.6875).
const tailSpeedMax = 1.65;
// Cauda que sobra depois disso é cortada. Até este teto o corte é aceitável
// (some no decaimento da última sílaba); acima dele é falha de qualidade.
const tailTruncationCap = Duration(milliseconds: 200);
const ttsSampleRate = 22050;
const mixSampleRate = 44100;
const asrSampleRate = 16000;
const aacBitrate = '192k';
// Bitrate do re-encode de vídeo no fallback do mux (containers cujo codec o MP4
// não aceita, ex.: VP9 de um WebM). Só é usado quando `-c:v copy` falha.
const reencodeVideoBitrate = '5M';
const toolTimeout = Duration(minutes: 30);
// sherpa-onnx processa o WAV inteiro em memória: pico medido de ~300 MB
// base + ~11 MB por segundo de áudio (120s ≈ 1,7 GB; 300s ≈ 3,6 GB, que já
// estoura). 30s (~680 MB) cabe em máquinas com pouca RAM; se ainda assim
// faltar memória, o separador tenta de novo com chunks pela metade até o piso.
const separationChunkSeconds = 30;
const minSeparationChunkSeconds = 10;
const whisperModelId = {Preset.fast: 'whisper-base-q5_1', Preset.best: 'whisper-small-q5_1'};
const piperModelId = {
  Lang.en: 'piper-en',
  Lang.pt: 'piper-pt-br',
  Lang.es: 'piper-es',
  Lang.de: 'piper-de-thorsten',
  Lang.fr: 'piper-fr-siwis',
  Lang.pl: 'piper-pl-gosia',
  Lang.cs: 'piper-cs-jirka',
};

/// Frase curta usada para tocar uma amostra da voz escolhida, por idioma
/// alvo. Idiomas alvo sem entrada aqui caem no fallback (inglês).
const voiceSampleSentence = <Lang, String>{
  Lang.pt: 'Esta é uma amostra da voz de dublagem.',
  Lang.en: 'This is a sample of the dubbing voice.',
  Lang.es: 'Esta es una muestra de la voz de doblaje.',
  Lang.de: 'Dies ist eine Probe der Synchronstimme.',
  Lang.fr: 'Ceci est un échantillon de la voix de doublage.',
  Lang.pl: 'To jest próbka głosu dubbingowego.',
  Lang.cs: 'Toto je ukázka dabingového hlasu.',
};
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
    'piper-pt-pt-tugao',
  ],
  Lang.en: [
    'piper-en',
    'piper-en-hfc-female',
    'piper-en-hfc-male',
    'piper-en-amy',
    'piper-en-ryan',
    'piper-en-kristin',
    'piper-en-joe',
    'piper-en-bryce',
    'piper-en-danny',
    'piper-en-john',
    'piper-en-kathleen',
    'piper-en-kusal',
    'piper-en-ljspeech',
    'piper-en-norman',
    'piper-en-reza-ibrahim',
    'piper-en-sam',
    'piper-en-gb-alan',
    'piper-en-gb-alba',
    'piper-en-gb-cori',
    'piper-en-gb-jenny-dioco',
    'piper-en-gb-northern-male',
    'piper-en-gb-southern-female',
    'piper-en-libritts',
    'piper-en-arctic',
    'piper-en-l2arctic',
    'piper-en-libritts-high',
    'piper-en-gb-aru',
    'piper-en-gb-semaine',
    'piper-en-gb-vctk',
  ],
  Lang.es: [
    'piper-es',
    'piper-es-davefx',
    'piper-es-daniela',
    'piper-es-claude',
    'piper-es-ald',
    'piper-es-carlfm',
  ],
  Lang.de: [
    'piper-de-thorsten',
    'piper-de-karlsson',
    'piper-de-pavoque',
    'piper-de-eva-k',
    'piper-de-kerstin',
    'piper-de-ramona',
    'piper-de-thorsten-emotional',
  ],
  Lang.fr: [
    'piper-fr-siwis',
    'piper-fr-gilles',
    'piper-fr-tom',
    'piper-fr-upmc',
  ],
  Lang.pl: [
    'piper-pl-gosia',
    'piper-pl-bass',
    'piper-pl-darkman',
    'piper-pl-mc-speech',
  ],
  Lang.cs: [
    'piper-cs-jirka',
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
    ('piper-pt-pt-tugao', 0, 'Tugão — masculina (PT)'),
  ],
  Lang.en: [
    ('piper-en', 0, 'Lessac'),
    ('piper-en-hfc-female', 0, 'HFC — feminina'),
    ('piper-en-hfc-male', 0, 'HFC — masculina'),
    ('piper-en-amy', 0, 'Amy — feminina'),
    ('piper-en-ryan', 0, 'Ryan — masculina'),
    ('piper-en-kristin', 0, 'Kristin — feminina'),
    ('piper-en-joe', 0, 'Joe — masculina'),
    ('piper-en-bryce', 0, 'Bryce — masculina'),
    ('piper-en-danny', 0, 'Danny — masculina'),
    ('piper-en-john', 0, 'John — masculina'),
    ('piper-en-kathleen', 0, 'Kathleen — feminina'),
    ('piper-en-kusal', 0, 'Kusal — masculina'),
    ('piper-en-ljspeech', 0, 'LJSpeech — feminina'),
    ('piper-en-norman', 0, 'Norman — masculina'),
    ('piper-en-reza-ibrahim', 0, 'Reza Ibrahim — masculina'),
    ('piper-en-sam', 0, 'Sam'),
    ('piper-en-gb-alan', 0, 'Alan (GB) — masculina'),
    ('piper-en-gb-alba', 0, 'Alba (GB) — feminina'),
    ('piper-en-gb-cori', 0, 'Cori (GB) — feminina'),
    ('piper-en-gb-jenny-dioco', 0, 'Jenny (GB) — feminina'),
    ('piper-en-gb-northern-male', 0, 'Sotaque norte (GB) — masculina'),
    ('piper-en-gb-southern-female', 0, 'Sotaque sul (GB) — feminina'),
    ('piper-en-libritts', 0, 'LibriTTS 1'),
    ('piper-en-libritts', 1, 'LibriTTS 2'),
    ('piper-en-libritts', 2, 'LibriTTS 3'),
    ('piper-en-libritts', 3, 'LibriTTS 4'),
    ('piper-en-libritts', 4, 'LibriTTS 5'),
    ('piper-en-libritts', 5, 'LibriTTS 6'),
    ('piper-en-libritts', 6, 'LibriTTS 7'),
    ('piper-en-libritts', 7, 'LibriTTS 8'),
    ('piper-en-arctic', 0, 'Arctic 1'),
    ('piper-en-arctic', 1, 'Arctic 2'),
    ('piper-en-arctic', 2, 'Arctic 3'),
    ('piper-en-arctic', 3, 'Arctic 4'),
    ('piper-en-l2arctic', 0, 'L2-Arctic 1 (sotaque)'),
    ('piper-en-l2arctic', 1, 'L2-Arctic 2 (sotaque)'),
    ('piper-en-l2arctic', 2, 'L2-Arctic 3 (sotaque)'),
    ('piper-en-l2arctic', 3, 'L2-Arctic 4 (sotaque)'),
    ('piper-en-libritts-high', 0, 'LibriTTS HQ 1'),
    ('piper-en-libritts-high', 1, 'LibriTTS HQ 2'),
    ('piper-en-libritts-high', 2, 'LibriTTS HQ 3'),
    ('piper-en-libritts-high', 3, 'LibriTTS HQ 4'),
    ('piper-en-gb-aru', 0, 'Aru (GB) 1'),
    ('piper-en-gb-aru', 1, 'Aru (GB) 2'),
    ('piper-en-gb-aru', 2, 'Aru (GB) 3'),
    ('piper-en-gb-aru', 3, 'Aru (GB) 4'),
    ('piper-en-gb-semaine', 0, 'Semaine (GB) 1'),
    ('piper-en-gb-semaine', 1, 'Semaine (GB) 2'),
    ('piper-en-gb-semaine', 2, 'Semaine (GB) 3'),
    ('piper-en-gb-semaine', 3, 'Semaine (GB) 4'),
    ('piper-en-gb-vctk', 0, 'VCTK (GB) 1'),
    ('piper-en-gb-vctk', 1, 'VCTK (GB) 2'),
    ('piper-en-gb-vctk', 2, 'VCTK (GB) 3'),
    ('piper-en-gb-vctk', 3, 'VCTK (GB) 4'),
  ],
  Lang.es: [
    ('piper-es', 0, 'Sharvard A'),
    ('piper-es', 1, 'Sharvard B'),
    ('piper-es-davefx', 0, 'DaveFX — masculina'),
    ('piper-es-daniela', 0, 'Daniela — feminina (AR)'),
    ('piper-es-claude', 0, 'Claude (MX)'),
    ('piper-es-ald', 0, 'Ald (MX)'),
    ('piper-es-carlfm', 0, 'CarlFM — masculina'),
  ],
  Lang.de: [
    ('piper-de-thorsten', 0, 'Thorsten — masculina'),
    ('piper-de-karlsson', 0, 'Karlsson — masculina'),
    ('piper-de-pavoque', 0, 'Pavoque — masculina'),
    ('piper-de-eva-k', 0, 'Eva K — feminina'),
    ('piper-de-kerstin', 0, 'Kerstin — feminina'),
    ('piper-de-ramona', 0, 'Ramona — feminina'),
    ('piper-de-thorsten-emotional', 0, 'Thorsten emocional 1'),
    ('piper-de-thorsten-emotional', 1, 'Thorsten emocional 2'),
    ('piper-de-thorsten-emotional', 2, 'Thorsten emocional 3'),
    ('piper-de-thorsten-emotional', 3, 'Thorsten emocional 4'),
  ],
  Lang.fr: [
    ('piper-fr-siwis', 0, 'Siwis — feminina'),
    ('piper-fr-gilles', 0, 'Gilles — masculina'),
    ('piper-fr-tom', 0, 'Tom — masculina'),
    // UPMC tem 2 falantes (Jessica/Pierre); confirmar por audição a ordem
    // real dos sids antes de refinar os rótulos.
    ('piper-fr-upmc', 0, 'UPMC — feminina (Jessica)'),
    ('piper-fr-upmc', 1, 'UPMC — masculina (Pierre)'),
  ],
  Lang.pl: [
    ('piper-pl-gosia', 0, 'Gosia — feminina'),
    ('piper-pl-bass', 0, 'Bass — masculina'),
    ('piper-pl-darkman', 0, 'Darkman — masculina'),
    ('piper-pl-mc-speech', 0, 'MC Speech'),
  ],
  Lang.cs: [
    ('piper-cs-jirka', 0, 'Jirka — masculina'),
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
  'piper-es-carlfm': [VoiceGender.male],
  'piper-pt-pt-tugao': [VoiceGender.male],
  'piper-en-bryce': [VoiceGender.male],
  'piper-en-danny': [VoiceGender.male],
  'piper-en-john': [VoiceGender.male],
  'piper-en-kathleen': [VoiceGender.female],
  'piper-en-kusal': [VoiceGender.male],
  'piper-en-ljspeech': [VoiceGender.female],
  'piper-en-norman': [VoiceGender.male],
  'piper-en-reza-ibrahim': [VoiceGender.male],
  'piper-en-sam': [VoiceGender.unknown],
  'piper-en-gb-alan': [VoiceGender.male],
  'piper-en-gb-alba': [VoiceGender.female],
  'piper-en-gb-cori': [VoiceGender.female],
  'piper-en-gb-jenny-dioco': [VoiceGender.female],
  'piper-en-gb-northern-male': [VoiceGender.male],
  'piper-en-gb-southern-female': [VoiceGender.female],
  'piper-de-thorsten': [VoiceGender.male],
  'piper-de-karlsson': [VoiceGender.male],
  'piper-de-pavoque': [VoiceGender.male],
  'piper-de-eva-k': [VoiceGender.female],
  'piper-de-kerstin': [VoiceGender.female],
  'piper-de-ramona': [VoiceGender.female],
  // Thorsten emocional: mesmo falante (masculino) do piper-de-thorsten,
  // em estilos de entonação diferentes.
  'piper-de-thorsten-emotional': [
    VoiceGender.male, VoiceGender.male, VoiceGender.male, VoiceGender.male,
  ],
  'piper-fr-siwis': [VoiceGender.female],
  'piper-fr-gilles': [VoiceGender.male],
  'piper-fr-tom': [VoiceGender.male],
  // Confirmar por audição a ordem real dos sids (ver comentário em pickableVoices).
  'piper-fr-upmc': [VoiceGender.female, VoiceGender.male],
  'piper-pl-gosia': [VoiceGender.female],
  'piper-pl-bass': [VoiceGender.male],
  'piper-pl-darkman': [VoiceGender.male],
  'piper-pl-mc-speech': [VoiceGender.unknown],
  'piper-cs-jirka': [VoiceGender.male],
};
