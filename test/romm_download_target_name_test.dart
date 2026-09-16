import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/models/game_model.dart';
import 'package:neostation/providers/neo_sync_provider.dart';

/// RomM names a download target relative to RetroArch's layout
/// (`saves/<core>/<file>`), but the shared resolver joins the file's path onto
/// the save or state directory and picks between them by type. Issue #511:
/// the `saves/` root was passed through, so saves landed in
/// `<saves>/saves/<core>/` and states under the saves directory.
void main() {
  final game = GameModel(
    name: 'Pokemon Emerald',
    realname: 'Pokemon Emerald',
    romname: 'Pokemon Emerald.gba',
    systemFolderName: 'gba',
    systemId: 'gba',
    year: '',
    developer: '',
    publisher: '',
    genre: '',
    players: '',
    rating: 0.0,
  );

  test('a per-core save drops the saves/ root and stays a save', () {
    final f = localTargetCloudFile(game, 'saves/mGBA/Pokemon Emerald.srm');
    expect(f.filePath, 'mGBA/Pokemon Emerald.srm');
    expect(f.type, 'save');
  });

  test('a flat save drops the saves/ root', () {
    final f = localTargetCloudFile(game, 'saves/Pokemon Emerald.srm');
    expect(f.filePath, 'Pokemon Emerald.srm');
    expect(f.type, 'save');
  });

  test('a state drops the states/ root and is placed as a state', () {
    final f = localTargetCloudFile(game, 'states/mGBA/Pokemon Emerald.state1');
    expect(f.filePath, 'mGBA/Pokemon Emerald.state1');
    expect(f.type, 'state');
  });

  test('a name without a root is passed through as a save', () {
    final f = localTargetCloudFile(game, 'Pokemon Emerald.srm');
    expect(f.filePath, 'Pokemon Emerald.srm');
    expect(f.type, 'save');
  });

  test('a folder merely named like a root is not stripped', () {
    final f = localTargetCloudFile(game, 'savesdata/Pokemon Emerald.srm');
    expect(f.filePath, 'savesdata/Pokemon Emerald.srm');
  });
}
