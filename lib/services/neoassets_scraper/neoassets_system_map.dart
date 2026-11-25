import '../../models/neoassets_scrape_models.dart';

/// Maps NeoStation systems (`app_systems.id`, the `assets/systems/<id>.json`
/// name) to the NeoAssets catalog they are looked up in.
///
/// Most NeoStation ids are NeoAssets ids already. The rest are regional
/// twins (Mega Drive is Genesis), hack lists that share their parent's
/// catalog, or arcade sets that NeoAssets indexes as one group. Systems not
/// listed here are not offered for NeoAssets scraping, which keeps a lookup
/// from spending quota on a `system_id` the server would reject.
class NeoAssetsSystemMap {
  NeoAssetsSystemMap._();

  /// NeoAssets metadata systems whose id NeoStation uses verbatim.
  static const Set<String> _sameId = {
    '2600', '5200', '7800', '32x', '3do', '3ds', 'a2001', 'ast', 'aw', //
    'bbcmicro', 'c64', 'cdi', 'chf', 'cpc', 'cps1', 'cps2', 'cps3', 'cv',
    'dc', 'dos', 'ds', 'duck', 'fds', 'gb', 'gba', 'gbc', 'gc', 'genesis',
    'gg', 'gw', 'intv', 'jag', 'jagcd', 'lynx', 'mini', 'mo2', 'model3',
    'msx', 'n64', 'naomi', 'naomi2', 'naomigd', 'neogeo', 'nes', 'ngcd',
    'ngp', 'ngpc', 'pc98', 'pcfx', 'ps1', 'ps2', 'ps3', 'psp', 'sat', 'scd',
    'scummvm', 'sg1k', 'sharpx68000', 'sms', 'snes', 'switch', 'tg16',
    'tgcd', 'tic80', 'triforce', 'vb', 'vc4k', 'vect', 'vic20', 'vita', 'wii',
    'wiiu', 'ws', 'wsc', 'wsv', 'xbox', 'xbox360', 'zxspectrum',
  };

  /// NeoStation systems that read another NeoAssets system's catalog.
  static const Map<String, String> _aliases = {
    'md': 'genesis',
    'md-hacks': 'genesis',
    'gen-hacks': 'genesis',
    'mcd': 'scd',
    'sfc': 'snes',
    'sfc-hacks': 'snes',
    'snes-hacks': 'snes',
    'satellaview': 'snes',
    'fc': 'nes',
    'nes-hacks': 'nes',
    'gb-hacks': 'gb',
    'gbc-hacks': 'gbc',
    'gba-hacks': 'gba',
    'gg-hacks': 'gg',
    'mark3': 'sms',
    'pce': 'tg16',
    'pccd': 'tgcd',
    'pspminis': 'psp',
    // NeoAssets' virtual "arcade" system expands to every arcade catalog.
    'arc': 'arcade',
  };

  /// NeoStation systems looked up across a NeoAssets group.
  static const Map<String, String> _groups = {
    'mame': 'mame-fbneo',
    'fbneo': 'mame-fbneo',
  };

  /// The selector for [appSystemId], or null when NeoAssets has no catalog
  /// for it.
  static NeoAssetsSystemSelector? selectorFor(String appSystemId) {
    final id = appSystemId.trim().toLowerCase();
    if (_sameId.contains(id)) return NeoAssetsSystemSelector.system(id);
    final alias = _aliases[id];
    if (alias != null) return NeoAssetsSystemSelector.system(alias);
    final group = _groups[id];
    if (group != null) return NeoAssetsSystemSelector.group(group);
    return null;
  }

  static bool supports(String appSystemId) => selectorFor(appSystemId) != null;
}
