import 'dart:convert';

import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/steps/sync_report.dart';
import 'package:test/test.dart';

DubbingSegment _seg(int id, int startMs, int placedMs, {int overflowMs = 0}) {
  final s = DubbingSegment(id, Duration(milliseconds: startMs),
      Duration(milliseconds: startMs + 1000), 'texto $id');
  s.placedStart = Duration(milliseconds: placedMs);
  s.overflow = Duration(milliseconds: overflowMs);
  return s;
}

void main() {
  group('buildSyncReport', () {
    test('conta as falas dentro da tolerância de ±300 ms', () {
      final segments = [
        _seg(0, 1000, 1000), // 0 ms
        _seg(1, 2000, 2299), // 299 ms — dentro
        _seg(2, 3000, 3300), // 300 ms — no limite, dentro
        _seg(3, 4000, 4301), // 301 ms — fora
      ];
      final r = buildSyncReport(segments, 10.0, Duration.zero);
      expect(r.summary.segments, 4);
      expect(r.summary.withinTolerance, 3);
      expect(r.summary.withinPct, 75.0);
      expect(r.summary.worstDeltaMs, 301);
    });

    test('delta negativo (fala adiantada) conta pelo módulo', () {
      final r = buildSyncReport([_seg(0, 5000, 4600)], 10.0, Duration.zero);
      expect(r.summary.worstDeltaMs, 400);
      expect(r.summary.withinTolerance, 0);
      final items = (jsonDecode(r.json) as Map)['items'] as List;
      expect(items.single['deltaMs'], -400);
    });

    test('estouros e cauda cortada aparecem no relatório', () {
      final segments = [
        _seg(0, 0, 0, overflowMs: 120),
        _seg(1, 2000, 2000),
        _seg(2, 4000, 4000, overflowMs: 40),
      ];
      final r = buildSyncReport(segments, 6.0, Duration(milliseconds: 250));
      expect(r.summary.segmentsWithOverflow, 2);
      final json = jsonDecode(r.json) as Map<String, dynamic>;
      expect(json['truncatedTailMs'], 250);
      expect(json['videoDurationMs'], 6000);
      expect(json['toleranceMs'], 300);
      expect(json['schemaVersion'], 1);
    });

    test('job sem segmentos não divide por zero', () {
      final r = buildSyncReport([], 10.0, Duration.zero);
      expect(r.summary.segments, 0);
      expect(r.summary.withinPct, 100.0);
      expect(r.summary.worstDeltaMs, 0);
    });

    test('o JSON preserva velocidade e atempo de cada fala', () {
      final s = _seg(0, 1000, 1000);
      s.speedUsed = 1.2;
      s.atempoUsed = 1.05;
      final r = buildSyncReport([s], 5.0, Duration.zero);
      final item = ((jsonDecode(r.json) as Map)['items'] as List).single;
      expect(item['speedUsed'], 1.2);
      expect(item['atempoUsed'], 1.05);
      expect(item['origStartMs'], 1000);
      expect(item['placedStartMs'], 1000);
    });
  });
}
