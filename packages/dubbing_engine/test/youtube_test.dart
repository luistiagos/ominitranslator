import 'dart:io';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/steps/youtube.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ToolResult _okResult() => ToolResult(0, '', '');

void main() {
  group('downloadFromYoutube', () {
    test('does not pass cookie flags when none are configured', () async {
      final tempDir = Directory.systemTemp.createTempSync('yt_test_');
      try {
        List<String>? capturedArgs;
        final RunToolFn mock = (exePath, args,
            {workingDirectory, timeout = const Duration(minutes: 30), token}) async {
          capturedArgs = args;
          File(p.join(tempDir.path, 'input.mp4')).writeAsBytesSync([1]);
          return _okResult();
        };

        await downloadFromYoutube(
            'https://youtube.com/watch?v=abc', tempDir.path, 'yt-dlp', CancellationToken(),
            runToolOverride: mock);

        expect(capturedArgs, isNot(contains('--cookies')));
        expect(capturedArgs, isNot(contains('--cookies-from-browser')));
        expect(capturedArgs, contains('--no-playlist'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('accepts a WebM download (format fallback "best")', () async {
      final tempDir = Directory.systemTemp.createTempSync('yt_test_');
      try {
        final RunToolFn mock = (exePath, args,
            {workingDirectory, timeout = const Duration(minutes: 30), token}) async {
          File(p.join(tempDir.path, 'input.webm')).writeAsBytesSync([1]);
          return _okResult();
        };

        final path = await downloadFromYoutube(
            'https://youtube.com/watch?v=abc', tempDir.path, 'yt-dlp', CancellationToken(),
            runToolOverride: mock);

        expect(path, endsWith('input.webm'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('locked browser cookies produce a friendly error', () async {
      final tempDir = Directory.systemTemp.createTempSync('yt_test_');
      try {
        final RunToolFn mock = (exePath, args,
            {workingDirectory, timeout = const Duration(minutes: 30), token}) async {
          return ToolResult(1, '',
              'ERROR: Could not copy Chrome cookie database. See ... for more info');
        };

        await expectLater(
          downloadFromYoutube(
              'https://youtube.com/watch?v=abc', tempDir.path, 'yt-dlp', CancellationToken(),
              runToolOverride: mock, cookiesFromBrowser: 'edge'),
          throwsA(isA<PipelineException>().having(
            (e) => e.message,
            'message',
            contains('Feche o navegador'),
          )),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('passes --cookies-from-browser when configured', () async {
      final tempDir = Directory.systemTemp.createTempSync('yt_test_');
      try {
        List<String>? capturedArgs;
        final RunToolFn mock = (exePath, args,
            {workingDirectory, timeout = const Duration(minutes: 30), token}) async {
          capturedArgs = args;
          File(p.join(tempDir.path, 'input.mp4')).writeAsBytesSync([1]);
          return _okResult();
        };

        await downloadFromYoutube(
            'https://youtube.com/watch?v=abc', tempDir.path, 'yt-dlp', CancellationToken(),
            runToolOverride: mock, cookiesFromBrowser: 'edge');

        final idx = capturedArgs!.indexOf('--cookies-from-browser');
        expect(idx, greaterThanOrEqualTo(0));
        expect(capturedArgs![idx + 1], 'edge');
        expect(capturedArgs, isNot(contains('--cookies')));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('cookies file takes priority over cookies-from-browser', () async {
      final tempDir = Directory.systemTemp.createTempSync('yt_test_');
      try {
        List<String>? capturedArgs;
        final RunToolFn mock = (exePath, args,
            {workingDirectory, timeout = const Duration(minutes: 30), token}) async {
          capturedArgs = args;
          File(p.join(tempDir.path, 'input.mp4')).writeAsBytesSync([1]);
          return _okResult();
        };

        await downloadFromYoutube(
            'https://youtube.com/watch?v=abc', tempDir.path, 'yt-dlp', CancellationToken(),
            runToolOverride: mock,
            cookiesFromBrowser: 'edge',
            cookiesFile: 'C:\\cookies.txt');

        final idx = capturedArgs!.indexOf('--cookies');
        expect(idx, greaterThanOrEqualTo(0));
        expect(capturedArgs![idx + 1], 'C:\\cookies.txt');
        expect(capturedArgs, isNot(contains('--cookies-from-browser')));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
