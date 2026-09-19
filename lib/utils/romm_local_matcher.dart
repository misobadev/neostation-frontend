import 'package:path/path.dart' as p;

import '../models/romm_rom.dart';

/// The one rule that decides whether a local library entry *is* a RomM ROM.
///
/// Every consumer of "does this RomM ROM correspond to a file we already
/// have" — the browse grid's "downloaded" badge, bulk sync's skip decision, and
/// the link paths that write `app_romm_rom_map` for pre-existing ROMs — goes
/// through here, so the badge and the link can never disagree about a game.
///
/// Two pieces, and callers compose them: [candidateNames] is every on-disk
/// name a ROM may have, [normalizeName] is what makes two names equal. The
/// callers differ in what they compare against — a directory listing, a
/// key in the scan index — so the composition is theirs; the rule is here.
///
/// Pure by design: it compares names and never touches the filesystem, the
/// database, or the network. Callers that need to know whether a candidate
/// name actually exists on disk (or in the scan index) do that probing
/// themselves and feed the names in.
///
/// Platform-to-system resolution is deliberately *not* part of this class: the
/// callers already scope their lookups to the local system a RomM platform
/// resolves to (`RommProvider.resolveSystem`), so the rule only has to answer
/// the filename half of the equivalence.
class RommLocalMatcher {
  const RommLocalMatcher._();

  /// On-disk names under which [rom] may exist locally, in match priority.
  ///
  /// A single-file ROM lands as its [RommRom.fsName]. A multi-disc ROM is
  /// served as a zip that `extractMultiDiscZip` unpacks into disc files plus a
  /// `.m3u` playlist and then deletes — so the fsName itself never exists on
  /// disk; only the playlist does. We match the playlist names that extraction
  /// would produce: the synthesised fallback (`<fsName>.m3u`) and, defensively,
  /// the extension-replaced variant (`<stem>.m3u`). A bundled playlist keeps
  /// its own basename, which can't be predicted here; the save map records
  /// that name at download time and `RommProvider` adds it on top of these.
  ///
  /// Returns a fresh, growable list so callers may append to it.
  static List<String> candidateNames(RommRom rom) {
    final names = <String>[rom.fsName];
    if (rom.isMultiFile) {
      names.add('${rom.fsName}.m3u');
      final stem = p.basenameWithoutExtension(rom.fsName);
      if (stem.isNotEmpty && stem != rom.fsName) names.add('$stem.m3u');
    }
    return names;
  }

  /// Canonical form of a filename for equivalence comparison.
  ///
  /// The single definition of "equal": two names are the same file when their
  /// normalized forms are, so every caller compares [candidateNames] against
  /// its own names through this and an index keyed by filename (the
  /// connect-time link pass builds one from the scan index) folds its keys the
  /// same way.
  ///
  /// The comparison is case-insensitive because a library copied from the
  /// server over USB may pass through a case-folding filesystem, and the sync
  /// layer looks games up by the library's own canonical spelling — case must
  /// never be the reason a game stays unlinked.
  static String normalizeName(String name) => name.trim().toLowerCase();
}
