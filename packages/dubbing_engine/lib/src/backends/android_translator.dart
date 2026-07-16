import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:dubbing_engine/src/backends/interfaces.dart';
import 'package:dubbing_engine/src/model_manager.dart';
import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/steps/translation_postprocess.dart';

/// C-API do §10.3 da spec Android (`packages/dubbing_engine/tool/android/
/// slimt-patches/0003-ot-translator-capi.patch`, compilada direto no
/// `libslimt.so`). Handle opaco = `Pointer<Void>`.
typedef _OtTranslatorCreateNative = Pointer<Void> Function(
    Pointer<Utf8> configPath, Pointer<Pointer<Utf8>> error);
typedef _OtTranslatorCreateDart = Pointer<Void> Function(
    Pointer<Utf8> configPath, Pointer<Pointer<Utf8>> error);

typedef _OtTranslatorTranslateNative = Pointer<Utf8> Function(
    Pointer<Void> handle, Pointer<Utf8> source, Pointer<Pointer<Utf8>> error);
typedef _OtTranslatorTranslateDart = Pointer<Utf8> Function(
    Pointer<Void> handle, Pointer<Utf8> source, Pointer<Pointer<Utf8>> error);

typedef _OtStringFreeNative = Void Function(Pointer<Utf8> value);
typedef _OtStringFreeDart = void Function(Pointer<Utf8> value);

typedef _OtTranslatorFreeNative = Void Function(Pointer<Void> handle);
typedef _OtTranslatorFreeDart = void Function(Pointer<Void> handle);

/// Abstrai a C-API do slimt para permitir teste sem carregar o `.so` real
/// (ele só existe compilado para arm64 Android — não roda neste desktop).
abstract interface class SlimtBindings {
  /// Cria um tradutor a partir de um `configPath` (contrato interno do
  /// wrapper — texto UTF-8 de 2 linhas: path do model, path do vocabulary).
  /// Lança [StateError] com a mensagem de erro do slimt em caso de falha.
  Pointer<Void> create(String configPath);

  /// Traduz uma frase. Lança [StateError] em caso de falha.
  String translate(Pointer<Void> handle, String source);

  void free(Pointer<Void> handle);
}

class NativeSlimtBindings implements SlimtBindings {
  final DynamicLibrary _lib;
  late final _OtTranslatorCreateDart _create;
  late final _OtTranslatorTranslateDart _translate;
  late final _OtStringFreeDart _stringFree;
  late final _OtTranslatorFreeDart _translatorFree;

  /// [libraryPath] permite injeção em teste; em produção o `.so` já está
  /// no diretório de libs nativas do APK e resolve só pelo nome.
  NativeSlimtBindings({String? libraryPath})
      : _lib = DynamicLibrary.open(libraryPath ?? 'libslimt.so') {
    _create = _lib.lookupFunction<_OtTranslatorCreateNative, _OtTranslatorCreateDart>(
        'ot_translator_create');
    _translate = _lib.lookupFunction<_OtTranslatorTranslateNative, _OtTranslatorTranslateDart>(
        'ot_translator_translate');
    _stringFree =
        _lib.lookupFunction<_OtStringFreeNative, _OtStringFreeDart>('ot_string_free');
    _translatorFree = _lib.lookupFunction<_OtTranslatorFreeNative, _OtTranslatorFreeDart>(
        'ot_translator_free');
  }

  @override
  Pointer<Void> create(String configPath) {
    final configPathPtr = configPath.toNativeUtf8();
    final errorPtr = calloc<Pointer<Utf8>>();
    try {
      final handle = _create(configPathPtr, errorPtr);
      if (handle == nullptr) {
        throw StateError(_takeError(errorPtr) ?? 'ot_translator_create falhou sem mensagem');
      }
      return handle;
    } finally {
      calloc.free(configPathPtr);
      calloc.free(errorPtr);
    }
  }

  @override
  String translate(Pointer<Void> handle, String source) {
    final sourcePtr = source.toNativeUtf8();
    final errorPtr = calloc<Pointer<Utf8>>();
    try {
      final resultPtr = _translate(handle, sourcePtr, errorPtr);
      if (resultPtr == nullptr) {
        throw StateError(_takeError(errorPtr) ?? 'ot_translator_translate falhou sem mensagem');
      }
      final result = resultPtr.toDartString();
      _stringFree(resultPtr);
      return result;
    } finally {
      calloc.free(sourcePtr);
      calloc.free(errorPtr);
    }
  }

  @override
  void free(Pointer<Void> handle) => _translatorFree(handle);

  /// Lê e libera a mensagem de erro escrita em `*error_utf8`, se houver.
  String? _takeError(Pointer<Pointer<Utf8>> errorPtr) {
    final err = errorPtr.value;
    if (err == nullptr) return null;
    final message = err.toDartString();
    _stringFree(err);
    return message;
  }
}

/// Pares de tradução do Android M1 (§10 da spec — só en/pt/es). Diferente do
/// catálogo desktop (`translation_catalog.dart`, IDs do translateLocally):
/// aqui os IDs são os do `ModelCatalog.android()` (`mt-tiny-*`).
const _androidDirectModelId = <(Lang, Lang), String>{
  (Lang.en, Lang.pt): 'mt-tiny-enpt',
  (Lang.pt, Lang.en): 'mt-tiny-pten',
  (Lang.en, Lang.es): 'mt-tiny-enes',
  (Lang.es, Lang.en): 'mt-tiny-esen',
};

/// Sequência de pares a traduzir para ir de [from] a [to]: vazia se
/// from==to; um par se há modelo direto; dois pares (from→en, en→to) se
/// precisa pivotar (pt↔es, Android M1 não tem modelo direto). Lança
/// [ArgumentError] fora do escopo do M1 (en/pt/es).
List<(Lang, Lang)> androidTranslationPath(Lang from, Lang to) {
  if (from == to) return const [];
  if (_androidDirectModelId.containsKey((from, to))) return [(from, to)];
  if (from != Lang.en &&
      to != Lang.en &&
      _androidDirectModelId.containsKey((from, Lang.en)) &&
      _androidDirectModelId.containsKey((Lang.en, to))) {
    return [(from, Lang.en), (Lang.en, to)];
  }
  throw ArgumentError(
      'Android M1 só traduz en/pt/es; sem caminho entre ${from.code} e ${to.code}');
}

class AndroidTranslator implements Translator {
  final ModelManager models;
  final SlimtBindings bindings;
  final Map<String, Pointer<Void>> _handles = {};

  AndroidTranslator(this.models, {SlimtBindings? bindings})
      : bindings = bindings ?? NativeSlimtBindings();

  @override
  Future<List<String>> translate(
      List<String> sentences, Lang from, Lang to, CancellationToken token) async {
    if (from == to) return sentences;
    var current = sentences;
    for (final (f, t) in androidTranslationPath(from, to)) {
      current = await _translatePair(current, f, t, token);
    }
    return current;
  }

  Future<List<String>> _translatePair(
      List<String> sentences, Lang from, Lang to, CancellationToken token) async {
    final handle = _handleFor(from, to);
    final results = <String>[];
    for (final sentence in sentences) {
      if (token.isCancelled) {
        throw PipelineException(PipelineStage.translate, 'Cancelado pelo usuário');
      }
      final raw = bindings.translate(handle, sentence);
      // Obrigatório (§10.4/AT-1): o slimt decodifica guloso e sem EOS
      // confiável nestes modelos tiny — sem o dedup, pt→en produz "tradução
      // correta + eco" repetido (17/100 frases degeneradas no AT-1 cru).
      results.add(dedupRepeatedTail(raw));
    }
    return results;
  }

  Pointer<Void> _handleFor(Lang from, Lang to) {
    final key = '${from.code}-${to.code}';
    final cached = _handles[key];
    if (cached != null) return cached;
    final id = _androidDirectModelId[(from, to)]!;
    // Guard antes do FFI: sem ele, um modelo faltando viraria um erro
    // críptico de open() vindo do C++. (Sem download automático aqui — a UI
    // usa resolveRequiredIds pra garantir prontidão antes do job.)
    if (models.stateOf(id) != ModelState.ready) {
      throw StateError(
          'Modelo de tradução $id (${from.code}→${to.code}) não está pronto — '
          'baixe-o antes de dublar.');
    }
    final entry = models.catalog.entryOf(id)!;
    final modelPath = models.pathOf(id, entry.expects[0]);
    final vocabPath = models.pathOf(id, entry.expects[1]);
    final configPath = _writeConfig(id, modelPath, vocabPath);
    final handle = bindings.create(configPath);
    _handles[key] = handle;
    return handle;
  }

  /// Escreve o `config_path` que a C-API espera (contrato interno do
  /// wrapper — não normativo): 2 linhas, model e vocabulary. Um arquivo por
  /// par de idiomas, dentro do próprio diretório do modelo (sobrevive entre
  /// jobs, não precisa reescrever a cada tradução).
  String _writeConfig(String modelId, String modelPath, String vocabPath) {
    final dir = models.pathOf(modelId);
    Directory(dir).createSync(recursive: true);
    final configPath = p.join(dir, '.ot_translator_config');
    File(configPath).writeAsStringSync('$modelPath\n$vocabPath\n');
    return configPath;
  }

  /// Libera os handles nativos. Chamado ao fim do job — sem isto, cada
  /// modelo carregado (tiny ≈ 17 MB) vaza até o processo do serviço morrer.
  @override
  void dispose() {
    for (final handle in _handles.values) {
      bindings.free(handle);
    }
    _handles.clear();
  }
}
