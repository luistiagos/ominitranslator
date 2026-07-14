// AT-2 §11.3 gate de sincronia: compara os limites de segmento produzidos
// pelo whisper-cli (desktop, baseline) com os do sherpa+VAD (device, já
// rodado e salvo em JSON) sobre o MESMO clipe sintético, passando os dois
// pelo mesmo buildDubbingSegments. Critério de aceite: >=90% dos segmentos
// do device dentro de +-300 ms do baseline desktop.
//
// Alinhamento: NÃO por índice. Na prática o whisper-cli desktop segmenta
// ~10-25% a mais que o número real de frases (palavras isoladas na pausa
// entre frases viram segmentos extras que sobrevivem ao buildDubbingSegments
// como "sentenças" de uma palavra) — um índice raso desalinha tudo após a
// primeira divergência. Em vez disso, cada frase do ground truth (verdade
// conhecida da síntese) é o âncora: para desktop e para device, pega-se o
// segmento cujo start está mais perto do início real daquela frase. Isso
// filtra segmentos espúrios de ambos os lados automaticamente.
//
// Uso: dart run tool/at2_sync_report.dart <fixtureDir> <deviceResultsDir> <outDir>
//   fixtureDir: contém en.wav/pt.wav/es.wav + <lang>_ground_truth.json
//               (saída de tool/at2_gen_fixture.dart)
//   deviceResultsDir: <lang>_fast.json e <lang>_best.json puxados do device
//   outDir: onde escrever sync_report_<lang>_<preset>.json e sync_summary.json
import 'dart:convert';
import 'dart:io';

import 'package:dubbing_engine/src/backends/whisper_transcriber.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/steps/segmenter.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:path/path.dart' as p;

const _langs = {'en': Lang.en, 'pt': Lang.pt, 'es': Lang.es};

/// Segmento de [starts] mais próximo de [targetMs], ou null se o mais
/// próximo ainda estiver a mais de [maxDistanceMs] de distância.
int? _nearest(List<int> starts, int targetMs, int maxDistanceMs) {
  int? best;
  var bestDist = maxDistanceMs + 1;
  for (final s in starts) {
    final d = (s - targetMs).abs();
    if (d < bestDist) {
      bestDist = d;
      best = s;
    }
  }
  return bestDist <= maxDistanceMs ? best : null;
}

void main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
        'uso: dart run tool/at2_sync_report.dart <fixtureDir> <deviceResultsDir> <outDir>');
    exit(2);
  }
  final fixtureDir = args[0];
  final deviceResultsDir = args[1];
  final outDir = args[2];
  Directory(outDir).createSync(recursive: true);

  final appData = Platform.environment['APPDATA'] ??
      '${Platform.environment['USERPROFILE']}\\AppData\\Roaming';
  final modelsRoot = '$appData\\omnitranslator\\models';
  final tools = Tools.locate();
  final models = ModelManager(modelsRoot, tools);
  final token = CancellationToken();

  final summary = <String, dynamic>{};

  for (final entry in _langs.entries) {
    final langCode = entry.key;
    final lang = entry.value;

    final workDir = Directory(p.join(outDir, 'work_$langCode'));
    workDir.createSync(recursive: true);
    final wavCopy = p.join(workDir.path, '$langCode.wav');
    File(p.join(fixtureDir, '$langCode.wav')).copySync(wavCopy);

    final groundTruth = jsonDecode(
        File(p.join(fixtureDir, '${langCode}_ground_truth.json'))
            .readAsStringSync()) as Map<String, dynamic>;
    final gtSentences =
        (groundTruth['sentences'] as List).cast<Map<String, dynamic>>();

    for (final preset in [Preset.fast, Preset.best]) {
      final presetName = preset == Preset.fast ? 'fast' : 'best';
      final tag = '${langCode}_$presetName';
      print('=== $tag: whisper-cli desktop ===');

      final rawSegments = await WhisperTranscriber(tools, models, preset)
          .transcribe(wavCopy, lang, token);
      final desktopSegments = buildDubbingSegments(rawSegments);

      final deviceFile = File(p.join(deviceResultsDir, '$tag.json'));
      if (!deviceFile.existsSync()) {
        print('  SKIP $tag: sem resultado do device em ${deviceFile.path}');
        continue;
      }
      final deviceData =
          jsonDecode(deviceFile.readAsStringSync()) as Map<String, dynamic>;
      final deviceRawSegs = (deviceData['segments'] as List)
          .cast<Map<String, dynamic>>()
          .map((s) => TranscriptSegment(
                Duration(milliseconds: s['startMs'] as int),
                Duration(milliseconds: s['endMs'] as int),
                s['text'] as String,
              ))
          .toList();
      final deviceSegments = buildDubbingSegments(deviceRawSegs);

      final desktopStarts =
          desktopSegments.map((s) => s.start.inMilliseconds).toList();
      final deviceStarts =
          deviceSegments.map((s) => s.start.inMilliseconds).toList();

      const maxMatchMs = 2000; // acima disso não é a mesma frase, é uma falha real
      final deltas = <Map<String, dynamic>>[];
      var within300 = 0;
      var matched = 0;
      for (final gt in gtSentences) {
        final gtMs = gt['startMs'] as int;
        final desktopMs = _nearest(desktopStarts, gtMs, maxMatchMs);
        final deviceMs = _nearest(deviceStarts, gtMs, maxMatchMs);
        if (desktopMs == null || deviceMs == null) {
          deltas.add({
            'gtStartMs': gtMs,
            'desktopStartMs': desktopMs,
            'deviceStartMs': deviceMs,
            'matched': false,
          });
          continue;
        }
        matched++;
        final deltaVsDesktop = deviceMs - desktopMs;
        if (deltaVsDesktop.abs() <= 300) within300++;
        deltas.add({
          'gtStartMs': gtMs,
          'desktopStartMs': desktopMs,
          'deviceStartMs': deviceMs,
          'desktopErrorMs': desktopMs - gtMs,
          'deviceErrorMs': deviceMs - gtMs,
          'deltaVsDesktopMs': deltaVsDesktop,
          'matched': true,
        });
      }
      final pct = matched > 0 ? within300 / matched * 100 : 0.0;

      final report = {
        'lang': langCode,
        'preset': presetName,
        'desktopSegmentCount': desktopSegments.length,
        'deviceSegmentCount': deviceSegments.length,
        'groundTruthSentenceCount': gtSentences.length,
        'matchedCount': matched,
        'within300msCount': within300,
        'within300msPct': pct,
        'deltas': deltas,
      };
      File(p.join(outDir, 'sync_report_$tag.json'))
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
      summary[tag] = {
        'desktopSegmentCount': desktopSegments.length,
        'deviceSegmentCount': deviceSegments.length,
        'groundTruthSentenceCount': gtSentences.length,
        'matchedCount': matched,
        'within300msPct': pct,
      };
      print('  desktop=${desktopSegments.length} device=${deviceSegments.length} '
          'gt=${gtSentences.length} matched=$matched within300ms=$within300 '
          '(${pct.toStringAsFixed(1)}%)');
    }
  }

  File(p.join(outDir, 'sync_summary.json'))
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(summary));
  print('OK — ${p.join(outDir, 'sync_summary.json')}');
}
