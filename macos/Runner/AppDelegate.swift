import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var channel: FlutterMethodChannel?
  private var pendingPaths: [String] = []
  private var dartReady = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    let paths = urls.filter { $0.isFileURL }.map { $0.path }
    if dartReady, let channel = channel {
      channel.invokeMethod("open", arguments: paths.map { ["path": $0] })
    } else {
      pendingPaths.append(contentsOf: paths)
    }
  }

  func attach(to controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "voges_word/open",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "pending", let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.dartReady = true
      result(self.pendingPaths.map { ["path": $0] })
      self.pendingPaths.removeAll()
    }
    self.channel = channel

    let fonts = FlutterMethodChannel(
      name: "voges_word/fonts",
      binaryMessenger: controller.engine.binaryMessenger)
    fonts.setMethodCallHandler { call, result in
      guard call.method == "families" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") })
    }

    let bookmarks = FlutterMethodChannel(
      name: "voges_word/bookmarks",
      binaryMessenger: controller.engine.binaryMessenger)
    bookmarks.setMethodCallHandler { call, result in
      switch call.method {
      case "create":
        guard let path = call.arguments as? String,
          let data = try? URL(fileURLWithPath: path).bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else {
          result(nil)
          return
        }
        result(data.base64EncodedString())
      case "resolve":
        var stale = false
        guard let text = call.arguments as? String,
          let data = Data(base64Encoded: text),
          let url = try? URL(
            resolvingBookmarkData: data, options: .withSecurityScope,
            relativeTo: nil, bookmarkDataIsStale: &stale)
        else {
          result(nil)
          return
        }
        _ = url.startAccessingSecurityScopedResource()
        result(url.path)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
