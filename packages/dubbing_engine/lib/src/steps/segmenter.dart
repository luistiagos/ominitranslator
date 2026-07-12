import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';

/// Resolves the timestamp of a boundary that has no real constituent to land on.
///
/// Only consulted when a single [TranscriptSegment] carries more than one
/// sentence, which is what happens when the ASR backend has no word-level
/// timestamps (sherpa/Whisper on Android emits one segment per VAD run).
/// [estimate] is the character-proportional guess; the resolver may move it
/// anywhere within (`lower`, `upper`), typically to the nearest energy valley.
typedef BoundaryResolver = Duration Function(
  Duration estimate, {
  required Duration lower,
  required Duration upper,
});

/// Groups raw transcript segments into the units that get dubbed.
///
/// Merges consecutive segments of the same speaker, then cuts the merged text
/// back apart at sentence boundaries. The cut lands on the boundary between the
/// constituents that were merged, so the timestamps the ASR produced survive the
/// round trip — with word-level input (whisper-cli `-ml 1 -sow`) every sentence
/// keeps the exact start and end of its first and last word.
List<DubbingSegment> buildDubbingSegments(
  List<TranscriptSegment> raw, {
  BoundaryResolver? resolveBoundary,
}) {
  final filtered = <TranscriptSegment>[];
  for (final seg in raw) {
    String text = seg.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) continue;
    if (RegExp(r'^[♪♫\s]+$').hasMatch(text)) continue;
    if (RegExp(r'^\[.*\]$').hasMatch(text)) continue;
    filtered.add(TranscriptSegment(seg.start, seg.end, text, speaker: seg.speaker));
  }
  if (filtered.isEmpty) return [];

  // Merge, keeping each unit's constituents instead of collapsing them into a
  // single segment — they are what the sentence split lands on further down.
  final merged = <List<TranscriptSegment>>[];
  List<TranscriptSegment>? cur;
  for (final seg in filtered) {
    if (cur == null) {
      cur = [seg];
      continue;
    }
    final unitStart = cur.first.start;
    final unitEnd = cur.last.end;
    final unitChars = cur.fold<int>(0, (s, t) => s + t.text.length) + cur.length - 1;
    if (seg.speaker == cur.first.speaker &&
        (seg.start - unitEnd) < mergeMaxPause &&
        (unitChars + 1 + seg.text.length) < mergeMaxChars &&
        (seg.end - unitStart) < mergeMaxDur) {
      cur.add(seg);
    } else {
      merged.add(cur);
      cur = [seg];
    }
  }
  if (cur != null) merged.add(cur);

  final result = <DubbingSegment>[];
  int id = 0;
  for (final unit in merged) {
    for (final s in _splitUnit(unit, resolveBoundary)) {
      result.add(DubbingSegment(id++, s.start, s.end, s.text, speaker: s.speaker));
    }
  }
  return result;
}

/// Cuts one merged unit back into sentences, on constituent boundaries.
List<TranscriptSegment> _splitUnit(
  List<TranscriptSegment> unit,
  BoundaryResolver? resolveBoundary,
) {
  // A constituent may itself hold more than one sentence (no word-level
  // timestamps). Break it up first, so every token below holds at most one
  // sentence ending and the grouping loop can stay uniform.
  final tokens = <TranscriptSegment>[];
  for (final t in unit) {
    tokens.addAll(_expandSentences(t, resolveBoundary));
  }

  final sentences = <TranscriptSegment>[];
  var from = 0;
  for (int i = 0; i < tokens.length; i++) {
    final isLast = i == tokens.length - 1;
    final endsHere = isLast ||
        (_endsSentence(tokens[i].text) && _startsSentence(tokens[i + 1].text));
    if (!endsHere) continue;
    final parts = tokens.sublist(from, i + 1);
    sentences.add(TranscriptSegment(
      parts.first.start,
      parts.last.end,
      parts.map((t) => t.text).join(' '),
      speaker: parts.first.speaker,
    ));
    from = i + 1;
  }
  return sentences;
}

/// Splits a single segment that carries several sentences, dividing its span
/// proportionally to the character count — the only estimate available without
/// finer timestamps. [resolveBoundary], when supplied, snaps each cut to the
/// real audio (see [BoundaryResolver]).
List<TranscriptSegment> _expandSentences(
  TranscriptSegment seg,
  BoundaryResolver? resolveBoundary,
) {
  final parts = _splitSentences(seg.text);
  if (parts.length == 1) return [seg];

  final totalUs = (seg.end - seg.start).inMicroseconds;
  final charsTotal = parts.fold<int>(0, (s, p) => s + p.length);
  final out = <TranscriptSegment>[];
  var cut = seg.start;
  var chars = 0;
  for (int i = 0; i < parts.length; i++) {
    final start = cut;
    Duration end;
    if (i == parts.length - 1) {
      end = seg.end;
    } else {
      chars += parts[i].length;
      end = seg.start + Duration(microseconds: (totalUs * chars / charsTotal).round());
      if (resolveBoundary != null) {
        end = resolveBoundary(end, lower: start, upper: seg.end);
      }
      if (end <= start) end = start + const Duration(milliseconds: 1);
      if (end > seg.end) end = seg.end;
    }
    out.add(TranscriptSegment(start, end, parts[i], speaker: seg.speaker));
    cut = end;
  }
  return out;
}

bool _endsSentence(String text) {
  if (text.isEmpty) return false;
  final c = text[text.length - 1];
  return c == '.' || c == '!' || c == '?' || c == '…';
}

bool _startsSentence(String text) =>
    text.isNotEmpty && RegExp(r'[A-ZÀ-Ú]').hasMatch(text[0]);

List<String> _splitSentences(String text) {
  final parts = <String>[];
  final buf = StringBuffer();
  for (int i = 0; i < text.length; i++) {
    buf.write(text[i]);
    if (_isSentenceEnd(text, i)) {
      parts.add(buf.toString().trim());
      buf.clear();
    }
  }
  final remaining = buf.toString().trim();
  if (remaining.isNotEmpty) parts.add(remaining);
  if (parts.isEmpty) parts.add(text);
  return parts;
}

bool _isSentenceEnd(String text, int i) {
  final char = text[i];
  if (char != '.' && char != '!' && char != '?' && char != '…') return false;
  if (i + 1 >= text.length) return true;
  if (text[i + 1] == ' ' && i + 2 < text.length && RegExp(r'[A-ZÀ-Ú]').hasMatch(text[i + 2])) {
    return true;
  }
  return false;
}
