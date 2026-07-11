import 'package:dubbing_engine/src/models.dart';

/// Modelos DIRETOS do translateLocally (catálogo oficial, verificado via
/// `translateLocally -a`/`-l`). Pares sem entrada aqui são traduzidos via
/// pivô em inglês — ver [translationPath].
const translationModels = <(Lang, Lang), String>{
  // en → X (línguas-alvo de dublagem).
  (Lang.en, Lang.pt): 'en-pt-base',
  (Lang.en, Lang.es): 'en-es-tiny',
  (Lang.en, Lang.de): 'en-de-base',
  (Lang.en, Lang.fr): 'en-fr-tiny',
  (Lang.en, Lang.pl): 'en-pl-tiny',
  (Lang.en, Lang.cs): 'en-cs-base',
  (Lang.en, Lang.bg): 'en-bg-tiny',
  (Lang.en, Lang.et): 'en-et-tiny',
  // X → en (todas as línguas de origem, incl. as línguas-alvo acima).
  (Lang.pt, Lang.en): 'pt-en-base',
  (Lang.es, Lang.en): 'es-en-tiny',
  (Lang.de, Lang.en): 'de-en-base',
  (Lang.fr, Lang.en): 'fr-en-tiny',
  (Lang.pl, Lang.en): 'pl-en-tiny',
  (Lang.cs, Lang.en): 'cs-en-base',
  (Lang.bg, Lang.en): 'bg-en-tiny',
  (Lang.ca, Lang.en): 'ca-en-tiny',
  (Lang.el, Lang.en): 'el-en-tiny',
  (Lang.et, Lang.en): 'et-en-tiny',
  // Croata/sérvio/bósnio compartilham o mesmo modelo (macrolíngua
  // sérvio-croata no catálogo do translateLocally).
  (Lang.hr, Lang.en): 'hbs-eng-tiny',
  (Lang.sr, Lang.en): 'hbs-eng-tiny',
  (Lang.bs, Lang.en): 'hbs-eng-tiny',
  (Lang.isl, Lang.en): 'is-en-base',
  (Lang.mk, Lang.en): 'mk-en-tiny',
  (Lang.mt, Lang.en): 'mt-en-tiny',
  (Lang.nb, Lang.en): 'nb-en-tiny',
  (Lang.nn, Lang.en): 'nn-en-tiny',
  (Lang.sl, Lang.en): 'sl-en-tiny',
  (Lang.sq, Lang.en): 'sq-en-tiny',
  (Lang.tr, Lang.en): 'tr-en-tiny',
  (Lang.uk, Lang.en): 'uk-en-tiny',
};

/// ID do modelo do translateLocally para a direção direta [from]→[to], ou
/// null se não existe tradução direta (precisa de pivô — ver [translationPath]).
String? directTranslationModelId(Lang from, Lang to) => translationModels[(from, to)];

/// Sequência de pares (from,to) a traduzir em ordem para ir de [from] a
/// [to]: vazia se from==to; um par se há modelo direto; dois pares
/// (from→en, en→to) se precisa pivotar pelo inglês (nenhum idioma além do
/// inglês tem modelo direto para outro). Lança [ArgumentError] se não
/// existe nenhum caminho de tradução.
List<(Lang, Lang)> translationPath(Lang from, Lang to) {
  if (from == to) return const [];
  if (directTranslationModelId(from, to) != null) return [(from, to)];
  if (from != Lang.en &&
      to != Lang.en &&
      directTranslationModelId(from, Lang.en) != null &&
      directTranslationModelId(Lang.en, to) != null) {
    return [(from, Lang.en), (Lang.en, to)];
  }
  throw ArgumentError('Nenhum caminho de tradução entre ${from.code} e ${to.code}');
}

/// true se existe caminho de tradução (direto ou via pivô) entre [from] e
/// [to], com from != to.
bool canTranslate(Lang from, Lang to) {
  if (from == to) return false;
  try {
    translationPath(from, to);
    return true;
  } on ArgumentError {
    return false;
  }
}
