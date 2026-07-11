import 'package:dubbing_engine/src/models.dart';

String _formatSrtTimestamp(Duration d) {
  final h = d.inHours.toString().padLeft(2, '0');
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
  return '$h:$m:$s,$ms';
}

String buildSrtContent(List<DubbingSegment> segments, bool useSource) {
  final buf = StringBuffer();
  for (int i = 0; i < segments.length; i++) {
    final seg = segments[i];
    final text = useSource ? seg.sourceText : seg.translatedText;
    buf.writeln('${i + 1}');
    buf.writeln('${_formatSrtTimestamp(seg.start)} --> ${_formatSrtTimestamp(seg.end)}');
    buf.writeln(text);
    buf.writeln();
  }
  return buf.toString();
}
