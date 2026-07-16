import 'package:flutter/services.dart';
import 'package:dubbing_engine/dubbing_engine.dart';

/// Ponte para o `MediaProcessingService` (FFmpegKitNext, AT-3/D3.3) —
/// `omnitranslator/ffmpeg`. O engine é Dart puro e não conhece
/// `MethodChannel`; esta é a única casa onde esse canal aparece do lado
/// Dart. API provada no device pelo AT-3 (`docs/spikes-android/
/// at3-evidence/at3-bench-MainActivity.kt`, 13/13 casos PASSOU).
///
/// O handler Kotlin real mora no `MediaProcessingService` (D3.3) — o canal só
/// é alcançável de dentro do isolate/engine headless do serviço, não da
/// `MainActivity` (ver `smoke_ffmpeg_handler.kt.snippet`, superado por
/// `MediaProcessingService.kt`).
const _channel = MethodChannel('omnitranslator/ffmpeg');

/// As 4 closures cruas que `androidRuntime()` exige — extraídas à parte
/// (D3.3/D-5) porque tanto `createFFmpegKitNextRunner()` (usado hoje só nos
/// harnesses de smoke test) quanto o entrypoint do foreground service
/// (`service_entrypoint.dart`, que monta `androidRuntime()` diretamente)
/// precisam delas, e duplicar as chamadas de canal nos dois lugares
/// divergiria silenciosamente cedo ou tarde.
({
  FFmpegStartFn start,
  FFmpegPollFn poll,
  FFmpegCancelFn cancel,
  FfprobeFn ffprobe,
}) androidFFmpegCallbacks() => (
      start: (args) async {
        final r = await _channel
            .invokeMapMethod<String, dynamic>('ffmpegStart', {'args': args});
        return (r!['sessionId'] as num).toInt();
      },
      poll: (sessionId) async {
        final r = await _channel.invokeMapMethod<String, dynamic>(
            'ffmpegPoll', {'sessionId': sessionId});
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
        final r = await _channel
            .invokeMapMethod<String, dynamic>('ffprobe', {'args': args});
        return FfprobeResult((r?['returnCode'] as num?)?.toInt() ?? -1,
            r?['output'] as String? ?? '');
      },
    );

/// [FFmpegKitNextRunner] real do Android, ligado ao [_channel].
FFmpegKitNextRunner createFFmpegKitNextRunner() {
  final cb = androidFFmpegCallbacks();
  return FFmpegKitNextRunner(
    start: cb.start,
    poll: cb.poll,
    cancel: cb.cancel,
    ffprobe: cb.ffprobe,
  );
}
