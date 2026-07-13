import 'dart:io';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/runtime/media_tool_runner.dart';
import 'package:dubbing_engine/src/wav.dart';
import 'package:path/path.dart' as p;

/// Monta a faixa de voz dublada com EXATAMENTE a duração do vídeo.
///
/// O mix final usa `amix=duration=first`, e o primeiro input é o áudio original
/// — cuja duração é a do vídeo. Logo, o que passar do fim do vídeo é descartado
/// pelo ffmpeg de qualquer jeito. Estender o buffer aqui só criaria a ilusão de
/// que a cauda foi preservada. O agendamento (`planDubSchedule`) já acelera o
/// último run para caber; o resíduo que ainda assim sobrar é devolvido em
/// [truncatedTail] para ser medido e reportado, nunca cortado em silêncio.
/// Escrita SEQUENCIAL: a faixa é gravada quadro a quadro, na ordem, sem nunca
/// materializar o vídeo inteiro em memória.
///
/// Antes isto alocava um `Float32List` do tamanho do vídeo (~635 MB por hora, só
/// em mono float32) e somava cada fala dentro dele. O scheduler garante que as
/// falas não se sobrepõem (`fitter.dart`: `placementSec = max(segStart, cursor)`),
/// então basta escrever silêncio até o início de cada fala e copiar os quadros
/// PCM16 do `seg_<id>_fit.wav` — sem soma, sem conversão para float, com memória
/// constante.
Future<({String path, Duration truncatedTail})> buildDubTrack(
  List<DubbingSegment> segments,
  double videoDurationSec,
  String workDir,
  CancellationToken token,
) async {
  final totalFrames = (videoDurationSec * mixSampleRate).round();
  final dubVoicePath = p.join(workDir, 'dub_voice.wav');

  final placed = segments
      .where((s) => s.fittedAudioPath != null && s.fittedSampleCount != null)
      .toList()
    ..sort((a, b) => a.placedStart.compareTo(b.placedStart));

  final writer = WavPcm16Writer.create(dubVoicePath, sampleRate: mixSampleRate);
  var overrunFrames = 0;
  try {
    var cursor = 0;
    for (final seg in placed) {
      token.throwIfCancelled(PipelineStage.mix);
      final startFrame =
          (seg.placedStart.inMicroseconds / 1000000.0 * mixSampleRate).round();
      if (startFrame < cursor) {
        // O writer é mais estrito que o buffer antigo, que somava sobreposições
        // em silêncio. Se isto disparar, o scheduler quebrou uma invariável.
        throw PipelineException(
            PipelineStage.mix,
            'Fala ${seg.id} começa em $startFrame, antes do fim da anterior '
            '($cursor) — o agendamento não pode sobrepor falas.');
      }
      writer.writeSilence(startFrame - cursor);
      cursor = startFrame;

      final end = startFrame + seg.fittedSampleCount!;
      if (end - totalFrames > overrunFrames) overrunFrames = end - totalFrames;

      // Cauda além do fim do vídeo seria descartada pelo ffmpeg de qualquer
      // forma (amix duration=first): não é escrita, é MEDIDA.
      final room = totalFrames - startFrame;
      if (room <= 0) continue;

      final reader = WavReader.open(seg.fittedAudioPath!);
      try {
        var written = 0;
        final limit =
            reader.frameCount < room ? reader.frameCount : room;
        const chunk = 1 << 16;
        while (written < limit) {
          final take = (limit - written) < chunk ? (limit - written) : chunk;
          writer.writeRawFrames(reader.readRawFrames(written, take));
          written += take;
        }
        cursor = startFrame + written;
      } finally {
        reader.close();
      }
    }
    writer.writeSilence(totalFrames - cursor);
  } catch (_) {
    writer.abort();
    rethrow;
  }
  writer.finish();

  return (
    path: dubVoicePath,
    truncatedTail: Duration(
        microseconds: (overrunFrames / mixSampleRate * 1e6).round()),
  );
}

Future<String> buildFinalMix(
  bool voiceOverMode,
  String workDir,
  MediaToolRunner media,
  CancellationToken token,
) async {
  final dubbedPath = p.join(workDir, 'dubbed.wav');
  if (voiceOverMode) {
    final r = await media.run(MediaTool.ffmpeg, [
      '-y',
      '-i', p.join(workDir, 'audio_full.wav'),
      '-i', p.join(workDir, 'dub_voice.wav'),
      '-filter_complex',
      '[0:a][1:a]sidechaincompress=threshold=0.02:ratio=12:attack=20:release=400[bg];'
      '[bg][1:a]amix=inputs=2:duration=first:normalize=0,'
      'loudnorm=I=-16:TP=-1.5:LRA=11[out]',
      '-map', '[out]',
      '-ac', '2',
      '-ar', '44100',
      '-c:a', 'pcm_s16le',
      dubbedPath,
    ], workingDirectory: workDir, token: token);
    if (r.exitCode != 0) {
      throw PipelineException(PipelineStage.mix, 'Mixagem com ducking falhou');
    }
  } else {
    final r = await media.run(MediaTool.ffmpeg, [
      '-y',
      '-i', p.join(workDir, 'accompaniment.wav'),
      '-i', p.join(workDir, 'dub_voice.wav'),
      '-filter_complex',
      '[0:a][1:a]amix=inputs=2:duration=first:normalize=0,'
      'loudnorm=I=-16:TP=-1.5:LRA=11[out]',
      '-map', '[out]',
      '-ac', '2',
      '-ar', '44100',
      '-c:a', 'pcm_s16le',
      dubbedPath,
    ], workingDirectory: workDir, token: token);
    if (r.exitCode != 0) {
      throw PipelineException(PipelineStage.mix, 'Mixagem falhou');
    }
  }
  if (!File(dubbedPath).existsSync()) {
    throw PipelineException(PipelineStage.mix, 'dubbed.wav não foi gerado');
  }
  return dubbedPath;
}
