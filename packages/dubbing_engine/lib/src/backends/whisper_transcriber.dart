import 'dart:convert';
import 'dart:io';
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/steps/speech_trim.dart';
import 'package:dubbing_engine/src/wav.dart';
import 'package:path/path.dart' as p;

int _threadCount() => (2 > (Platform.numberOfProcessors - 2)) ? 2 : (Platform.numberOfProcessors - 2);

class WhisperTranscriber implements Transcriber {
  final Tools tools;
  final ModelManager models;
  final Preset preset;
  WhisperTranscriber(this.tools, this.models, this.preset);
  @override
  Future<List<TranscriptSegment>> transcribe(
      String wav16kMono, Lang sourceLang, CancellationToken token, {RunToolFn? runToolOverride}) async {
    final exec = runToolOverride ?? runTool;
    final workDir = p.dirname(wav16kMono);
    final whisperId = whisperModelId[preset]!;
    final whisperEntry = ModelManager.manifest.firstWhere((e) => e.id == whisperId);
    final modelFile = models.pathOf(whisperId, whisperEntry.expects.first);
    final r1 = await exec(tools.ffmpeg, [
      '-y', '-i', wav16kMono,
      '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le',
      p.join(workDir, 'asr_in.wav'),
    ], workingDirectory: workDir, token: token);
    if (r1.exitCode != 0) throw PipelineException(PipelineStage.transcribe, 'Erro ao preparar áudio para ASR');
    final r2 = await exec(tools.whisperCli, [
      '-m', modelFile,
      '-f', p.join(workDir, 'asr_in.wav'),
      '-l', sourceLang.whisperCode,
      '-oj', '-of', p.join(workDir, 'transcript'),
      // Um segmento por PALAVRA: os timestamps de segmento do whisper
      // atravessam silêncios (fundem falas separadas por pausas longas);
      // com granularidade de palavra, o segmentador reconstrói as falas
      // com limites reais — as pausas ficam ENTRE segmentos.
      '-ml', '1', '-sow',
      '-t', '${_threadCount()}',
    ], workingDirectory: workDir, token: token);
    if (r2.exitCode != 0) throw PipelineException(PipelineStage.transcribe, 'Whisper falhou');
    final jsonFile = File(p.join(workDir, 'transcript.json'));
    if (!jsonFile.existsSync()) throw PipelineException(PipelineStage.transcribe, 'transcript.json não gerado');
    final data = jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
    final list = data['transcription'] as List;
    if (list.isEmpty) throw PipelineException(PipelineStage.transcribe, 'Nenhuma fala detectada no vídeo');
    final segments = list.map((e) {
      final offsets = e['offsets'];
      return TranscriptSegment(
        Duration(milliseconds: offsets['from'] as int),
        Duration(milliseconds: offsets['to'] as int),
        (e['text'] as String).trim(),
      );
    }).toList();
    // O whisper estica o fim dos segmentos através dos silêncios; apara as
    // janelas à fala real — todo o agendamento da dublagem depende disso.
    final asrWav = readWav(p.join(workDir, 'asr_in.wav'));
    return trimSegmentsToSpeech(segments, asrWav.samples, asrWav.sampleRate);
  }
}
