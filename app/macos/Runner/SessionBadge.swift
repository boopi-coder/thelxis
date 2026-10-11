import Cocoa
import FlutterMacOS

/// Mandatory "being controlled" badge (docs/PROTOCOL.md section 9).
///
/// A borderless, non-activating panel in the top-right corner of the primary
/// display. It is a window of its own, so it keeps showing while the Flutter
/// window is hidden in the tray and the Dock icon is gone. The clock ticks here,
/// not in Dart.
///
/// Channel `io.thelxis/badge`:
///   show {label, stopLabel, sinceMs, controlActive, peers}   dismiss
///   native -> Dart: stopPressed
final class SessionBadgeController: NSObject {
  private static var shared: SessionBadgeController?

  static func register(with messenger: FlutterBinaryMessenger) {
    shared = SessionBadgeController(messenger: messenger)
  }

  private static let size = NSSize(width: 300, height: 56)
  private static let margin: CGFloat = 16

  private let channel: FlutterMethodChannel
  private var panel: BadgePanel?
  private var content: BadgeContentView?
  private var timer: Timer?
  private var sinceMs: Int64 = 0

  private init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "io.thelxis/badge", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      self.handle(call, result)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screensChanged),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "show":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad_args", message: "show expects a map", details: nil))
        return
      }
      let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
      show(
        label: args["label"] as? String ?? "",
        stopLabel: args["stopLabel"] as? String ?? "",
        sinceMs: (args["sinceMs"] as? NSNumber)?.int64Value ?? nowMs,
        controlActive: args["controlActive"] as? Bool ?? false)
      result(nil)
    case "dismiss":
      dismiss()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: show / dismiss

  private func show(label: String, stopLabel: String, sinceMs: Int64, controlActive: Bool) {
    self.sinceMs = sinceMs
    if panel == nil {
      createPanel()
    }
    guard let panel = panel, let content = content else { return }
    content.apply(label: label, stopLabel: stopLabel, controlActive: controlActive)
    updateTimer()
    reposition()
    panel.orderFrontRegardless()

    if timer == nil {
      let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
      // .common: keep ticking while menus or other tracking loops run.
      RunLoop.main.add(t, forMode: .common)
      timer = t
    }
  }

  private func dismiss() {
    timer?.invalidate()
    timer = nil
    panel?.orderOut(nil)
    panel = nil
    content = nil
  }

  private func createPanel() {
    let rect = NSRect(origin: .zero, size: SessionBadgeController.size)
    let panel = BadgePanel(
      contentRect: rect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    // isFloatingPanel resets the level to .floating, so it must come first.
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    // Keep it out of screenshots and recordings made with window-capture APIs.
    panel.sharingType = .none

    let content = BadgeContentView(frame: rect)
    content.stopButton.target = self
    content.stopButton.action = #selector(stopTapped)
    panel.contentView = content

    self.panel = panel
    self.content = content
  }

  // MARK: ticking and placement

  private func tick() {
    updateTimer()
    reposition()
    // Re-assert the level and z-order in case another window took the top.
    panel?.orderFrontRegardless()
  }

  private func updateTimer() {
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    content?.timerField.stringValue = SessionBadgeController.format(seconds: (nowMs - sinceMs) / 1000)
  }

  /// `HH:MM:SS`, hours uncapped, negative (clock moved back) shows zero.
  static func format(seconds: Int64) -> String {
    let total = max(0, seconds)
    return String(format: "%02lld:%02lld:%02lld", total / 3600, (total % 3600) / 60, total % 60)
  }

  /// Top-right corner of the primary display's visible area (below the menu
  /// bar, clear of the Dock).
  private func reposition() {
    guard let panel = panel, let screen = NSScreen.screens.first else { return }
    let area = screen.visibleFrame
    let size = SessionBadgeController.size
    let origin = NSPoint(
      x: area.maxX - SessionBadgeController.margin - size.width,
      y: area.maxY - SessionBadgeController.margin - size.height)
    let frame = NSRect(origin: origin, size: size)
    if panel.frame != frame {
      panel.setFrame(frame, display: true)
      panel.invalidateShadow()
    }
  }

  @objc private func screensChanged() {
    reposition()
  }

  @objc private func stopTapped() {
    channel.invokeMethod("stopPressed", arguments: nil)
  }
}

/// Never becomes key or main, so showing or clicking it cannot steal focus.
private final class BadgePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// The first click on a non-key window must act, not just activate.
private final class FirstMouseButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class BadgeContentView: NSVisualEffectView {
  private static let radius: CGFloat = 14
  private static let viewOnlyAccent = NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.96, alpha: 1)
  private static let controlAccent = NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.37, alpha: 1)

  let iconView = NSImageView()
  let labelField = NSTextField(labelWithString: "")
  let timerField = NSTextField(labelWithString: "")
  let stopButton = FirstMouseButton(frame: .zero)
  private let dot = NSView()
  private let outline = NSView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .hudWindow
    blendingMode = .behindWindow
    state = .active
    appearance = NSAppearance(named: .darkAqua)
    maskImage = BadgeContentView.roundedMask(radius: BadgeContentView.radius)

    // First subview = lowest, so it never intercepts clicks meant for the button.
    outline.wantsLayer = true
    outline.layer?.cornerRadius = BadgeContentView.radius
    outline.layer?.borderWidth = 1
    outline.frame = bounds
    outline.autoresizingMask = [.width, .height]
    addSubview(outline)

    iconView.image = NSApp.applicationIconImage
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.frame = NSRect(x: 12, y: 12, width: 32, height: 32)
    addSubview(iconView)

    labelField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
    labelField.textColor = .white
    labelField.lineBreakMode = .byTruncatingTail
    labelField.maximumNumberOfLines = 1
    addSubview(labelField)

    dot.wantsLayer = true
    dot.layer?.cornerRadius = 4
    addSubview(dot)

    timerField.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    timerField.textColor = NSColor(white: 1, alpha: 0.75)
    timerField.lineBreakMode = .byClipping
    timerField.maximumNumberOfLines = 1
    addSubview(timerField)

    stopButton.isBordered = false
    stopButton.wantsLayer = true
    stopButton.layer?.cornerRadius = 8
    stopButton.layer?.backgroundColor = NSColor(calibratedRed: 0.91, green: 0.27, blue: 0.33, alpha: 1).cgColor
    addSubview(stopButton)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  func apply(label: String, stopLabel: String, controlActive: Bool) {
    labelField.stringValue = label
    stopButton.toolTip = stopLabel
    stopButton.setAccessibilityLabel(stopLabel)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let title = NSAttributedString(
      string: stopLabel,
      attributes: [
        .foregroundColor: NSColor.white,
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        .paragraphStyle: style,
      ])
    stopButton.attributedTitle = title

    let accent = controlActive ? BadgeContentView.controlAccent : BadgeContentView.viewOnlyAccent
    dot.layer?.backgroundColor = accent.cgColor
    outline.layer?.borderColor = accent.withAlphaComponent(controlActive ? 0.9 : 0.5).cgColor
    outline.layer?.borderWidth = controlActive ? 2 : 1
    layoutContent(titleWidth: title.size().width)
  }

  /// Frames are computed by hand: the badge has a fixed size and three controls.
  private func layoutContent(titleWidth: CGFloat) {
    let width = bounds.width
    let height = bounds.height
    let buttonWidth = min(max(64, ceil(titleWidth) + 24), 120)
    let buttonHeight: CGFloat = 28
    stopButton.frame = NSRect(
      x: width - 12 - buttonWidth, y: (height - buttonHeight) / 2,
      width: buttonWidth, height: buttonHeight)

    let textX: CGFloat = 52
    let textWidth = max(40, stopButton.frame.minX - 8 - textX)
    labelField.frame = NSRect(x: textX, y: 29, width: textWidth, height: 18)
    dot.frame = NSRect(x: textX, y: 15, width: 8, height: 8)
    timerField.frame = NSRect(x: textX + 14, y: 10, width: textWidth - 14, height: 16)
  }

  /// 9-slice mask so the blur is clipped to a rounded rectangle at any size.
  private static func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}
