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
        result(AXIsProcessTrusted())
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
        if !trusted {
          HostChannel.openPane("Privacy_Accessibility")
        }
        result(trusted)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func openPane(_ pane: String) {
    if let url = URL(string: privacyPrefix + pane) {
      NSWorkspace.shared.open(url)
    }
  }
}
