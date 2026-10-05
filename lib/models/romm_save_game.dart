import 'romm_asset.dart';
import 'romm_rom.dart';

/// One game's remote inventory, in most-recently-updated order.
class RommSaveGame {
  final String key;
  final int? romId;
  final List<RommAsset> assets;

  const RommSaveGame(this.key, this.romId, this.assets);

  int get saves => assets.where((asset) => !asset.isState).length;
  int get states => assets.length - saves;

  /// A display-only fallback while metadata loads; never used to match art.
  String get fallbackTitle {
    final file = assets.first;
    var title = file.fileName.replaceFirst(
      RegExp(r'\s*\[\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\]'),
      '',
    );
    title = title.replaceFirst(
      file.isState ? RegExp(r'\.state(?:\..*|\d*)$') : RegExp(r'\.[^.]+$'),
      '',
    );
    return title.isEmpty ? file.fileName : title;
  }

  static List<RommSaveGame> group(List<RommAsset> assets) {
    final groups = <String, List<RommAsset>>{};
    for (final asset in assets) {
      // Unidentified assets stay separate rather than borrowing another game's
      // title or artwork on a filename guess. Save/state IDs can overlap.
      final key = asset.romId != null
          ? 'rom:${asset.romId}'
          : '${asset.isState ? 'state' : 'save'}:${asset.id}';
      (groups[key] ??= []).add(asset);
    }
    return [
      for (final entry in groups.entries)
        RommSaveGame(
          entry.key,
          entry.value.first.romId,
          List.unmodifiable(entry.value),
        ),
    ];
  }
}

/// Existing metadata/art only. Opening Saves never starts a scrape or import.
class RommSaveGameInfo {
  final RommRom? rom;
  final String? localCover;
  final List<String> serverCovers;

  const RommSaveGameInfo({
    this.rom,
    this.localCover,
    this.serverCovers = const [],
  });
}
