import 'package:dubbing_engine/src/models.dart';
import 'package:dubbing_engine/src/translation_catalog.dart';
import 'package:test/test.dart';

void main() {
  group('translation_catalog', () {
    test('every language other than en has a direct X->en model', () {
      for (final lang in Lang.values) {
        if (lang == Lang.en) continue;
        expect(directTranslationModelId(lang, Lang.en), isNotNull,
            reason: '${lang.code}->en');
      }
    });

    test('every dub target has a direct en->X model', () {
      for (final lang in Lang.values) {
        if (!lang.isDubTarget || lang == Lang.en) continue;
        expect(directTranslationModelId(Lang.en, lang), isNotNull,
            reason: 'en->${lang.code}');
      }
    });

    test('translationPath is empty when from == to', () {
      expect(translationPath(Lang.pt, Lang.pt), isEmpty);
    });

    test('translationPath is direct for en<->pt', () {
      expect(translationPath(Lang.en, Lang.pt), [(Lang.en, Lang.pt)]);
      expect(translationPath(Lang.pt, Lang.en), [(Lang.pt, Lang.en)]);
    });

    test('translationPath pivots through en for pt->es', () {
      expect(translationPath(Lang.pt, Lang.es),
          [(Lang.pt, Lang.en), (Lang.en, Lang.es)]);
    });

    test('translationPath pivots for a source-only language to a dub target', () {
      expect(translationPath(Lang.ca, Lang.pt),
          [(Lang.ca, Lang.en), (Lang.en, Lang.pt)]);
    });

    test('translationPath throws when there is no path (source-only to source-only)', () {
      expect(() => translationPath(Lang.ca, Lang.tr), throwsArgumentError);
    });

    test('canTranslate matches translationPath success/failure', () {
      expect(canTranslate(Lang.pt, Lang.pt), isFalse);
      expect(canTranslate(Lang.de, Lang.en), isTrue);
      expect(canTranslate(Lang.uk, Lang.pt), isTrue);
      expect(canTranslate(Lang.ca, Lang.tr), isFalse);
    });

    test('hr/sr/bs share the same macrolanguage model id', () {
      final id = directTranslationModelId(Lang.hr, Lang.en);
      expect(id, 'hbs-eng-tiny');
      expect(directTranslationModelId(Lang.sr, Lang.en), id);
      expect(directTranslationModelId(Lang.bs, Lang.en), id);
    });

    test('Lang.isl uses code "is" (is is a reserved word in Dart)', () {
      expect(Lang.isl.code, 'is');
      expect(Lang.isl.whisperCode, 'is');
    });

    test('Lang.nb whisper code is "no", not "nb"', () {
      expect(Lang.nb.code, 'nb');
      expect(Lang.nb.whisperCode, 'no');
    });

    test('whisperCode defaults to code for languages without an override', () {
      for (final lang in Lang.values) {
        if (lang == Lang.nb) continue;
        expect(lang.whisperCode, lang.code, reason: lang.name);
      }
    });

    test('iso639_2 spot checks', () {
      expect(Lang.de.iso639_2, 'deu');
      expect(Lang.uk.iso639_2, 'ukr');
      expect(Lang.isl.iso639_2, 'isl');
      expect(Lang.nb.iso639_2, 'nob');
    });
  });
}
