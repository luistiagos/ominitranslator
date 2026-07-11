import 'package:dubbing_engine/src/constants.dart';
import 'package:dubbing_engine/src/models.dart';

List<DubbingSegment> buildDubbingSegments(List<TranscriptSegment> raw) {
  final filtered = <TranscriptSegment>[];
  for (final seg in raw) {
    String text = seg.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) continue;
    if (RegExp(r'^[♪♫\s]+$').hasMatch(text)) continue;
    if (RegExp(r'^\[.*\]$').hasMatch(text)) continue;
    filtered.add(TranscriptSegment(seg.start, seg.end, text, speaker: seg.speaker));
  }
  if (filtered.isEmpty) return [];
  final merged = <TranscriptSegment>[];
  TranscriptSegment? cur;
  for (final seg in filtered) {
    if (cur == null) {
      cur = seg;
    } else if (seg.speaker == cur.speaker &&
        (seg.start - cur.end) < mergeMaxPause &&
        (cur.text.length + 1 + seg.text.length) < mergeMaxChars &&
        (seg.end - cur.start) < mergeMaxDur) {
      cur = TranscriptSegment(cur.start, seg.end, '${cur.text} ${seg.text}',
          speaker: cur.speaker);
    } else {
      merged.add(cur);
      cur = seg;
    }
  }
  if (cur != null) merged.add(cur);
  final result = <DubbingSegment>[];
  int id = 0;
  for (final u in merged) {
    final parts = _splitSentences(u.text);
    if (parts.length == 1) {
      result.add(DubbingSegment(id++, u.start, u.end, parts[0], speaker: u.speaker));
    } else {
      final total = u.end - u.start;
      final charsTotal = parts.fold<int>(0, (s, p) => s + p.length);
      Duration t = u.start;
      for (final p in parts) {
        final dur = Duration(
          microseconds: (total.inMicroseconds * p.length / charsTotal).round(),
        );
        result.add(DubbingSegment(id++, t, t + dur, p, speaker: u.speaker));
        t += dur;
      }
    }
  }
  return result;
}

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
  if (char != '.' && char != '!' && char != '?' && char != '\u2026') return false;
  if (i + 1 >= text.length) return true;
  if (text[i + 1] == ' ' && i + 2 < text.length && RegExp(r'[A-ZÀ-Ú]').hasMatch(text[i + 2])) {
    return true;
  }
  return false;
}
