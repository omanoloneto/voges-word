import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var titleBarHeight: CGFloat = 0
  private var placingButtons = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    (NSApp.delegate as? AppDelegate)?.attach(to: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "voges_word/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setTitleBarHeight", let self = self,
        let height = call.arguments as? Double
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.titleBarHeight = CGFloat(height)
      self.watchWindowButtons()
      self.placeWindowButtons()
      result(nil)
    }

    super.awakeFromNib()
  }

  override var title: String {
    didSet { DispatchQueue.main.async { [weak self] in self?.placeWindowButtons() } }
  }

  private func watchWindowButtons() {
    guard let close = standardWindowButton(.closeButton),
      let container = close.superview?.superview
    else { return }
    close.postsFrameChangedNotifications = true
    container.postsFrameChangedNotifications = true
    let center = NotificationCenter.default
    let place: (Notification) -> Void = { [weak self] _ in self?.placeWindowButtons() }
    center.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main, using: place)
    center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: self, queue: .main, using: place)
    center.addObserver(forName: NSView.frameDidChangeNotification, object: close, queue: .main, using: place)
    center.addObserver(forName: NSView.frameDidChangeNotification, object: container, queue: .main, using: place)
  }

  /// Centers the close, minimize and zoom buttons in the app's blue ribbon.
  private func placeWindowButtons() {
    guard titleBarHeight > 0, !placingButtons, !styleMask.contains(.fullScreen),
      let close = standardWindowButton(.closeButton),
      let minimize = standardWindowButton(.miniaturizeButton),
      let zoom = standardWindowButton(.zoomButton),
      let container = close.superview?.superview
    else { return }
    placingButtons = true
    defer { placingButtons = false }

    var frame = container.frame
    frame.size.height = titleBarHeight
    frame.origin.y = self.frame.height - titleBarHeight
    if frame != container.frame { container.frame = frame }

    let size = close.frame.size
    let margin = ((titleBarHeight - size.height) / 2).rounded()
    let spacing = minimize.frame.minX - close.frame.maxX
    for (index, button) in [close, minimize, zoom].enumerated() {
      let origin = NSPoint(x: margin + CGFloat(index) * (size.width + spacing), y: margin)
      if button.frame.origin != origin { button.setFrameOrigin(origin) }
    }
  }
}
