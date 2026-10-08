import '../../utils/game_name_sort.dart';
import 'package:neostation/models/database_game_model.dart';
import 'package:neostation/models/romm_rom.dart';

/// Pure search / filter logic backing the library-wide [SearchScreen].
///
/// Kept free of Flutter and widget state so it can be unit-tested directly:
/// the screen owns presentation and gamepad focus, these functions own the
/// in-memory matching, sorting and option-derivation rules.

/// A stored rating as the 0..10 score the UI shows. Ratings are held on
/// ScreenScraper's 0..20 scale and displayed out of 10 across the app.
double searchRatingScore(double rating) => rating / 2;

/// The whole 1..10 score a game is filed under, or null when it is unrated.
///
/// The rating filter offers plain scores rather than "4+" thresholds, so each
/// game belongs to exactly one of them — the same one-value-per-game shape the
/// platform and genre filters have.
int? searchRatingBucket(double? rating) {
  if (rating == null || rating <= 0) return null;
  return searchRatingScore(rating).round().clamp(1, 10);
}

/// Keys identifying a filter dimension, shared by the criteria, the facet sets
/// and the screen's chip row.
const String kFilterPlatform = 'platform';
const String kFilterDeveloper = 'developer';
const String kFilterGenre = 'genre';
const String kFilterYear = 'year';
const String kFilterRating = 'rating';

/// Which library a result comes from. Only offered while RomM is connected —
/// with no remote source there is nothing to choose between.
const String kFilterSource = 'source';

/// Values for [kFilterSource]. [kSourceAny] is the "Any" option and is never
/// stored on [SearchCriteria] (null means Any there, as for every dimension).
const String kSourceAny = 'any';
const String kSourceLocal = 'local';
const String kSourceRomm = 'romm';

/// Active filter selection. A null field means "Any" for that dimension.
class SearchCriteria {
  const SearchCriteria({
    this.query = '',
    this.platform,
    this.developer,
    this.genre,
    this.year,
    this.rating,
    this.source,
  });

  final String query;
  final String? platform;
  final String? developer;
  final String? genre;
  final String? year;

  /// Whole 1..10 score to match exactly (null == Any); see [searchRatingBucket].
  final int? rating;

  /// [kSourceLocal] / [kSourceRomm], or null for both. Partitions which
  /// sections the screen renders; it never participates in per-game matching,
  /// which is why [matchesCriteria] ignores it.
  final String? source;

  /// This selection with [dimension] reset to "Any".
  ///
  /// Facets are derived per dimension from everything *except* that dimension,
  /// so a filter's own choice never narrows the options it offers.
  SearchCriteria without(String dimension) => SearchCriteria(
    query: query,
    platform: dimension == kFilterPlatform ? null : platform,
    developer: dimension == kFilterDeveloper ? null : developer,
    genre: dimension == kFilterGenre ? null : genre,
    year: dimension == kFilterYear ? null : year,
    rating: dimension == kFilterRating ? null : rating,
    source: dimension == kFilterSource ? null : source,
  );

  /// The active value for a string-valued [dimension] (null == Any).
  String? valueOf(String dimension) => switch (dimension) {
    kFilterPlatform => platform,
    kFilterDeveloper => developer,
    kFilterGenre => genre,
    kFilterYear => year,
    kFilterSource => source,
    _ => null,
  };

  /// Whether the local library should be shown at all.
  bool get includesLocal => source != kSourceRomm;

  /// Whether the RomM section should be shown at all.
  bool get includesRomm => source != kSourceLocal;

  /// Whether every active dimension can be evaluated against a RomM result.
  ///
  /// Rating is one that can't: local scores come from the scraper on a
  /// 0..20 scale while RomM carries IGDB's 0..100 and populates it sparsely, so
  /// the same chip would return inconsistent sets across the two sources.
  /// The screen surfaces that rather than quietly leaving remote rows
  /// unfiltered.
  bool get rommFilterable => rating == null;

  /// The part of this selection RomM cannot apply server-side.
  ///
  /// Platform, genre and developer go to `/api/roms` as query parameters and
  /// are matched across the whole library. RomM has no release-year filter, so
  /// year is the one dimension still applied to the rows that come back — which
  /// means it only narrows the pages fetched so far.
  SearchCriteria get remoteClientSide => SearchCriteria(year: year);

  /// Whether any dimension still has to be applied client-side; used to decide
  /// whether the loaded-pages caveat applies at all.
  bool get hasClientSideRemoteFilter => year != null;
}

/// Extracts a 4-digit year from a raw year / ISO release-date string.
String? searchYearOf(DatabaseGameModel g) {
  final raw = g.year?.trim();
  if (raw == null || raw.isEmpty) return null;
  final m = RegExp(r'(\d{4})').firstMatch(raw);
  return m?.group(1);
}

/// Distinct, case-insensitively sorted, non-empty values produced by [pick].
List<String> distinctOptions(
  Iterable<DatabaseGameModel> games,
  String? Function(DatabaseGameModel) pick,
) {
  final set = <String>{};
  for (final g in games) {
    final v = pick(g)?.trim();
    if (v != null && v.isNotEmpty) set.add(v);
  }
  return set.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
}

/// Distinct 4-digit years present in [games], sorted newest first.
List<String> distinctYears(Iterable<DatabaseGameModel> games) {
  final set = <String>{};
  for (final g in games) {
    final y = searchYearOf(g);
    if (y != null) set.add(y);
  }
  return set.toList()..sort((a, b) => b.compareTo(a));
}

/// Whether [g] satisfies every dimension of [criteria].
bool matchesCriteria(DatabaseGameModel g, SearchCriteria criteria) {
  final query = criteria.query.trim().toLowerCase();
  if (query.isNotEmpty) {
    final name = (g.realName ?? g.filename).toLowerCase();
    if (!name.contains(query)) return false;
  }
  if (criteria.platform != null && g.systemRealName != criteria.platform) {
    return false;
  }
  if (criteria.developer != null &&
      (g.developer?.trim() ?? '') != criteria.developer) {
    return false;
  }
  if (criteria.genre != null && (g.genre?.trim() ?? '') != criteria.genre) {
    return false;
  }
  if (criteria.year != null && searchYearOf(g) != criteria.year) return false;
  if (criteria.rating != null &&
      searchRatingBucket(g.rating) != criteria.rating) {
    return false;
  }
  return true;
}

/// The subset of a RomM result the filters can be evaluated against.
///
/// Deliberately a plain value type rather than `RommRom` itself: [platform] is
/// the *local* system name the ROM resolves to, not RomM's platform slug, so
/// the platform chip keeps offering one vocabulary across both sources. The
/// screen resolves that per page and hands it in here.
class RemoteGameFields {
  const RemoteGameFields({
    required this.name,
    this.platform,
    this.genres = const [],
    this.companies = const [],
    this.year,
  });

  final String name;
  final String? platform;
  final List<String> genres;
  final List<String> companies;
  final String? year;
}

/// Whether a RomM result satisfies every dimension of [criteria] that can be
/// evaluated remotely.
///
/// Genre and developer match if *any* of the ROM's values match, because RomM
/// carries lists where the local database carries one joined string — a game
/// filed under "Role-playing, Adventure" should still answer an Adventure
/// filter. Rating is not evaluated here; see [SearchCriteria.rommFilterable].
bool matchesRemoteCriteria(RemoteGameFields g, SearchCriteria criteria) {
  final query = criteria.query.trim().toLowerCase();
  if (query.isNotEmpty && !g.name.toLowerCase().contains(query)) return false;

  if (criteria.platform != null && g.platform != criteria.platform) {
    return false;
  }
  if (criteria.developer != null &&
      !g.companies.any((c) => c.trim() == criteria.developer)) {
    return false;
  }
  if (criteria.genre != null &&
      !g.genres.any((v) => v.trim() == criteria.genre)) {
    return false;
  }
  if (criteria.year != null && g.year != criteria.year) return false;
  return true;
}

/// Applies [criteria] to [games] and returns the matches sorted by display
/// name (realName, falling back to filename), case-insensitively.
List<DatabaseGameModel> filterAndSortGames(
  Iterable<DatabaseGameModel> games,
  SearchCriteria criteria, {
  bool ignoreArticles = false,
}) {
  return games.where((g) => matchesCriteria(g, criteria)).toList()
    ..sort((a, b) {
      final an = (a.realName ?? a.filename).toLowerCase();
      final bn = (b.realName ?? b.filename).toLowerCase();
      return compareGameTitles(an, bn, ignoreArticles: ignoreArticles);
    });
}

/// The option sets offered by the filter chips for a given selection.
///
/// Each list is derived from the games that match every *other* dimension, so
/// the filters only ever offer values that can actually narrow the current
/// results — searching "Sonic" leaves no NES entry in the platform picker.
class SearchFacets {
  const SearchFacets({
    this.platforms = const [],
    this.developers = const [],
    this.genres = const [],
    this.years = const [],
    this.ratings = const [],
  });

  final List<String> platforms;
  final List<String> developers;
  final List<String> genres;
  final List<String> years;

  /// Whole 1..10 scores at least one candidate game is filed under, ascending.
  final List<int> ratings;

  static const SearchFacets empty = SearchFacets();

  /// String options for a dimension ([kFilterRating] has its own list).
  List<String> optionsFor(String dimension) => switch (dimension) {
    kFilterPlatform => platforms,
    kFilterDeveloper => developers,
    kFilterGenre => genres,
    kFilterYear => years,
    _ => const [],
  };
}

/// Derives the per-dimension filter options available under [criteria].
SearchFacets computeFacets(
  Iterable<DatabaseGameModel> games,
  SearchCriteria criteria,
) {
  final all = games is List<DatabaseGameModel> ? games : games.toList();
  return SearchFacets(
    platforms: _facet(all, criteria, kFilterPlatform, (g) => g.systemRealName),
    developers: _facet(all, criteria, kFilterDeveloper, (g) => g.developer),
    genres: _facet(all, criteria, kFilterGenre, (g) => g.genre),
    years: _yearFacet(all, criteria),
    ratings: _ratingFacet(all, criteria),
  );
}

/// Candidate games for [dimension]'s facet: everything matching the other
/// dimensions of [criteria].
Iterable<DatabaseGameModel> _candidates(
  List<DatabaseGameModel> games,
  SearchCriteria criteria,
  String dimension,
) {
  final scoped = criteria.without(dimension);
  return games.where((g) => matchesCriteria(g, scoped));
}

/// Options for a string-valued dimension.
///
/// An active value is kept in the list even when nothing matches it any more
/// (a query that strands the current selection), so the chip stays consistent
/// with its picker and the user can still cycle off it.
List<String> _facet(
  List<DatabaseGameModel> games,
  SearchCriteria criteria,
  String dimension,
  String? Function(DatabaseGameModel) pick,
) {
  final options = distinctOptions(
    _candidates(games, criteria, dimension),
    pick,
  );
  final active = criteria.valueOf(dimension);
  if (active != null && !options.contains(active)) {
    options
      ..add(active)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }
  return options;
}

List<String> _yearFacet(
  List<DatabaseGameModel> games,
  SearchCriteria criteria,
) {
  final years = distinctYears(_candidates(games, criteria, kFilterYear));
  final active = criteria.year;
  if (active != null && !years.contains(active)) {
    years
      ..add(active)
      ..sort((a, b) => b.compareTo(a));
  }
  return years;
}

/// Scores actually present in the candidate set — a library of 7s and 8s
/// offers 7 and 8, not the whole 1..10 range.
List<int> _ratingFacet(List<DatabaseGameModel> games, SearchCriteria criteria) {
  final scores = <int>{};
  for (final g in _candidates(games, criteria, kFilterRating)) {
    final bucket = searchRatingBucket(g.rating);
    if (bucket != null) scores.add(bucket);
  }
  final active = criteria.rating;
  if (active != null) scores.add(active);
  return scores.toList()..sort();
}

/// One line in the results list.
///
/// Local games, the "On RomM" divider, remote ROMs and the remote section's
/// loading / error / load-more line all share a single flat list so the
/// existing index-based gamepad navigation and fixed-extent scroll maths keep
/// working unchanged. Rows the user can't focus (the header, the spinner) are
/// simply left out of the focusable index.
sealed class ResultRow {
  const ResultRow();
}

class LocalRow extends ResultRow {
  const LocalRow(this.game);
  final DatabaseGameModel game;
}

class RemoteHeaderRow extends ResultRow {
  const RemoteHeaderRow();
}

class RemoteRow extends ResultRow {
  const RemoteRow(this.rom);
  final RommRom rom;
}

/// The remote section's trailing line: a spinner, an error, "load more", or a
/// note that the active filters can't be applied to RomM results.
enum RemoteStatus { loading, error, loadMore, unsupported, noEquivalent }

class RemoteStatusRow extends ResultRow {
  const RemoteStatusRow(this.status);
  final RemoteStatus status;
}

/// Headers and the spinner are skipped by Up/Down; everything else stops.
bool isFocusableRow(ResultRow row) => switch (row) {
  LocalRow() => true,
  RemoteRow() => true,
  RemoteStatusRow(:final status) =>
    status == RemoteStatus.loadMore || status == RemoteStatus.error,
  RemoteHeaderRow() => false,
};

/// The rendered rows plus the subset of their indices that can take focus.
///
/// The two index spaces are deliberately separate and must not be used
/// interchangeably: [rows] is what the list builder renders, while selection is
/// tracked as a position in [focusable]. They coincide only while the results
/// are local-only — as soon as the unfocusable RomM header is present, every
/// row below it sits at a different index in each. Translate with
/// [focusableIndexOfRow].
class ResultRows {
  const ResultRows({required this.rows, required this.focusable});

  final List<ResultRow> rows;
  final List<int> focusable;

  static const ResultRows empty = ResultRows(rows: [], focusable: []);

  /// The selection index for a row at [rowIndex] in [rows], or -1 when that row
  /// can't take focus (the RomM header, the spinner).
  int focusableIndexOfRow(int rowIndex) => focusable.indexOf(rowIndex);

  /// The row [selectionIndex] points at, or null when the list is empty.
  ResultRow? rowAtSelection(int selectionIndex) =>
      selectionIndex >= 0 && selectionIndex < focusable.length
      ? rows[focusable[selectionIndex]]
      : null;
}

/// Builds the flat row list from the local results plus the RomM section.
///
/// The chip filters deliberately do not narrow the RomM section beyond what
/// [visibleRemote] already carries: [RommRom] has no rating, so applying that
/// criterion remotely would silently drop everything. The caller reports that
/// case through [rommFilterable] instead, and a filter value RomM's vocabulary
/// has no entry for through [unmatchedFilter] — each replaces the remote rows
/// with a single explanatory line rather than an unexplained empty list.
ResultRows buildResultRows({
  required List<DatabaseGameModel> results,
  bool remoteSectionVisible = false,
  bool rommFilterable = true,
  String? unmatchedFilter,
  List<RommRom> visibleRemote = const [],
  bool hasError = false,
  bool isLoading = false,
  bool hasMore = false,
}) {
  final rows = <ResultRow>[...results.map(LocalRow.new)];

  if (remoteSectionVisible) {
    rows.add(const RemoteHeaderRow());

    if (!rommFilterable) {
      // A rating filter is active and can't be evaluated remotely; say so
      // instead of listing rows the filter never touched.
      rows.add(const RemoteStatusRow(RemoteStatus.unsupported));
    } else if (unmatchedFilter != null) {
      rows.add(const RemoteStatusRow(RemoteStatus.noEquivalent));
    } else {
      rows.addAll(visibleRemote.map(RemoteRow.new));
      if (hasError) {
        rows.add(const RemoteStatusRow(RemoteStatus.error));
      } else if (isLoading) {
        rows.add(const RemoteStatusRow(RemoteStatus.loading));
      } else if (hasMore) {
        rows.add(const RemoteStatusRow(RemoteStatus.loadMore));
      }
    }
  }

  return ResultRows(
    rows: rows,
    focusable: [
      for (var i = 0; i < rows.length; i++)
        if (isFocusableRow(rows[i])) i,
    ],
  );
}

/// Cycles through [options] with an "Any" (null) slot at the head, moving by
/// [delta] with wraparound. Returns the newly selected value (null == Any).
T? cycleFilterValue<T>(List<T> options, T? current, int delta) {
  final len = options.length + 1;
  final currentIdx = current == null ? 0 : options.indexOf(current) + 1;
  var next = (currentIdx + delta) % len;
  if (next < 0) next += len;
  return next == 0 ? null : options[next - 1];
}

/// Ordered choices offered when a search result is selected.
///
/// [download] only ever appears for a RomM result that isn't on this device
/// yet; once it is downloaded a remote result offers the same [goTo] / [play]
/// as a local one, plus [link], which opens the manual RomM link picker
/// pre-selected on that result.
enum SearchResultAction { goTo, play, download, link }

/// The action list for a selected result, in D-pad order.
///
/// A local row offers Go-to-game and Play, plus Link while RomM is connected
/// ([canLink]). That is the only way in for the case manual linking exists
/// for: a ROM whose local filename does not match the server's is never
/// recognised as downloaded, so the remote row for it cannot resolve back to
/// it and offers Download alone. Starting from the local game instead, the
/// picker opens on the game's own system and the user chooses the RomM entry.
///
/// A remote row that maps back to a local game ([hasLocal]) offers the same
/// two first — so the existing focus order is unchanged — and then Link; one
/// that doesn't offers Download only.
List<SearchResultAction> searchResultActionsFor({
  required bool isRemote,
  required bool hasLocal,
  bool canLink = false,
}) {
  if (!isRemote) {
    return [
      SearchResultAction.goTo,
      SearchResultAction.play,
      if (canLink && hasLocal) SearchResultAction.link,
    ];
  }
  return hasLocal
      ? const [
          SearchResultAction.goTo,
          SearchResultAction.play,
          SearchResultAction.link,
        ]
      : const [SearchResultAction.download];
}
