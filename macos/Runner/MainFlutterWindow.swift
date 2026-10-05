import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let shortcuts = FlutterMethodChannel(
      name: "com.neogamelab.neostation/shortcuts",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    shortcuts.setMethodCallHandler { call, result in
      guard let path = call.arguments as? String else {
        result(FlutterError(code: "invalid_path", message: "Missing shortcut path", details: nil))
        return
      }
      let url = URL(fileURLWithPath: path)
      do {
        let isAlias = try url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true
        switch call.method {
        case "isAlias":
          result(isAlias)
        case "launch":
          let target = isAlias
            ? try URL(resolvingAliasFileAt: url, options: [.withoutUI]) : url
          NSWorkspace.shared.open(target, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
              if let error = error {
                result(FlutterError(code: "launch_failed", message: error.localizedDescription, details: nil))
              } else {
                result(nil)
              }
            }
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "shortcut_failed", message: error.localizedDescription, details: nil))
      }
    }

    super.awakeFromNib()
  }
}
