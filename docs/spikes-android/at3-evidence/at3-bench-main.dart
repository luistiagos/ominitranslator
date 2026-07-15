// AT-3 spike: roda a matriz de comandos reais do pipeline sobre o NOSSO build
// LGPL do FFmpegKitNext (AAR local), no device. Prova os primitivos do §12.3
// (sessão async, statistics->progresso, cancelamento, timeout) e valida cada
// output reabrindo-o com ffprobe.
//
// Layout esperado (adb push para /data/local/tmp/at3, copiado pelo app para a
// própria pasta no primeiro start — mesmo contorno de storage do AT-2):
//   at3/fixture.mp4  (h264+aac, 60s)
//   at3/voice.wav    (pcm_s16le estéreo, 60s)
// Saída: at3/results/<caso>.json, summary.json, log.txt

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _ch = MethodChannel('at3/ffmpeg');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BenchApp());
}

class BenchApp extends StatefulWidget {
  const BenchApp({super.key});
  @override
  State<BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<BenchApp> {
  String _status = 'starting…';
  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      await _runBenchmark((s) => setState(() => _status = s));
    } catch (e, st) {
      setState(() => _status = 'FATAL: $e\n$st');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_status, style: const TextStyle(fontSize: 13)),
            ),
          ),
        ),
      );
}

// ---- ponte para o MethodChannel ----

Future<int> _ffmpegStart(List<String> args) async {
  final r = await _ch.invokeMethod('ffmpegStart', {'args': args});
  return (r['sessionId'] as num).toInt();
}

Future<Map<String, dynamic>> _ffmpegPoll(int sessionId) async {
  final r = await _ch.invokeMethod('ffmpegPoll', {'sessionId': sessionId});
  return Map<String, dynamic>.from(r as Map);
}

Future<void> _ffmpegCancel(int sessionId) =>
    _ch.invokeMethod('ffmpegCancel', {'sessionId': sessionId});

Future<Map<String, dynamic>> _ffprobe(List<String> args) async {
  final r = await _ch.invokeMethod('ffprobe', {'args': args});
  return Map<String, dynamic>.from(r as Map);
}

/// Roda ffmpeg async e faz poll até terminar. Coleta amostras de statTimeMs
/// (progresso). Retorna o mapa final do poll + as amostras.
Future<Map<String, dynamic>> _runFfmpeg(List<String> args,
    {Duration timeout = const Duration(minutes: 3)}) async {
  final sessionId = await _ffmpegStart(args);
  final progressSamples = <double>[];
  final sw = Stopwatch()..start();
  Map<String, dynamic> poll = {};
  while (true) {
    await Future.delayed(const Duration(milliseconds: 200));
    poll = await _ffmpegPoll(sessionId);
    final t = (poll['statTimeMs'] as num?)?.toDouble() ?? -1;
    if (t >= 0 && (progressSamples.isEmpty || progressSamples.last != t)) {
      progressSamples.add(t);
    }
    final state = poll['state'] as String?;
    if (state == 'COMPLETED' || state == 'FAILED') break;
    if (sw.elapsed > timeout) {
      await _ffmpegCancel(sessionId);
      poll = await _ffmpegPoll(sessionId);
      poll['timedOut'] = true;
      break;
    }
  }
  poll['sessionId'] = sessionId;
  poll['progressSamples'] = progressSamples;
  poll['elapsedMs'] = sw.elapsedMilliseconds;
  return poll;
}

// ---- helpers de validação (via ffprobe) ----

Future<Map<String, dynamic>> _probeJson(String path) async {
  final r = await _ffprobe([
    '-v', 'error', '-print_format', 'json',
    '-show_format', '-show_streams', path,
  ]);
  final out = r['output'] as String? ?? '';
  try {
    return {'rc': r['returnCode'], 'json': jsonDecode(out)};
  } catch (_) {
    return {'rc': r['returnCode'], 'json': null, 'raw': out};
  }
}

double _durationOf(Map<String, dynamic> probe) {
  final j = probe['json'];
  if (j is Map && j['format'] is Map) {
    final d = j['format']['duration'];
    return double.tryParse('$d') ?? -1;
  }
  return -1;
}

/// Reduz o mapa do poll do ffmpeg para os campos que interessam no JSON.
Map<String, dynamic> _slim(Map<String, dynamic> r) => {
      'state': r['state'], 'returnCode': r['returnCode'],
      'isSuccess': r['isSuccess'], 'isCancel': r['isCancel'],
      'elapsedMs': r['elapsedMs'],
      'progressSampleCount': (r['progressSamples'] as List?)?.length ?? 0,
      'logsTail': (r['logsTail'] as String?)?.split('\n').take(6).join(' | '),
    };

Future<void> _runBenchmark(void Function(String) status) async {
  final extDir = await getExternalStorageDirectory();
  if (extDir == null) throw Exception('sem external storage dir');
  final base = '${extDir.path}/at3';
  final resultsDir = Directory('$base/results')..createSync(recursive: true);
  final log = File('${resultsDir.path}/log.txt').openWrite(mode: FileMode.write);
  Future<void> logLine(String s) async {
    log.writeln('${DateTime.now().toIso8601String()} $s');
    await log.flush();
  }

  // Copia as fixtures de /data/local/tmp/at3 (adb push) para a pasta do app.
  const src = '/data/local/tmp/at3';
  for (final f in ['fixture.mp4', 'voice.wav']) {
    final s = File('$src/$f');
    final d = File('$base/$f');
    if (s.existsSync() && (!d.existsSync() || d.lengthSync() != s.lengthSync())) {
      d.parent.createSync(recursive: true);
      s.copySync(d.path);
    }
  }
  final fixture = '$base/fixture.mp4';
  final voice = '$base/voice.wav';
  if (!File(fixture).existsSync()) {
    throw Exception('fixture ausente: $fixture (fez adb push para $src?)');
  }

  await logLine('=== AT-3 matriz ===');
  final summary = <String, dynamic>{};

  Future<void> record(String tag, Map<String, dynamic> data) async {
    summary[tag] = {'ok': data['ok']};
    File('${resultsDir.path}/$tag.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
    await logLine('$tag: ok=${data['ok']} ${data['note'] ?? ''}');
    status('$tag: ${data['ok'] == true ? 'OK' : 'FALHOU'}');
  }

  final au = '$base/audio_full.wav';
  final atempoWav = '$base/seg_atempo.wav';
  final childWav = '$base/child.wav';
  final dubbed = '$base/dubbed.wav';
  final joined = '$base/joined.wav';
  final aacOut = '$base/out_aac.m4a';
  final finalMp4 = '$base/final.mp4';

  // 1 — probe JSON
  {
    final p = await _probeJson(fixture);
    final j = p['json'];
    final streams = (j is Map ? j['streams'] : null) as List?;
    final hasVideo = streams?.any((s) => s['codec_type'] == 'video' && s['codec_name'] == 'h264') ?? false;
    final hasAudio = streams?.any((s) => s['codec_type'] == 'audio') ?? false;
    final dur = _durationOf(p);
    await record('01_probe', {
      'ok': p['rc'] == 0 && hasVideo && hasAudio && (dur - 60).abs() < 0.5,
      'returnCode': p['rc'], 'durationSec': dur,
      'hasH264Video': hasVideo, 'hasAudio': hasAudio,
      'note': 'dur=$dur',
    });
  }

  // 2 — demux PCM16
  {
    final r = await _runFfmpeg(['-y', '-i', fixture, '-vn', '-ac', '2', '-ar', '44100', '-c:a', 'pcm_s16le', au]);
    final p = await _probeJson(au);
    final st = (p['json']?['streams'] as List?)?.first;
    await record('02_demux', {
      'ok': r['isSuccess'] == true && st?['codec_name'] == 'pcm_s16le' &&
          '${st?['sample_rate']}' == '44100' && st?['channels'] == 2,
      'ffmpeg': _slim(r), 'probe': st, 'note': 'dur=${_durationOf(p)}',
    });
  }

  // 3 — atempo=1.25 (48s esperado)
  {
    final r = await _runFfmpeg(['-y', '-i', au, '-filter:a', 'atempo=1.2500', atempoWav]);
    final p = await _probeJson(atempoWav);
    final dur = _durationOf(p);
    await record('03_atempo', {
      'ok': r['isSuccess'] == true && (dur - 48).abs() < 0.3,
      'ffmpeg': _slim(r), 'durationSec': dur, 'note': 'dur=$dur (esperado ~48)',
    });
  }

  // 4 — asetrate/aresample (voz infantil: pitch 1.15, atempo inverso; ~60s)
  {
    final rate = (44100 * 1.15).round(); // 50715
    const tempo = '0.8696'; // 1/1.15
    final r = await _runFfmpeg(['-y', '-i', au, '-filter:a', 'asetrate=$rate,aresample=44100,atempo=$tempo', childWav]);
    final p = await _probeJson(childWav);
    final st = (p['json']?['streams'] as List?)?.first;
    final dur = _durationOf(p);
    await record('04_asetrate_aresample', {
      'ok': r['isSuccess'] == true && '${st?['sample_rate']}' == '44100' && (dur - 60).abs() < 0.6,
      'ffmpeg': _slim(r), 'probe': st, 'durationSec': dur, 'note': 'rate=$rate dur=$dur',
    });
  }

  // 5+6+7 — sidechaincompress + amix + loudnorm (filtergraph literal de produção)
  {
    final r = await _runFfmpeg([
      '-y', '-i', au, '-i', voice,
      '-filter_complex',
      '[0:a][1:a]sidechaincompress=threshold=0.02:ratio=12:attack=20:release=400[bg];'
          '[bg][1:a]amix=inputs=2:duration=first:normalize=0,'
          'loudnorm=I=-16:TP=-1.5:LRA=11[out]',
      '-map', '[out]', '-ac', '2', '-ar', '44100', '-c:a', 'pcm_s16le', dubbed,
    ]);
    final p = await _probeJson(dubbed);
    final st = (p['json']?['streams'] as List?)?.first;
    final dur = _durationOf(p);
    await record('05_sidechain_amix_loudnorm', {
      'ok': r['isSuccess'] == true && st?['codec_name'] == 'pcm_s16le' &&
          '${st?['sample_rate']}' == '44100' && (dur - 60).abs() < 0.6,
      'ffmpeg': _slim(r), 'probe': st, 'durationSec': dur,
      'progressSampleCount': (r['progressSamples'] as List?)?.length ?? 0,
      'note': 'dur=$dur progress=${(r['progressSamples'] as List?)?.length}',
    });
  }

  // 8a — segment muxer
  {
    final r = await _runFfmpeg(['-y', '-i', dubbed, '-f', 'segment', '-segment_time', '10', '-c', 'copy', '$base/part_%03d.wav']);
    final parts = Directory(base).listSync().where((e) => e.path.contains('part_') && e.path.endsWith('.wav')).toList();
    await record('08a_segment', {
      'ok': r['isSuccess'] == true && parts.length >= 6,
      'ffmpeg': _slim(r), 'partCount': parts.length, 'note': '${parts.length} partes',
    });
    final parts2 = parts.map((e) => e.path).toList()..sort();
    File('$base/list.txt').writeAsStringSync(parts2.map((p) => "file '$p'").join('\n'));
  }

  // 8b — concat demuxer
  {
    final r = await _runFfmpeg(['-y', '-f', 'concat', '-safe', '0', '-i', '$base/list.txt', '-c', 'copy', joined]);
    final p = await _probeJson(joined);
    final dur = _durationOf(p);
    await record('08b_concat', {
      'ok': r['isSuccess'] == true && (dur - 60).abs() < 0.3,
      'ffmpeg': _slim(r), 'durationSec': dur, 'note': 'dur=$dur',
    });
  }

  // 9 — AAC 192k
  {
    final r = await _runFfmpeg(['-y', '-i', dubbed, '-c:a', 'aac', '-b:a', '192k', aacOut]);
    final p = await _probeJson(aacOut);
    final st = (p['json']?['streams'] as List?)?.first;
    await record('09_aac192k', {
      'ok': r['isSuccess'] == true && st?['codec_name'] == 'aac',
      'ffmpeg': _slim(r), 'probe': st, 'note': 'codec=${st?['codec_name']}',
    });
  }

  // 10 — mux -c:v copy (com faixa original, tags de idioma)
  {
    final r = await _runFfmpeg([
      '-y', '-i', fixture, '-i', dubbed,
      '-map', '0:v:0', '-map', '1:a:0', '-map', '0:a:0',
      '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k',
      '-metadata:s:a:0', 'language=por', '-metadata:s:a:1', 'language=eng',
      '-disposition:a:0', 'default', finalMp4,
    ]);
    final p = await _probeJson(finalMp4);
    final streams = (p['json']?['streams'] as List?) ?? [];
    final vh264 = streams.any((s) => s['codec_type'] == 'video' && s['codec_name'] == 'h264');
    final audioCount = streams.where((s) => s['codec_type'] == 'audio').length;
    await record('10_mux_copy', {
      'ok': r['isSuccess'] == true && vh264 && audioCount == 2,
      'ffmpeg': _slim(r), 'videoIsH264Copy': vh264, 'audioTrackCount': audioCount,
      'durationSec': _durationOf(p), 'note': 'v=h264:$vh264 audio=$audioCount',
    });
  }

  // 11 — re-encode fallback (openh264) — decisão C3
  {
    final r = await _runFfmpeg([
      '-y', '-i', fixture, '-i', dubbed,
      '-map', '0:v:0', '-map', '1:a:0',
      '-c:v', 'libopenh264', '-b:v', '5M', '-c:a', 'aac', '-b:a', '192k',
      '$base/reencode.mp4',
    ]);
    final p = await _probeJson('$base/reencode.mp4');
    final vh264 = (p['json']?['streams'] as List?)?.any((s) => s['codec_type'] == 'video' && s['codec_name'] == 'h264') ?? false;
    await record('11_reencode_openh264', {
      'ok': r['isSuccess'] == true && vh264,
      'ffmpeg': _slim(r), 'videoIsH264': vh264, 'note': 'v=h264:$vh264',
    });
  }

  // 12 — cancelamento (execução longa via -stream_loop; cancela após ~2s)
  {
    final sessionId = await _ffmpegStart([
      '-y', '-stream_loop', '200', '-i', dubbed,
      '-c:a', 'pcm_s16le', '$base/cancel_target.wav',
    ]);
    await Future.delayed(const Duration(seconds: 2));
    await _ffmpegCancel(sessionId);
    Map<String, dynamic> poll = {};
    for (var i = 0; i < 50; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      poll = await _ffmpegPoll(sessionId);
      if (poll['state'] != 'RUNNING') break;
    }
    await record('12_cancel', {
      'ok': poll['isCancel'] == true && poll['state'] != 'RUNNING',
      'state': poll['state'], 'returnCode': poll['returnCode'],
      'isCancel': poll['isCancel'], 'isSuccess': poll['isSuccess'],
      'note': 'state=${poll['state']} isCancel=${poll['isCancel']}',
    });
  }

  // 13 — timeout (o Dart aplica timeout de 3s numa execução longa)
  {
    final r = await _runFfmpeg([
      '-y', '-stream_loop', '200', '-i', dubbed,
      '-c:a', 'pcm_s16le', '$base/timeout_target.wav',
    ], timeout: const Duration(seconds: 3));
    await record('13_timeout', {
      'ok': r['timedOut'] == true && r['isSuccess'] != true,
      'timedOut': r['timedOut'], 'state': r['state'], 'isCancel': r['isCancel'],
      'note': 'timedOut=${r['timedOut']} state=${r['state']}',
    });
  }

  final allOk = summary.values.every((v) => (v as Map)['ok'] == true);
  summary['ALL_OK'] = allOk;
  File('${resultsDir.path}/summary.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));
  await logLine('=== DONE === ALL_OK=$allOk');
  await log.flush();
  await log.close();
  status('DONE — ALL_OK=$allOk (ver at3/results/summary.json)');
}
