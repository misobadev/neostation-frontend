/// [romname] without its file extension: "Game.gb" and "Game" are one ROM.
///
/// A game list's romname is the file name, extension included, while a game
/// built from a library row has it stripped, so per-game matches and keys go
/// by this. Only an extension of one to five letters or digits is stripped:
/// a title that ends in a period ("Mr. Do.") or has one inside ("Dr. Mario",
/// "Super Mario Bros. 3") keeps it.
String romStem(String romname) {
  final dot = romname.lastIndexOf('.');
  if (dot <= 0) return romname;
  final ext = romname.substring(dot);
  return _extension.hasMatch(ext) ? romname.substring(0, dot) : romname;
}

final RegExp _extension = RegExp(r'^\.[A-Za-z0-9]{1,5}$');
