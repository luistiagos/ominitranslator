import 'package:flutter/services.dart';
import 'package:dubbing_engine/dubbing_engine.dart';

/// Ponte para o `MediaProcessingService` (FFmpegKitNext, AT-3/D3.3) —
/// `omnitranslator/ffmpeg`. O engine é Dart puro e não conhece
/// `MethodChannel`; esta é a única casa onde esse canal aparece do lado
/// Dart. API provada no device pelo AT-3 (`docs/spikes-android/
/// at3-evidence/at3-bench-MainActivity.kt`, 13/13 casos PASSOU).
const _channel = MethodChannel('omnitranslator/ffmpeg');

/// [FFmpegKitNextRunner] real do Android, ligado ao [_channel].
FFmpegKitNextRunner createFFmpegKitNextRunner() {
  return FFmpegKitNextRunner(
    start: (args) async {
      final r = await _channel.invokeMapMethod<String, dynamic>('ffmpegStart', {'args': args});
      return (r!['sessionId'] as num).toInt();
    },
    poll: (sessionId) async {
      final r = await _channel
          .invokeMapMethod<String, dynamic>('ffmpegPoll', {'sessionId': sessionId});
      return FFmpegPollResult(
        returnCode: (r?['returnCode'] as num?)?.toInt(),
        logsTail: r?['logsTail'] as String? ?? '',
        statTimeMs: (r?['statTimeMs'] as num?)?.toDouble(),
      );
    },
    cancel: (sessionId) async {
      await _channel.invokeMethod('ffmpegCancel', {'sessionId': sessionId});
    },
    ffprobe: (args) async {
      final r = await _channel.invokeMapMethod<String, dynamic>('ffprobe', {'args': args});
      return FfprobeResult((r?['returnCode'] as num?)?.toInt() ?? -1, r?['output'] as String? ?? '');
    },
  );
}
