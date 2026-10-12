import Cocoa
import FlutterMacOS
import ApplicationServices

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    HostChannel.register(with: flutterViewController.engine.binaryMessenger)
    SessionBadgeController.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// Permission checks and System Settings deep links for the Thelxis host.
/// The input hot path (CGEvent) is Dart FFI; see lib/platform/impl/macos_host.dart.
enum HostChannel {
  private static let privacyPrefix = "x-apple.systempreferences:com.apple.preference.security?"
  /// The system prompt is only shown once per launch; afterwards we send the user
  /// straight to the settings pane instead.
  private static var promptedScreenCapture = false

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "io.thelxis/host", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "screenCaptureStatus":
        result(CGPreflightScreenCaptureAccess())
      case "accessibilityStatus":
        result(HostChannel.canPostEvents())
      case "requestScreenCapture":
        if CGPreflightScreenCaptureAccess() {
          result(true)
        } else if !HostChannel.promptedScreenCapture {
          HostChannel.promptedScreenCapture = true
          result(CGRequestScreenCaptureAccess())
        } else {
          HostChannel.openPane("Privacy_ScreenCapture")
          result(false)
        }
      case "requestAccessibility":
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        var canPost = true
        if #available(macOS 10.15, *), !CGPreflightPostEventAccess() {
          canPost = CGRequestPostEventAccess()
        }
        if !trusted || !canPost {
          HostChannel.openPane("Privacy_Accessibility")
        }
        result(trusted && canPost)
      case "setDockIconVisible":
        let args = call.arguments as? [String: Any]
        HostChannel.setDockIconVisible(args?["visible"] as? Bool ?? true)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Tray mode: `.accessory` removes the Dock icon and menu bar while the window
  /// is hidden; `.regular` brings them back and puts the Flutter window in front.
  /// Separate windows such as the session badge are unaffected by the policy.
  private static func setDockIconVisible(_ visible: Bool) {
    DispatchQueue.main.async {
      if visible {
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window is MainFlutterWindow {
          if window.isMiniaturized {
            window.deminiaturize(nil)
          }
          window.makeKeyAndOrderFront(nil)
        }
      } else {
        _ = NSApp.setActivationPolicy(.accessory)
      }
    }
  }

  /// CGEventPost is gated by its own TCC service (PostEvent) since 10.15, and
  /// after an update replaces the binary AXIsProcessTrusted can disagree with
  /// it, so input only works when both say yes.
  private static func canPostEvents() -> Bool {
    let trusted = AXIsProcessTrusted()
    if #available(macOS 10.15, *) {
      return trusted && CGPreflightPostEventAccess()
    }
    return trusted
  }

  private static func openPane(_ pane: String) {
    if let url = URL(string: privacyPrefix + pane) {
      NSWorkspace.shared.open(url)
    }
  }
}
