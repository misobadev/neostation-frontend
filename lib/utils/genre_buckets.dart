/// Normalization of freeform scraper genre strings into a small, stable set of
/// buckets the Discovery genre shelves are built from.
///
/// Kept pure and dependency-free so the keyword table can be tested directly.
///
/// The stored genre is a single freeform TEXT column written by the scraper,
/// **localized to the user's ScreenScraper language** — the same game reads
/// `Plate-forme` for a French user and `Plattform` for a German one, and a
/// re-scrape in another language reshuffles every bucket. That is why picks
/// persist by `rom_path` rather than by bucket: the current week's board
/// survives a language change even though the shelves it was built from would
/// be computed differently afterwards.
///
/// Values also arrive compounded (`Action / Aventure`, `Action-RPG`,
/// `Shoot'em up > Vertical`), so matching works on fragments rather than on the
/// whole string, and the keyword table is ordered most-specific-first: the
/// first bucket with a matching fragment wins, which is what makes
/// `Action-RPG` an RPG instead of an action game.
library;

/// The buckets a genre string can normalize to.
///
/// Declaration order is meaningful beyond the values themselves: the weekly
/// genre shelf line-up breaks candidate-count ties by enum index, so it is a
/// deterministic priority order. Append rather than reorder.
enum GenreBucket {
  platform,
  rpg,
  shooter,
  fighting,
  racing,
  puzzle,
  sports,
  adventure,
  strategy,
  simulation,
  action,
  other,
  beatEmUp,
  shootEmUp,
  musicRhythm,
  boardCard,
  pinball,
  educational,
  quiz,
  compilation,
}

/// One bucket and the keywords that select it, in match priority order.
class _BucketKeywords {
  const _BucketKeywords(this.bucket, this.keywords);

  final GenreBucket bucket;

  /// Space-normalized, diacritic-free keywords. A keyword matches when it
  /// appears in a fragment at the start of a word, so `platform` also catches
  /// `platformer` and `platforms` without `rol` catching `control`.
  final List<String> keywords;
}

/// Ordered most-specific-first: whichever entry matches a fragment first wins.
///
/// Covers the ScreenScraper genre names for the six languages it scrapes in
/// (en/fr/de/es/it/pt). Compound genres are split before matching, so the
/// keywords here are single fragments (`plate` for `Plate-forme`, whose hyphen
/// is a separator).
const List<_BucketKeywords> _bucketKeywords = [
  // RPG first: `Action-RPG` and `Action / Jeu de rôle` must not read as action.
  _BucketKeywords(GenreBucket.rpg, [
    'rpg',
    'jrpg',
    'role',
    'rol',
    'rollenspiel',
    'ruolo',
    'jdr',
    'interpretacao',
    'dungeon',
    'roguelike',
    'rogue',
  ]),
  // Beat 'em ups are their own shelf, and must be matched before the broader
  // fighting keywords below (`Beat 'em up` used to fall into fighting).
  _BucketKeywords(GenreBucket.beatEmUp, [
    'beat em up',
    'beat them all',
    'beatemup',
    'brawler',
    'hack and slash',
    'hack n slash',
    'side scrolling fighter',
    'picchiaduro a scorrimento',
    'prugelspiel',
    'palizas',
    'briga de rua',
  ]),
  // Shoot 'em ups are a distinct shelf from the broader shooter bucket.
  _BucketKeywords(GenreBucket.shootEmUp, [
    'shoot em up',
    'shoot them up',
    'shmup',
    'shump',
    'bullet hell',
    'danmaku',
    'vertical shooter',
    'horizontal shooter',
    'matamarcianos',
    'sparatutto a scorrimento',
  ]),
  _BucketKeywords(GenreBucket.platform, [
    'platform',
    'plataforma',
    'plattform',
    'piattaforma',
    'plate',
    'jump and run',
  ]),
  _BucketKeywords(GenreBucket.shooter, [
    'shoot',
    'fps',
    'tir',
    'disparo',
    'sparatutto',
    'ballerspiel',
    'run and gun',
    'tiro',
  ]),
  _BucketKeywords(GenreBucket.fighting, [
    'fight',
    'versus',
    'vs',
    'combat',
    'lucha',
    'pelea',
    'picchiaduro',
    'kampf',
    'luta',
    'briga',
  ]),
  _BucketKeywords(GenreBucket.racing, [
    'racing',
    'race',
    'driving',
    'course',
    'rennspiel',
    'rennen',
    'carrera',
    'corsa',
    'corse',
    'corrida',
    'kart',
  ]),
  _BucketKeywords(GenreBucket.quiz, [
    'quiz',
    'trivia',
    'question',
    'questions',
    'questionario',
    'frage',
    'preguntas',
    'perguntas',
  ]),
  _BucketKeywords(GenreBucket.boardCard, [
    'board',
    'card',
    'cards',
    'tabletop',
    'table top',
    'chess',
    'checkers',
    'poker',
    'mahjong',
    'mahjongg',
    'jeu de societe',
    'brettspiel',
    'juego de mesa',
    'gioco da tavolo',
    'jogo de tabuleiro',
  ]),
  _BucketKeywords(GenreBucket.pinball, ['pinball', 'pin ball', 'flipper']),
  _BucketKeywords(GenreBucket.musicRhythm, [
    'music',
    'musique',
    'musik',
    'musica',
    'rhythm',
    'rythme',
    'rhythmus',
    'ritmo',
    'dance',
    'dancing',
    'karaoke',
    'guitar hero',
    'dj hero',
    'beatmania',
  ]),
  _BucketKeywords(GenreBucket.educational, [
    'educational',
    'education',
    'educatif',
    'educative',
    'lernspiel',
    'lernen',
    'educativo',
    'educativa',
    'educacional',
    'didactic',
    'edutainment',
  ]),
  _BucketKeywords(GenreBucket.puzzle, [
    'puzzle',
    'reflexion',
    'rompecabezas',
    'ratsel',
    'rompicapo',
    'denkspiel',
    'quebra',
    'cabeca',
    'logic',
    'logica',
  ]),
  // Racing and fighting resolve before sports so `Course / Sport` is a race
  // and a boxing game filed as `Combat / Sport` is a fighter.
  _BucketKeywords(GenreBucket.sports, [
    'sport',
    'deporte',
    'esporte',
    'football',
    'soccer',
    'tennis',
    'golf',
    'basketball',
    'baseball',
  ]),
  _BucketKeywords(GenreBucket.strategy, [
    'strategy',
    'strategie',
    'estrategia',
    'strategia',
    'rts',
    'tactic',
    'tactique',
    'taktik',
    'wargame',
    'tower defense',
  ]),
  // Spelled out rather than a bare `sim` prefix, which is broad enough to
  // catch unrelated words at a word start.
  _BucketKeywords(GenreBucket.simulation, [
    'simulation',
    'simulator',
    'simulateur',
    'simulacion',
    'simulazione',
    'simulacao',
    'management',
    'gestion',
    'gestao',
    'gestione',
    'tycoon',
    'aufbau',
  ]),
  _BucketKeywords(GenreBucket.adventure, [
    'adventure',
    'aventure',
    'aventura',
    'abenteuer',
    'avventura',
    'point',
    'visual novel',
    'novel',
    'survival horror',
  ]),
  _BucketKeywords(GenreBucket.compilation, [
    'compilation',
    'compilacion',
    'recopilatorio',
    'compilacao',
    'sammlung',
    'raccolta',
    'coletanea',
    'collection',
    'anthology',
    'classics',
  ]),
  // Action last of the real buckets: it is the fallback every compound genre
  // carries, so anything more specific must have had its chance already.
  // Arcade games are action games here; there is no separate arcade shelf.
  _BucketKeywords(GenreBucket.action, [
    'action',
    'aktion',
    'azione',
    'accion',
    'acao',
    'arcade',
    'arcada',
  ]),
  _BucketKeywords(GenreBucket.other, [
    'misc',
    'miscellaneous',
    'miscelanea',
    'miscelania',
    'divers',
    'diversos',
    'varios',
    'various',
    'other',
    'outros',
    'outro',
    'autre',
    'sonstiges',
    'altro',
    'vari',
  ]),
];

/// Characters that separate the parts of a compound genre string.
final RegExp _fragmentSeparators = RegExp(r'[/,|>\-]');

/// Everything that is not a letter or a digit, for word normalization.
final RegExp _nonAlphanumeric = RegExp(r'[^a-z0-9]+');

/// Accented characters ScreenScraper genre names actually contain, mapped to
/// their unaccented form. Dart has no built-in Unicode normalization, so this
/// is a table rather than an NFD pass.
const Map<String, String> _diacritics = {
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ä': 'a',
  'ã': 'a',
  'å': 'a',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'ö': 'o',
  'õ': 'o',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ç': 'c',
  'ñ': 'n',
  'ý': 'y',
  'ÿ': 'y',
  'ß': 'ss',
};

/// The bucket [raw] belongs to.
///
/// Null, empty and unrecognised genres fall in [GenreBucket.other] — that is a
/// real bucket rather than an error, and the pick engine treats it like any
/// other (a shelf only appears once a bucket has enough candidates).
GenreBucket genreBucketOf(String? raw) {
  if (raw == null) return GenreBucket.other;

  final normalized = _stripDiacritics(raw.toLowerCase());
  if (normalized.trim().isEmpty) return GenreBucket.other;

  final fragments = normalized
      .split(_fragmentSeparators)
      .map(_canonicalize)
      .where((f) => f.isNotEmpty)
      .toList();
  if (fragments.isEmpty) return GenreBucket.other;

  for (final entry in _bucketKeywords) {
    for (final fragment in fragments) {
      for (final keyword in entry.keywords) {
        if (fragment.contains(' $keyword')) return entry.bucket;
      }
    }
  }
  return GenreBucket.other;
}

String _stripDiacritics(String value) {
  var result = value;
  _diacritics.forEach((accented, plain) {
    if (result.contains(accented)) result = result.replaceAll(accented, plain);
  });
  return result;
}

/// Reduces a fragment to space-separated words wrapped in spaces, so a plain
/// `contains(' keyword')` is a word-start match.
String _canonicalize(String fragment) {
  final words = fragment.replaceAll(_nonAlphanumeric, ' ').trim();
  return words.isEmpty ? '' : ' $words ';
}
