import 'dart:io';

import 'package:dubbing_engine/src/runtime/disk_space_probe.dart';
import 'package:test/test.dart';

void main() {
  group('FixedDiskSpaceProbe', () {
    test('devolve sempre o valor configurado', () async {
      const probe = FixedDiskSpaceProbe(1234);
      expect(await probe.freeBytes(r'C:\qualquer'), 1234);
      expect(await probe.freeBytes('/outro/path'), 1234);
    });

    test('null significa "não dá para saber"', () async {
      const probe = FixedDiskSpaceProbe(null);
      expect(await probe.freeBytes('/x'), isNull);
    });
  });

  group('WindowsDiskSpaceProbe', () {
    test('mede o volume do path no Windows; null fora dele', () async {
      const probe = WindowsDiskSpaceProbe();
      final bytes = await probe.freeBytes(Directory.systemTemp.path);
      if (Platform.isWindows) {
        expect(bytes, isNotNull);
        expect(bytes, greaterThan(0));
      } else {
        expect(bytes, isNull);
      }
    });

    test('path inexistente não lança — devolve null ou o volume', () async {
      const probe = WindowsDiskSpaceProbe();
      // Não deve explodir: a UI compartilhada consulta paths que o usuário
      // ainda nem criou.
      await expectLater(probe.freeBytes(r'Z:\nao\existe'), completes);
    });
  });
}
