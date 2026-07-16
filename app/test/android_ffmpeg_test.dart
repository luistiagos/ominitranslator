import 'package:dubbing_engine/dubbing_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnitranslator_app/src/platform/android_ffmpeg.dart';

// Trava o contrato Dart<->Kotlin (nomes de método e chaves de argumento) —
// mesmo padrão de android_storage_test.dart. O handler Kotlin real mora no
// MediaProcessingService (D3.3), ainda não escrito; isto só garante que o
// lado Dart chama exatamente o que o AT-3 provou no device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('omnitranslator/ffmpeg');

  final calls = <MethodCall>[];
  void mockHandler(Map<String, Object?> Function(MethodCall call) responseFor) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return responseFor(call);
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    calls.clear();
  });

  group('createFFmpegKitNextRunner', () {
    test('ffmpegStart envia args, ffmpegPoll lê returnCode/logsTail/statTimeMs', () async {
      var pollCount = 0;
      mockHandler((call) {
        switch (call.method) {
          case 'ffmpegStart':
            return {'sessionId': 42};
          case 'ffmpegPoll':
            pollCount++;
            // primeiro poll: ainda rodando; segundo: terminou.
            return pollCount == 1
                ? {'statTimeMs': 500.0}
                : {'returnCode': 0, 'logsTail': 'ok', 'statTimeMs': 1000.0};
          default:
            throw StateError('método inesperado: ${call.method}');
        }
      });
      final runner = createFFmpegKitNextRunner();
      final result = await runner.run(MediaTool.ffmpeg, ['-i', 'in.mp4']);

      expect(calls.first.method, 'ffmpegStart');
      expect(calls.first.arguments, {
        'args': ['-i', 'in.mp4']
      });
      expect(calls.where((c) => c.method == 'ffmpegPoll').first.arguments, {'sessionId': 42});
      expect(result.exitCode, 0);
      expect(result.stderrTail, 'ok');
    });

    test('ffmpegCancel envia o sessionId certo', () async {
      final token = CancellationToken();
      mockHandler((call) {
        switch (call.method) {
          case 'ffmpegStart':
            return {'sessionId': 7};
          case 'ffmpegPoll':
            if (!token.isCancelled) token.cancel();
            return {'returnCode': 255};
          case 'ffmpegCancel':
            return {};
          default:
            throw StateError('método inesperado: ${call.method}');
        }
      });
      final runner = createFFmpegKitNextRunner();
      await runner.run(MediaTool.ffmpeg, ['-i', 'in.mp4'], token: token);
      final cancelCall = calls.firstWhere((c) => c.method == 'ffmpegCancel');
      expect(cancelCall.arguments, {'sessionId': 7});
    });

    test('ffprobe envia args e devolve returnCode/output', () async {
      mockHandler((call) {
        expect(call.method, 'ffprobe');
        return {'returnCode': 0, 'output': '{"format":{}}'};
      });
      final runner = createFFmpegKitNextRunner();
      final result = await runner.run(MediaTool.ffprobe, ['-show_format']);
      expect(calls.single.method, 'ffprobe');
      expect(calls.single.arguments, {
        'args': ['-show_format']
      });
      expect(result.exitCode, 0);
      expect(result.stdout, '{"format":{}}');
    });
  });
}
