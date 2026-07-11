import 'dart:convert';
import 'dart:io';
import 'package:dubbing_engine/src/backends/translatelocally_translator.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ToolResult _okResult([String stdout = '']) => ToolResult(0, stdout, '');
ToolResult _failResult() => ToolResult(1, '', 'error');

final _tools = Tools(
  ffmpeg: 'ffmpeg',
  ffprobe: 'ffprobe',
  whisperCli: 'whisper-cli',
  translateLocally: 'translateLocally',
  sherpaSourceSeparation: 'sherpa-separation',
);

void main() {
  group('TranslateLocallyTranslator', () {
    test('returns same sentences when from == to', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);
        final result = await translator.translate(['Hello'], Lang.en, Lang.en, CancellationToken());
        expect(result, ['Hello']);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('translates directly when no pivot needed', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);

        final result = await translator.translate(['Hello', 'World'], Lang.en, Lang.pt, CancellationToken(),
            runToolOverride: (String exePath, List<String> args,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              // Grava a saída em encoding LOCAL (cp1252 no Windows), como o
              // translateLocally real faz — verificado empiricamente.
              final dstIdx = args.indexOf('-o');
              if (dstIdx >= 0 && dstIdx + 1 < args.length) {
                final dstFile = args[dstIdx + 1];
                File(dstFile).writeAsBytesSync(systemEncoding.encode('Olá\nMundo'));
              }
              return _okResult();
            });

        expect(result, ['Olá', 'Mundo']);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('translates via pivot for pt->es', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);

        var callCount = 0;
        final result = await translator.translate(['Olá'], Lang.pt, Lang.es, CancellationToken(),
            runToolOverride: (String exePath, List<String> args,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              callCount++;
              final dstIdx = args.indexOf('-o');
              if (dstIdx >= 0 && dstIdx + 1 < args.length) {
                final dstFile = args[dstIdx + 1];
                if (callCount == 1) {
                  File(dstFile).writeAsStringSync('Hello');
                } else {
                  File(dstFile).writeAsStringSync('Hola');
                }
              }
              return _okResult();
            });

        // Offline-first: com a tradução funcionando, o download de modelos
        // (-d) não é invocado — só as 2 traduções do pivô.
        expect(callCount, 2);
        expect(result, ['Hola']);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('handles trailing newline in output file (real translateLocally behavior)', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);

        final result = await translator.translate(['Hello', 'World'], Lang.en, Lang.pt, CancellationToken(),
            runToolOverride: (String exePath, List<String> args,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              final dstIdx = args.indexOf('-o');
              if (dstIdx >= 0 && dstIdx + 1 < args.length) {
                final dstFile = args[dstIdx + 1];
                // Builds que emitam UTF-8 também precisam funcionar.
                File(dstFile).writeAsBytesSync(utf8.encode('Olá\nMundo\n'));
              }
              return _okResult();
            });

        expect(result, ['Olá', 'Mundo']);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('writes the input file in the system encoding (accents intact)', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);

        List<int>? srcBytes;
        await translator.translate(['A ação não é fácil.'], Lang.pt, Lang.en, CancellationToken(),
            runToolOverride: (String exePath, List<String> args,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              final srcIdx = args.indexOf('-i');
              if (srcIdx >= 0) {
                srcBytes = File(args[srcIdx + 1]).readAsBytesSync();
              }
              final dstIdx = args.indexOf('-o');
              if (dstIdx >= 0) {
                File(args[dstIdx + 1]).writeAsStringSync('The action is not easy.');
              }
              return _okResult();
            });

        // O translateLocally lê no encoding do sistema: entrada UTF-8 com
        // acentos corrompe a tradução ("fão", "aão").
        expect(srcBytes, systemEncoding.encode('A ação não é fácil.'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('does not download models when translation succeeds (offline-first)', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);

        final downloadCalls = <String>[];
        await translator.translate(['Hello'], Lang.en, Lang.pt, CancellationToken(),
            runToolOverride: (String exePath, List<String> args,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              if (args.contains('-d')) downloadCalls.add(args.join(' '));
              final dstIdx = args.indexOf('-o');
              if (dstIdx >= 0 && dstIdx + 1 < args.length) {
                File(args[dstIdx + 1]).writeAsStringSync('Olá');
              }
              return _okResult();
            });

        expect(downloadCalls, isEmpty);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('downloads models and retries once when translation fails first', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);

        var translateCalls = 0;
        var downloadCalls = 0;
        final result = await translator.translate(['Hello'], Lang.en, Lang.pt, CancellationToken(),
            runToolOverride: (String exePath, List<String> args,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              if (args.contains('-d')) {
                downloadCalls++;
                return _okResult();
              }
              translateCalls++;
              // 1ª tradução falha (modelo ausente); depois do -d, funciona.
              if (translateCalls == 1) return _failResult();
              final dstIdx = args.indexOf('-o');
              if (dstIdx >= 0 && dstIdx + 1 < args.length) {
                File(args[dstIdx + 1]).writeAsStringSync('Olá');
              }
              return _okResult();
            });

        expect(result, ['Olá']);
        expect(downloadCalls, 1);
        expect(translateCalls, 2);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('throws when translateLocally fails', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);

        await expectLater(
          translator.translate(['Hello'], Lang.en, Lang.pt, CancellationToken(),
              runToolOverride: (_, __,
                  {String? workingDirectory,
                  Duration timeout = const Duration(minutes: 30),
                  CancellationToken? token}) async => _failResult()),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('throws when output file line count differs from input', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);

        await expectLater(
          translator.translate(['Hello', 'World'], Lang.en, Lang.pt, CancellationToken(),
              runToolOverride: (String exePath, List<String> args,
                  {String? workingDirectory,
                  Duration timeout = const Duration(minutes: 30),
                  CancellationToken? token}) async {
                final dstIdx = args.indexOf('-o');
                if (dstIdx >= 0 && dstIdx + 1 < args.length) {
                  File(args[dstIdx + 1]).writeAsStringSync('Only one line');
                }
                return _okResult();
              }),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
