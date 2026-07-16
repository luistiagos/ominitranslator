import 'dart:ffi';
import 'dart:io';
import 'package:dubbing_engine/src/backends/android_translator.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/tools/tool_locator.dart';
import 'package:test/test.dart';

final _tools = Tools(
  ffmpeg: 'ffmpeg',
  ffprobe: 'ffprobe',
  whisperCli: 'whisper-cli',
  translateLocally: 'translateLocally',
  sherpaSourceSeparation: 'sherpa-separation',
);

/// Handles falsos: cada "criação" devolve um Pointer<Void> distinto
/// (derivado de um contador), sem tocar libslimt.so de verdade — ele só
/// existe compilado pra arm64 Android.
class FakeSlimtBindings implements SlimtBindings {
  int _nextAddress = 1;
  final List<String> createdConfigPaths = [];
  final List<(Pointer<Void>, String)> translateCalls = [];
  final Set<int> freed = {};
  String Function(String source)? onTranslate;
  bool throwOnCreate = false;

  @override
  Pointer<Void> create(String configPath) {
    if (throwOnCreate) throw StateError('create falhou (forçado no teste)');
    createdConfigPaths.add(configPath);
    return Pointer<Void>.fromAddress(_nextAddress++);
  }

  @override
  String translate(Pointer<Void> handle, String source) {
    translateCalls.add((handle, source));
    return onTranslate?.call(source) ?? source.toUpperCase();
  }

  @override
  void free(Pointer<Void> handle) => freed.add(handle.address);
}

void main() {
  group('androidTranslationPath', () {
    test('empty when from == to', () {
      expect(androidTranslationPath(Lang.en, Lang.en), isEmpty);
    });

    test('direct path for en<->pt and en<->es', () {
      expect(androidTranslationPath(Lang.en, Lang.pt), [(Lang.en, Lang.pt)]);
      expect(androidTranslationPath(Lang.pt, Lang.en), [(Lang.pt, Lang.en)]);
      expect(androidTranslationPath(Lang.en, Lang.es), [(Lang.en, Lang.es)]);
      expect(androidTranslationPath(Lang.es, Lang.en), [(Lang.es, Lang.en)]);
    });

    test('pivots through en for pt<->es (Android M1 has no direct model)', () {
      expect(androidTranslationPath(Lang.pt, Lang.es), [(Lang.pt, Lang.en), (Lang.en, Lang.es)]);
      expect(androidTranslationPath(Lang.es, Lang.pt), [(Lang.es, Lang.en), (Lang.en, Lang.pt)]);
    });

    test('throws for languages outside Android M1 scope', () {
      expect(() => androidTranslationPath(Lang.en, Lang.de), throwsArgumentError);
    });
  });

  group('AndroidTranslator', () {
    late Directory tempDir;
    late ModelManager models;
    late FakeSlimtBindings bindings;
    late AndroidTranslator translator;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('android_translator_test_');
      models = ModelManager(tempDir.path, _tools, catalog: ModelCatalog.android());
      // Materializa os modelos mt-tiny-* como "prontos" (expects + .sha256):
      // o guard de prontidão do _handleFor roda ANTES do FFI e barraria
      // qualquer tradução com os modelos ausentes.
      for (final id in ['mt-tiny-enpt', 'mt-tiny-pten', 'mt-tiny-enes', 'mt-tiny-esen']) {
        final entry = models.catalog.entryOf(id)!;
        final dir = Directory(models.pathOf(id))..createSync(recursive: true);
        for (final f in entry.expects) {
          File(models.pathOf(id, f)).writeAsStringSync('fake');
        }
        File('${dir.path}${Platform.pathSeparator}.sha256').writeAsStringSync('fake');
      }
      bindings = FakeSlimtBindings();
      translator = AndroidTranslator(models, bindings: bindings);
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('returns the same sentences when from == to, without touching bindings', () async {
      final result =
          await translator.translate(['Hello'], Lang.en, Lang.en, CancellationToken());
      expect(result, ['Hello']);
      expect(bindings.createdConfigPaths, isEmpty);
    });

    test('translates directly (en->pt) and applies dedupRepeatedTail', () async {
      // Mesmo caso de eco (sentença repetida inteira) do
      // translation_postprocess_test.dart — o slimt cru produz isto no
      // pt->en real (AT-1 §6.1); o backend precisa cortar antes de devolver.
      bindings.onTranslate = (s) => 'I would like a cup of coffee. I would like a cup of coffee.';
      final result =
          await translator.translate(['Hello'], Lang.en, Lang.pt, CancellationToken());
      expect(result, ['I would like a cup of coffee.']);
    });

    test('writes a 2-line config file (model path, vocab path) for the pair', () async {
      await translator.translate(['Hello'], Lang.en, Lang.pt, CancellationToken());
      expect(bindings.createdConfigPaths, hasLength(1));
      final lines = File(bindings.createdConfigPaths.single).readAsLinesSync();
      expect(lines, hasLength(2));
      expect(lines[0], contains('model.enpt.intgemm.alphas.bin'));
      expect(lines[1], contains('vocab.enpt.spm'));
    });

    test('reuses the same handle across calls for the same language pair', () async {
      await translator.translate(['A'], Lang.en, Lang.pt, CancellationToken());
      await translator.translate(['B'], Lang.en, Lang.pt, CancellationToken());
      expect(bindings.createdConfigPaths, hasLength(1)); // create() só uma vez
      expect(bindings.translateCalls, hasLength(2));
      expect(bindings.translateCalls[0].$1, bindings.translateCalls[1].$1); // mesmo handle
    });

    test('pivots pt->es through en, calling translate for both hops', () async {
      bindings.onTranslate = (s) => '[$s]';
      final result =
          await translator.translate(['Olá'], Lang.pt, Lang.es, CancellationToken());
      expect(result, ['[[Olá]]']);
      expect(bindings.translateCalls, hasLength(2));
    });

    test('translates a batch, preserving order', () async {
      final result = await translator
          .translate(['a', 'b', 'c'], Lang.en, Lang.pt, CancellationToken());
      expect(result, ['A', 'B', 'C']);
    });

    test('throws PipelineException when the token is already cancelled', () async {
      final token = CancellationToken()..cancel();
      expect(
        () => translator.translate(['Hello'], Lang.en, Lang.pt, token),
        throwsA(isA<PipelineException>()
            .having((e) => e.stage, 'stage', PipelineStage.translate)),
      );
    });

    test('propagates errors from bindings.create as StateError', () async {
      bindings.throwOnCreate = true;
      expect(
        () => translator.translate(['Hello'], Lang.en, Lang.pt, CancellationToken()),
        throwsStateError,
      );
    });

    test('throws a clear StateError when the model is not ready (guard before FFI)', () async {
      Directory(models.pathOf('mt-tiny-enpt')).deleteSync(recursive: true);
      expect(
        () => translator.translate(['Hello'], Lang.en, Lang.pt, CancellationToken()),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('mt-tiny-enpt'))),
      );
      expect(bindings.createdConfigPaths, isEmpty); // nunca chegou no FFI
    });

    test('dispose() frees every cached handle', () async {
      await translator.translate(['A'], Lang.en, Lang.pt, CancellationToken());
      await translator.translate(['A'], Lang.en, Lang.es, CancellationToken());
      translator.dispose();
      expect(bindings.freed, hasLength(2));
    });
  });
}
