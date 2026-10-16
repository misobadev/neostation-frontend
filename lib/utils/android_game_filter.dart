/// Tells installed games apart from the emulators and frontends that also
/// declare themselves games.
///
/// Emulators and launchers set the Android game category so they sit with games
/// in the Play Store, which would otherwise fill "Android Games" with the very
/// apps NeoStation exists to launch games through. This only decides what the
/// scan suggests: a user's own choice for an app always wins.
class AndroidGameFilter {
  AndroidGameFilter._();

  /// Frontends and launchers that are not in the emulator catalogue. Matched as
  /// package prefixes so every build variant is caught.
  static const List<String> frontendPackagePrefixes = [
    'com.retroarch',
    'org.es_de',
    'com.magneticchen.daijishou',
    'org.pegasus_frontend',
    'com.neogamelab',
    'com.iisulauncher',
  ];

  /// Packages the emulator catalogue lists as launch targets but that are also
  /// real games: GameHub-style emulators ship disguised variants installed over
  /// these, so the catalogue alone cannot tell them from the genuine app. They
  /// are treated as games; a user with the disguised emulator can unmark it.
  static const Set<String> realGamePackages = {
    'com.tencent.ig',
    'com.tencent.tmgp.cf',
    'com.miHoYo.GenshinImpact',
    'com.miHoYo.Yuanshen',
    'com.miHoYo.Yuanshen.nightly',
  };

  /// Whether [packageName] is an emulator or frontend.
  ///
  /// [emulatorPackages] are the Android packages of the emulators the systems
  /// catalogue knows. [label] is the app's display name, used to catch the
  /// emulators that are not in the catalogue.
  static bool isEmulatorOrFrontend({
    required String packageName,
    String? label,
    Set<String> emulatorPackages = const {},
  }) {
    if (emulatorPackages.contains(packageName) &&
        !realGamePackages.contains(packageName)) {
      return true;
    }
    for (final prefix in frontendPackagePrefixes) {
      if (packageName == prefix || packageName.startsWith('$prefix.')) {
        return true;
      }
    }
    return label != null && label.toLowerCase().contains('emulator');
  }
}
