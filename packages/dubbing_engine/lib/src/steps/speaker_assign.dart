import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';

/// Absorve falantes "fantasma" — clusters com pouco tempo de fala em termos
/// absolutos E relativos, quase sempre ruído da diarização (a "terceira
/// voz" numa conversa de duas pessoas). Cada turno de um falante menor é
/// reatribuído ao falante principal mais próximo no tempo.
List<SpeakerTurn> pruneMinorSpeakers(List<SpeakerTurn> turns) {
  if (turns.isEmpty) return turns;
  final airtime = <int, double>{};
  double total = 0;
  for (final t in turns) {
    airtime[t.speaker] = (airtime[t.speaker] ?? 0) + t.duration;
    total += t.duration;
  }
  final major = airtime.entries
      .where((e) =>
          e.value >= minSpeakerAirtimeSeconds ||
          (total > 0 && e.value / total >= minSpeakerAirtimeFraction))
      .map((e) => e.key)
      .toSet();
  if (major.isEmpty || major.length == airtime.length) return turns;
  final majorTurns = turns.where((t) => major.contains(t.speaker)).toList();
  return turns.map((t) {
    if (major.contains(t.speaker)) return t;
    SpeakerTurn? nearest;
    double nearestDist = double.infinity;
    for (final m in majorTurns) {
      final dist = t.start > m.end
          ? t.start - m.end
          : (m.start > t.end ? m.start - t.end : 0.0);
      if (dist < nearestDist) {
        nearestDist = dist;
        nearest = m;
      }
    }
    return SpeakerTurn(t.start, t.end, nearest!.speaker);
  }).toList();
}

/// Atribui um falante a cada segmento transcrito a partir dos turnos da
/// diarização. O falante escolhido é o do turno com maior sobreposição
/// temporal — mas só quando a sobreposição é significativa
/// ([minSegmentOverlapRatio] da duração do segmento); segmentos ambíguos
/// herdam o falante anterior (continuidade), e flips isolados curtos entre
/// vizinhos iguais são suavizados (erro de fronteira da diarização).
/// Os índices são renumerados por tempo total de fala (0 = quem mais fala),
/// para que o falante principal receba a voz padrão do idioma.
List<TranscriptSegment> assignSpeakers(
    List<TranscriptSegment> segments, List<SpeakerTurn> turns) {
  if (turns.isEmpty) return segments;
  final rank = rankSpeakersByAirtime(turns);
  final result = <TranscriptSegment>[];
  int? prevSpeaker;
  for (final seg in segments) {
    final match = _speakerFor(seg, turns);
    final int speaker;
    if (match.overlapRatio >= minSegmentOverlapRatio || prevSpeaker == null) {
      speaker = rank[match.speaker] ?? 0;
    } else {
      speaker = prevSpeaker;
    }
    prevSpeaker = speaker;
    result.add(
        TranscriptSegment(seg.start, seg.end, seg.text, speaker: speaker));
  }
  for (int i = 1; i + 1 < result.length; i++) {
    final cur = result[i];
    if (cur.speaker != result[i - 1].speaker &&
        result[i - 1].speaker == result[i + 1].speaker &&
        (cur.end - cur.start) <= maxSpeakerFlapSegment) {
      result[i] = TranscriptSegment(cur.start, cur.end, cur.text,
          speaker: result[i - 1].speaker);
    }
  }
  return result;
}

({int speaker, double overlapRatio}) _speakerFor(
    TranscriptSegment seg, List<SpeakerTurn> turns) {
  final segStart = seg.start.inMicroseconds / 1e6;
  final segEnd = seg.end.inMicroseconds / 1e6;
  final segDuration = segEnd - segStart;
  double bestOverlap = 0;
  int bestSpeaker = -1;
  double bestDistance = double.infinity;
  int nearestSpeaker = turns.first.speaker;
  for (final turn in turns) {
    final overlap = (segEnd < turn.end ? segEnd : turn.end) -
        (segStart > turn.start ? segStart : turn.start);
    if (overlap > bestOverlap) {
      bestOverlap = overlap;
      bestSpeaker = turn.speaker;
    }
    final distance = segStart > turn.end
        ? segStart - turn.end
        : (turn.start > segEnd ? turn.start - segEnd : 0.0);
    if (distance < bestDistance) {
      bestDistance = distance;
      nearestSpeaker = turn.speaker;
    }
  }
  if (bestSpeaker < 0) {
    return (speaker: nearestSpeaker, overlapRatio: 0.0);
  }
  return (
    speaker: bestSpeaker,
    overlapRatio: segDuration > 0 ? bestOverlap / segDuration : 0.0,
  );
}

/// Mapeia id bruto de cluster → índice ordenado por tempo total de fala.
/// Público para o pipeline renumerar outros mapas (ex.: sexo por falante)
/// com o mesmo critério usado em [assignSpeakers].
Map<int, int> rankSpeakersByAirtime(List<SpeakerTurn> turns) {
  final airtime = <int, double>{};
  for (final turn in turns) {
    airtime[turn.speaker] = (airtime[turn.speaker] ?? 0) + turn.duration;
  }
  final ordered = airtime.keys.toList()
    ..sort((a, b) => airtime[b]!.compareTo(airtime[a]!));
  return {for (int i = 0; i < ordered.length; i++) ordered[i]: i};
}
