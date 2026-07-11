import 'dart:io';
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/wav.dart';
import 'package:path/path.dart' as p;

int _threadCount() => (2 > (Platform.numberOfProcessors - 2)) ? 2 : (Platform.numberOfProcessors - 2);

String _tail(String stderr) {
  final lines = stderr.split('\n').where((l) => l.trim().isNotEmpty).toList();
  final last = lines.length > 3 ? lines.sublist(lines.length - 3) : lines;
  final joined = last.join(' ').trim();
  return joined.length > 300 ? joined.substring(joined.length - 300) : joined;
}

class SherpaSeparator implements Separator {
  final Tools tools;
  final ModelManager models;
  SherpaSeparator(this.tools, this.models);

  List<String> _sherpaArgs(String inputWav, String vocalsOut, String accompOut) {
    final modelPath = models.pathOf(spleeterModelId);
    return [
      '--spleeter-vocals=${p.join(modelPath, 'vocals.fp16.onnx')}',
      '--spleeter-accompaniment=${p.join(modelPath, 'accompaniment.fp16.onnx')}',
      '--num-threads=${_threadCount()}',
      '--provider=cpu',
      '--input-wav=$inputWav',
      '--output-vocals-wav=$vocalsOut',
      '--output-accompaniment-wav=$accompOut',
    ];
  }

  @override
  Future<SeparationOutcome> separate(
      String inputWav, String workDir, CancellationToken token, {RunToolFn? runToolOverride}) async {
    final exec = runToolOverride ?? runTool;
    if (models.stateOf(spleeterModelId) != ModelState.ready) {
      return SeparationOutcome.failure('Modelo $spleeterModelId não está pronto');
    }
    if (!File(tools.sherpaSourceSeparation).existsSync()) {
      return SeparationOutcome.failure(
          'Executável não encontrado: ${tools.sherpaSourceSeparation}');
    }
    final vocalsWav = p.join(workDir, 'vocals.wav');
    final accompanimentWav = p.join(workDir, 'accompaniment.wav');
    final double durationSec;
    try {
      durationSec = wavDurationSeconds(inputWav);
    } on FormatException catch (e) {
      return SeparationOutcome.failure('WAV de entrada inválido: ${e.message}');
    }
    // Falha do sherpa (provável falta de memória) é retryable: tenta de novo
    // com chunks progressivamente menores até o piso.
    int chunkSec = separationChunkSeconds;
    var attempt = durationSec <= chunkSec
        ? await _separateSingle(exec, inputWav, vocalsWav, accompanimentWav, workDir, token)
        : await _separateChunked(exec, inputWav, vocalsWav, accompanimentWav, workDir, token, chunkSec);
    while (!attempt.outcome.ok &&
        attempt.retryable &&
        !token.isCancelled &&
        chunkSec ~/ 2 >= minSeparationChunkSeconds &&
        chunkSec ~/ 2 < durationSec) {
      chunkSec ~/= 2;
      attempt = await _separateChunked(
          exec, inputWav, vocalsWav, accompanimentWav, workDir, token, chunkSec);
    }
    return attempt.outcome;
  }

  Future<({SeparationOutcome outcome, bool retryable})> _separateSingle(
      RunToolFn exec, String inputWav,
      String vocalsWav, String accompanimentWav, String workDir, CancellationToken token) async {
    final result = await exec(
      tools.sherpaSourceSeparation,
      _sherpaArgs(inputWav, vocalsWav, accompanimentWav),
      workingDirectory: workDir,
      token: token,
    );
    if (result.exitCode != 0) {
      return (
        outcome: SeparationOutcome.failure(
            'sherpa saiu com código ${result.exitCode}: ${_tail(result.stderrTail)}'),
        retryable: true,
      );
    }
    if (!File(vocalsWav).existsSync() || !File(accompanimentWav).existsSync()) {
      return (
        outcome: const SeparationOutcome.failure('sherpa não gerou os arquivos de saída'),
        retryable: true,
      );
    }
    return (
      outcome: SeparationOutcome.success(
          (vocalsWav: vocalsWav, accompanimentWav: accompanimentWav)),
      retryable: false,
    );
  }

  Future<({SeparationOutcome outcome, bool retryable})> _separateChunked(
      RunToolFn exec, String inputWav,
      String vocalsWav, String accompanimentWav, String workDir, CancellationToken token,
      int chunkSeconds) async {
    final chunkDir = p.join(workDir, 'sep_chunks');
    Directory(chunkDir).createSync(recursive: true);
    try {
      final split = await exec(tools.ffmpeg, [
        '-y', '-i', inputWav,
        '-f', 'segment',
        '-segment_time', '$chunkSeconds',
        '-c', 'copy',
        p.join(chunkDir, 'chunk_%03d.wav'),
      ], workingDirectory: chunkDir, token: token);
      if (split.exitCode != 0) {
        return (
          outcome: SeparationOutcome.failure(
              'ffmpeg segment falhou: ${_tail(split.stderrTail)}'),
          retryable: false,
        );
      }
      final chunkPattern = RegExp(r'^chunk_\d{3}\.wav$');
      final chunks = Directory(chunkDir)
          .listSync()
          .whereType<File>()
          .where((f) => chunkPattern.hasMatch(p.basename(f.path)))
          .map((f) => f.path)
          .toList()
        ..sort();
      if (chunks.isEmpty) {
        return (
          outcome: const SeparationOutcome.failure('ffmpeg segment não gerou chunks'),
          retryable: false,
        );
      }

      final vocalNames = <String>[];
      final accompNames = <String>[];
      for (int i = 0; i < chunks.length; i++) {
        if (token.isCancelled) {
          return (
            outcome: const SeparationOutcome.failure('Cancelado pelo usuário'),
            retryable: false,
          );
        }
        final idx = '$i'.padLeft(3, '0');
        final vocalName = 'chunk_${idx}_vocals.wav';
        final accompName = 'chunk_${idx}_accomp.wav';
        final v = p.join(chunkDir, vocalName);
        final a = p.join(chunkDir, accompName);
        final r = await exec(
          tools.sherpaSourceSeparation,
          _sherpaArgs(chunks[i], v, a),
          workingDirectory: chunkDir,
          token: token,
        );
        if (r.exitCode != 0) {
          return (
            outcome: SeparationOutcome.failure(
                'sherpa falhou no chunk ${i + 1}/${chunks.length} com chunks de '
                '${chunkSeconds}s (código ${r.exitCode}): ${_tail(r.stderrTail)}'),
            retryable: true,
          );
        }
        if (!File(v).existsSync() || !File(a).existsSync()) {
          return (
            outcome: SeparationOutcome.failure(
                'sherpa não gerou saídas para o chunk ${i + 1}/${chunks.length} '
                'com chunks de ${chunkSeconds}s'),
            retryable: true,
          );
        }
        vocalNames.add(vocalName);
        accompNames.add(accompName);
      }

      final concatJobs = [
        (list: 'vocals_list.txt', names: vocalNames, output: vocalsWav),
        (list: 'accomp_list.txt', names: accompNames, output: accompanimentWav),
      ];
      for (final job in concatJobs) {
        // Nomes relativos na lista evitam problemas de escaping de '\' no
        // concat demuxer do ffmpeg no Windows (workingDirectory: chunkDir).
        File(p.join(chunkDir, job.list)).writeAsStringSync(
            job.names.map((n) => "file '$n'").join('\n'));
        final r = await exec(tools.ffmpeg, [
          '-y', '-f', 'concat', '-safe', '0',
          '-i', job.list,
          '-c:a', 'pcm_s16le',
          job.output,
        ], workingDirectory: chunkDir, token: token);
        if (r.exitCode != 0) {
          return (
            outcome: SeparationOutcome.failure(
                'concat de ${job.list} falhou: ${_tail(r.stderrTail)}'),
            retryable: false,
          );
        }
      }
      if (!File(vocalsWav).existsSync() || !File(accompanimentWav).existsSync()) {
        return (
          outcome: const SeparationOutcome.failure(
              'arquivos concatenados não foram gerados'),
          retryable: false,
        );
      }
      return (
        outcome: SeparationOutcome.success(
            (vocalsWav: vocalsWav, accompanimentWav: accompanimentWav)),
        retryable: false,
      );
    } finally {
      try {
        Directory(chunkDir).deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
