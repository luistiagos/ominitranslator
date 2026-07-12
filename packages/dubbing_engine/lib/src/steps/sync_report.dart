import 'dart:convert';

import 'package:dubbing_engine/src/models.dart';

/// Tolerância de sincronia do critério de aceite: uma fala dublada deve começar
/// dentro desta janela em torno do início da fala original.
const syncToleranceMs = 300;

/// Resumo do quanto a dublagem ficou sincronizada com o original.
typedef SyncSummary = ({
  int segments,
  int withinTolerance,
  double withinPct,
  int worstDeltaMs,
  int segmentsWithOverflow,
});

/// Mede a sincronia de um job e devolve o resumo mais o JSON completo.
///
/// O critério de release ("pelo menos 90% dos segmentos dentro de ±300 ms") era
/// conferido a ouvido, por amostragem, e só no fim de tudo. Aqui ele vira um
/// número que o próprio pipeline calcula, igual no Windows e no Android — o
/// desktop serve de baseline para o port, em vez de uma impressão auditiva.
({SyncSummary summary, String json}) buildSyncReport(
  List<DubbingSegment> segments,
  double videoDurationSec,
  Duration truncatedTail,
) {
  final rows = <Map<String, Object?>>[];
  var within = 0;
  var worst = 0;
  var overflowing = 0;

  for (final seg in segments) {
    final deltaMs =
        seg.placedStart.inMilliseconds - seg.start.inMilliseconds;
    final absDelta = deltaMs.abs();
    if (absDelta <= syncToleranceMs) within++;
    if (absDelta > worst) worst = absDelta;
    if (seg.overflow > Duration.zero) overflowing++;

    rows.add({
      'id': seg.id,
      'origStartMs': seg.start.inMilliseconds,
      'placedStartMs': seg.placedStart.inMilliseconds,
      'deltaMs': deltaMs,
      'speedUsed': seg.speedUsed,
      'atempoUsed': seg.atempoUsed,
      'overflowMs': seg.overflow.inMilliseconds,
    });
  }

  final summary = (
    segments: segments.length,
    withinTolerance: within,
    withinPct: segments.isEmpty ? 100.0 : within * 100.0 / segments.length,
    worstDeltaMs: worst,
    segmentsWithOverflow: overflowing,
  );

  final json = const JsonEncoder.withIndent('  ').convert({
    'schemaVersion': 1,
    'videoDurationMs': (videoDurationSec * 1000).round(),
    'toleranceMs': syncToleranceMs,
    'segments': summary.segments,
    'withinTolerance': summary.withinTolerance,
    'withinPct': double.parse(summary.withinPct.toStringAsFixed(2)),
    'worstDeltaMs': summary.worstDeltaMs,
    'segmentsWithOverflow': summary.segmentsWithOverflow,
    'truncatedTailMs': truncatedTail.inMilliseconds,
    'items': rows,
  });

  return (summary: summary, json: json);
}
