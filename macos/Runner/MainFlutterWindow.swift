import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // Before any plugin can read a preference.
    LegacyPreferences.importIfNeeded()

    let flutterViewController = FlutterViewController.init()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}

/// Copies the preferences of a NeoStation beta into this build's.
///
/// The betas were `com.neogamelab.neostation`; preferences (shared_preferences'
/// `flutter.*` keys, including a custom user-data folder) are kept per bundle
/// id, so this build would otherwise start without them. The App Sandbox is
/// off (see Release.entitlements), so the beta's domain can be read. Keys this
/// build already has are left alone, and the copy is made once.
enum LegacyPreferences {
  static let legacyDomain = "com.neogamelab.neostation"
  static let currentId = "dev.misoba.neostation"
  static let doneKey = "flutter.legacy_beta_preferences_imported"

  static func importIfNeeded() {
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: doneKey) { return }
    defer { defaults.set(true, forKey: doneKey) }

    guard let legacy = defaults.persistentDomain(forName: legacyDomain), !legacy.isEmpty else {
      return
    }
    // The beta's own Application Support folder, which Dart renames to this
    // build's on the same start: a path inside it must follow.
    let oldFolder = "/Application Support/\(legacyDomain)"
    let newFolder = "/Application Support/\(currentId)"
    for (key, value) in legacy where key.hasPrefix("flutter.") {
      if defaults.object(forKey: key) != nil { continue }
      if let text = value as? String, text.contains(oldFolder) {
        defaults.set(text.replacingOccurrences(of: oldFolder, with: newFolder), forKey: key)
      } else {
        defaults.set(value, forKey: key)
      }
    }
  }
}
