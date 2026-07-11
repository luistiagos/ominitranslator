import 'dart:convert';
import 'dart:io';
import 'package:dubbing_engine/src/backends/translatelocally_translator.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/process_runner.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
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
            runToolOverride: (String exePath, List<String> args, List<int> stdinBytes,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              return _okResult('Olá\nMundo\r\n');
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
            runToolOverride: (String exePath, List<String> args, List<int> stdinBytes,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              callCount++;
              return _okResult(callCount == 1 ? 'Hello' : 'Hola');
            });

        // Offline-first: com a tradução funcionando, o download de modelos
        // (-d) não é invocado — só as 2 traduções do pivô.
        expect(callCount, 2);
        expect(result, ['Hola']);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('handles trailing newline in stdout', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);

        final result = await translator.translate(['Hello', 'World'], Lang.en, Lang.pt, CancellationToken(),
            runToolOverride: (String exePath, List<String> args, List<int> stdinBytes,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              return _okResult('Olá\nMundo\n');
            });

        expect(result, ['Olá', 'Mundo']);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('sends the input via stdin as UTF-8 bytes (accents intact)', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);

        List<int>? sentStdin;
        await translator.translate(['A ação não é fácil.'], Lang.pt, Lang.en, CancellationToken(),
            runToolOverride: (String exePath, List<String> args, List<int> stdinBytes,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              sentStdin = stdinBytes;
              return _okResult('The action is not easy.');
            });

        // Diferente do I/O por arquivo (-i/-o, encoding local), o stdin do
        // translateLocally é UTF-8 puro — acentos passam intactos como
        // bytes multi-byte, sem passar pelo encoding local do sistema.
        expect(sentStdin, utf8.encode('A ação não é fácil.\n'));
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('transliterates Serbian Cyrillic input to Latin before sending to hbs-eng-tiny', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);

        List<int>? sentStdin;
        String? modelId;
        await translator.translate(['Мачка спава на каучу.'], Lang.sr, Lang.en, CancellationToken(),
            runToolOverride: (String exePath, List<String> args, List<int> stdinBytes,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              modelId = args[args.indexOf('-m') + 1];
              sentStdin = stdinBytes;
              return _okResult('The cat sleeps on the couch.');
            });

        // hbs-eng-tiny só traduz corretamente sérvio em script latino —
        // testado empiricamente com o binário real (cirílico produz saída
        // sem sentido). A transliteração é sem perdas (alfabeto de Vuk
        // Karadžić).
        expect(modelId, 'hbs-eng-tiny');
        expect(utf8.decode(sentStdin!), 'Mačka spava na kauču.\n');
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('leaves Latin-script input for hr/bs untouched', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);

        List<int>? sentStdin;
        await translator.translate(['Mačka spava na kauču.'], Lang.hr, Lang.en, CancellationToken(),
            runToolOverride: (String exePath, List<String> args, List<int> stdinBytes,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              sentStdin = stdinBytes;
              return _okResult('The cat sleeps on the couch.');
            });

        expect(utf8.decode(sentStdin!), 'Mačka spava na kauču.\n');
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
            runToolOverride: (String exePath, List<String> args, List<int> stdinBytes,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              if (args.contains('-d')) downloadCalls.add(args.join(' '));
              return _okResult('Olá');
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
            runToolOverride: (String exePath, List<String> args, List<int> stdinBytes,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              translateCalls++;
              // 1ª tradução falha (modelo ausente); depois do -d, funciona.
              if (translateCalls == 1) return _failResult();
              return _okResult('Olá');
            },
            downloadOverride: (String exePath, List<String> args,
                {String? workingDirectory,
                Duration timeout = const Duration(minutes: 30),
                CancellationToken? token}) async {
              downloadCalls++;
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
              runToolOverride: (_, __, ___,
                  {String? workingDirectory,
                  Duration timeout = const Duration(minutes: 30),
                  CancellationToken? token}) async => _failResult(),
              downloadOverride: (_, __,
                  {String? workingDirectory,
                  Duration timeout = const Duration(minutes: 30),
                  CancellationToken? token}) async => _failResult()),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('throws when output line count differs from input', () async {
      final tempDir = Directory.systemTemp.createTempSync('trans_test_');
      try {
        final models = ModelManager(tempDir.path, _tools);
        final translator = TranslateLocallyTranslator(_tools, models);

        await expectLater(
          translator.translate(['Hello', 'World'], Lang.en, Lang.pt, CancellationToken(),
              runToolOverride: (String exePath, List<String> args, List<int> stdinBytes,
                  {String? workingDirectory,
                  Duration timeout = const Duration(minutes: 30),
                  CancellationToken? token}) async {
                return _okResult('Only one line');
              },
              downloadOverride: (_, __,
                  {String? workingDirectory,
                  Duration timeout = const Duration(minutes: 30),
                  CancellationToken? token}) async => _okResult()),
          throwsA(isA<PipelineException>()),
        );
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
