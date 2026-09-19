/// One scanned library entry, reduced to what the RomM link pass matches on.
///
/// The pass compares filenames within a system folder and nothing else, so it
/// reads two columns rather than a whole `DatabaseGameModel`: the library list
/// query joins metadata, runs a correlated subquery per row and sorts by
/// `LOWER(...)`, which on a 10k-ROM Android device is a long frame on the
/// platform thread — an ANR, not a dropped frame — for three values.
typedef RommLinkRow = ({String filename, String romname, String systemFolder});

/// Builds a [RommLinkRow], deriving [RommLinkRow.romname] the way
/// `DatabaseGameModel.romname` does so the pass keys games exactly as the rest
/// of the app does.
RommLinkRow rommLinkRow({
  required String filename,
  required String systemFolder,
}) {
  final lastDot = filename.lastIndexOf('.');
  return (
    filename: filename,
    romname: lastDot != -1 ? filename.substring(0, lastDot) : filename,
    systemFolder: systemFolder,
  );
}
