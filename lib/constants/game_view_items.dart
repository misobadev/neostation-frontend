/// The parts of the games views (list, grid, carousel) that can be shown or
/// hidden from each view's options.
///
/// Each view keeps its own choices. They are stored together, comma-separated
/// as `view.item` ids, in `user_config.game_view_hidden_items`, so the view and
/// item ids below must never change.
abstract final class GameViewItem {
  // Views.
  static const String list = 'list';
  static const String grid = 'grid';
  static const String carousel = 'carousel';

  // Items.
  static const String fileName = 'file_name';
  static const String playTime = 'play_time';
  static const String rating = 'rating';
  static const String achievements = 'achievements';
  static const String random = 'random';
  static const String favorite = 'favorite';
  static const String settings = 'settings';
  static const String play = 'play';

  /// The items each view can toggle, in the order its options list them. The
  /// list's details footer has controls the grid and carousel footer doesn't.
  static const Map<String, List<String>> itemsFor = {
    list: [
      fileName,
      playTime,
      rating,
      achievements,
      random,
      favorite,
      settings,
      play,
    ],
    grid: [fileName, playTime, rating, achievements, play],
    carousel: [fileName, playTime, rating, achievements, play],
  };

  static String _id(String view, String item) => '$view.$item';

  /// The items hidden in [view], as bare item ids.
  static Set<String> hiddenIn(Set<String> hidden, String view) => {
    for (final item in itemsFor[view] ?? const <String>[])
      if (hidden.contains(_id(view, item))) item,
  };

  /// [hidden] with [item] in [view] hidden or shown.
  static Set<String> withHidden(
    Set<String> hidden,
    String view,
    String item, {
    required bool hide,
  }) {
    final id = _id(view, item);
    return hide ? {...hidden, id} : ({...hidden}..remove(id));
  }

  /// Parses the stored comma-separated list, dropping anything that isn't a
  /// known item of a known view, so a value written by a newer build can't
  /// hide something this one doesn't have.
  static Set<String> decode(Object? stored) {
    final Iterable<String> ids = switch (stored) {
      final List<dynamic> list => list.map((e) => e.toString()),
      final String text => text.split(','),
      _ => const [],
    };
    return {
      for (final id in ids.map((s) => s.trim()))
        if (_isKnown(id)) id,
    };
  }

  static bool _isKnown(String id) {
    final dot = id.indexOf('.');
    if (dot <= 0) return false;
    final items = itemsFor[id.substring(0, dot)];
    return items != null && items.contains(id.substring(dot + 1));
  }

  /// The stored form of [hidden]: comma-separated, in a stable order.
  static String encode(Set<String> hidden) => [
    for (final view in itemsFor.keys)
      for (final item in itemsFor[view]!)
        if (hidden.contains(_id(view, item))) _id(view, item),
  ].join(',');
}
