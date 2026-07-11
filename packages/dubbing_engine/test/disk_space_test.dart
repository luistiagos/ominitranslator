import 'dart:io';
import 'package:dubbing_engine/src/tools/disk_space.dart';
import 'package:test/test.dart';

void main() {
  group('disk_space', () {
    test('freeBytesForPath returns a positive value for an existing path', () {
      final bytes = freeBytesForPath(Directory.systemTemp.path);
      if (Platform.isWindows) {
        expect(bytes, isNotNull);
        expect(bytes!, greaterThan(0));
      } else {
        expect(bytes, isNull);
      }
    });

    test('driveOf returns the root prefix of the path', () {
      if (Platform.isWindows) {
        expect(driveOf(r'C:\Users\foo\bar'), r'C:\');
      }
    });
  });
}
