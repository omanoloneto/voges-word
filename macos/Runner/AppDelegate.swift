import Cocoa
import FlutterMacOS
import PDFKit

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

    let spelling = FlutterMethodChannel(
      name: "voges_word/spell",
      binaryMessenger: controller.engine.binaryMessenger)
    let spellTag = NSSpellChecker.uniqueSpellDocumentTag()
    spelling.setMethodCallHandler { call, result in
      guard call.method == "check",
        let arguments = call.arguments as? [String: Any],
        let texts = arguments["texts"] as? [String],
        let wanted = arguments["language"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      let checker = NSSpellChecker.shared
      let languages = checker.availableLanguages
      let base = wanted.split(separator: "_").first.map(String.init) ?? wanted
      let language =
        languages.first { $0 == wanted } ?? languages.first { $0 == base }
        ?? languages.first { $0.hasPrefix(base + "_") }
      result(
        texts.map { text -> [[String: Any]] in
          var found: [[String: Any]] = []
          var start = 0
          let length = (text as NSString).length
          while start < length {
            let range = checker.checkSpelling(
              of: text, startingAt: start, language: language, wrap: false,
              inSpellDocumentWithTag: spellTag, wordCount: nil)
            if range.location == NSNotFound || range.length == 0 { break }
            let guesses =
              checker.guesses(
                forWordRange: range, in: text, language: language,
                inSpellDocumentWithTag: spellTag) ?? []
            found.append([
              "start": range.location,
              "end": range.location + range.length,
              "suggestions": Array(guesses.prefix(5)),
            ])
            start = range.location + range.length
          }
          return found
        })
    }

    let printing = FlutterMethodChannel(
      name: "voges_word/print",
      binaryMessenger: controller.engine.binaryMessenger)
    printing.setMethodCallHandler { call, result in
      guard call.method == "print",
        let arguments = call.arguments as? [String: Any],
        let bytes = arguments["bytes"] as? FlutterStandardTypedData,
        let document = PDFDocument(data: bytes.data),
        let operation = document.printOperation(
          for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true)
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      operation.jobTitle = arguments["name"] as? String ?? "Document"
      operation.showsPrintPanel = true
      operation.showsProgressPanel = true
      if let window = NSApp.mainWindow ?? NSApp.windows.first {
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
      } else {
        operation.run()
      }
      result(nil)
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
