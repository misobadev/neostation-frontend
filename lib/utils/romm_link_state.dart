import 'package:path/path.dart' as p;

import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/utils/rom_tree.dart';

/// How a local game is linked to RomM, as the Manage tab reports it.
enum RommLinkState {
  /// No `app_romm_rom_map` row exists for the game.
  notLinked,

  /// A row exists that the download path or an automatic pass wrote — or a
  /// legacy row with a null `link_source`, which reads the same way.
  auto,

  /// A row the user picked by hand in the link picker.
  manual,
}

/// Derives the link state the Manage tab shows from the mapping row (or its
/// absence). Pure so the null-source rule is unit-testable on its own:
/// [RommLinkSource.fromDb] already maps a null column to [RommLinkSource.auto],
/// and only [RommLinkSource.manual] is reported as manual.
RommLinkState rommLinkStateOf(RommSaveMapping? mapping) {
  if (mapping == null) return RommLinkState.notLinked;
  return mapping.source == RommLinkSource.manual
      ? RommLinkState.manual
      : RommLinkState.auto;
}

/// The on-disk filename a manual link must be keyed by.
///
/// `app_romm_rom_map.romname` is written with the file's basename *with* its
/// extension (`Game.sfc`, or the `.m3u` of a multi-disc game) by both the
/// download path and `RommProvider.linkLocalCopy`, while `GameModel.romname`
/// carries it stripped. `putManualMapping` replaces only the row with the same
/// key, so the picker derives the basename from [romPath] — decoding the SAF
/// `content://` form Android stores — and falls back to [romname] when there
/// is no path to read it from.
String rommLinkKeyFor({required String? romPath, required String romname}) {
  if (romPath == null || romPath.isEmpty) return romname;
  final base = p.basename(normalizeRomPath(romPath));
  return base.isEmpty ? romname : base;
}
