import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omnitranslator_app/src/platform/android_storage.dart';

// Trava o contrato Dart<->Kotlin (nomes de método e chaves de argumento) —
// um typo de qualquer lado do MethodChannel só apareceria em runtime no
// device, sem esses testes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('omnitranslator/storage');

  MethodCall? lastCall;
  void mockHandler(Object? response) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      lastCall = call;
      return response;
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    lastCall = null;
  });

  group('createAndroidDiskSpaceProbe', () {
    test('chama getFreeBytes com o path certo e devolve o valor', () async {
      mockHandler(123456);
      final probe = createAndroidDiskSpaceProbe();
      final bytes = await probe.freeBytes('/storage/emulated/0/foo');
      expect(bytes, 123456);
      expect(lastCall?.method, 'getFreeBytes');
      expect(lastCall?.arguments, {'path': '/storage/emulated/0/foo'});
    });

    test('propaga null quando a plataforma não sabe responder', () async {
      mockHandler(null);
      final probe = createAndroidDiskSpaceProbe();
      expect(await probe.freeBytes('/x'), isNull);
    });
  });

  group('pickImportDocument', () {
    test('devolve a uri escolhida', () async {
      mockHandler({'uri': 'content://com.android.providers/document/1'});
      final uri = await pickImportDocument();
      expect(uri, 'content://com.android.providers/document/1');
      expect(lastCall?.method, 'pickImportDocument');
    });

    test('devolve null quando o usuário cancela', () async {
      mockHandler(null);
      expect(await pickImportDocument(), isNull);
    });
  });

  group('pickExportLocation', () {
    test('envia nome sugerido e mimeType, devolve a uri', () async {
      mockHandler({'uri': 'content://export/1'});
      final uri = await pickExportLocation(suggestedName: 'dubbed.mp4');
      expect(uri, 'content://export/1');
      expect(lastCall?.method, 'pickExportLocation');
      expect(lastCall?.arguments, {
        'suggestedName': 'dubbed.mp4',
        'mimeType': 'video/mp4',
      });
    });
  });

  group('copyUriToLocalFile / copyLocalFileToUri', () {
    test('copyUriToLocalFile envia uri+destPath e devolve bytesCopied', () async {
      mockHandler({'bytesCopied': 4096});
      final n = await copyUriToLocalFile('content://x', '/tmp/out.mp4');
      expect(n, 4096);
      expect(lastCall?.method, 'copyUriToFile');
      expect(lastCall?.arguments, {'uri': 'content://x', 'destPath': '/tmp/out.mp4'});
    });

    test('copyLocalFileToUri envia srcPath+uri e devolve bytesCopied', () async {
      mockHandler({'bytesCopied': 2048});
      final n = await copyLocalFileToUri('/tmp/in.mp4', 'content://y');
      expect(n, 2048);
      expect(lastCall?.method, 'copyFileToUri');
      expect(lastCall?.arguments, {'srcPath': '/tmp/in.mp4', 'uri': 'content://y'});
    });
  });
}
