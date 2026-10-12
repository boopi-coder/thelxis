// Contract between the app core (sessions/UI) and per-OS native code.
//
// OWNERSHIP: this file is owned by the architect. Core code depends only on
// this file; native implementations live under lib/platform/impl/ and are
// selected by createHostPlatform(). Changing a signature here is a protocol
// change between agents — coordinate before editing.

import 'dart:ui' show Rect;

import 'impl/host_platform_impl.dart' as impl;

/// Mouse buttons, numbered as in PROTOCOL.md §5.3 (`b` field).
enum MouseButton { left, middle, right, back, forward }

/// Non-keyboard actions from PROTOCOL.md §5.3 (`sp` message).
enum SpecialAction { ctrlAltDel, lock, back, home, recents, notifications, power }

/// Host-side capabilities that may need an OS permission.
enum HostPermission {
  /// macOS Screen Recording; Android MediaProjection consent (asked per capture).
  screenCapture,

  /// macOS Accessibility; Android AccessibilityService enabled.
  inputControl,

  /// Android POST_NOTIFICATIONS (needed for the foreground service notice).
  notifications,
}

enum PermissionStatus { granted, denied, notRequired }

/// A physical display of the host.
class HostDisplay {
  const HostDisplay({
    required this.id,
    required this.name,
    required this.bounds,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.primary,
    this.captureSourceId,
  });

  /// Stable id within this run (index as a string is fine: "0", "1", ...).
  final String id;
  final String name;

  /// Display rectangle in the coordinate space the [InputInjector] uses
  /// (Windows: virtual-desktop pixels; macOS: global points; X11: root pixels;
  /// Android: physical pixels of the default display).
  final Rect bounds;

  /// Native pixel size (what the captured video will roughly be).
  final int pixelWidth;
  final int pixelHeight;
  final bool primary;

  /// The flutter_webrtc `desktopCapturer` source id for this display, if the
  /// implementation can determine it. When null, core falls back to matching
  /// by index order of `desktopCapturer.getSources(types: [SourceType.Screen])`.
  final String? captureSourceId;
}

/// Injects input on the host. Calls are fire-and-forget and must be cheap;
/// implementations must never throw from these methods (log and ignore).
abstract class InputInjector {
  /// Absolute move. [nx], [ny] are normalized 0..1 within [display].
  void mouseMove(HostDisplay display, double nx, double ny);

  void mouseButton(MouseButton button, bool down);

  /// Logical pixels as in PROTOCOL.md §5.3 (`dy > 0` scrolls content down,
  /// 60 px ≈ one wheel notch). Implementations accumulate fractions.
  void scroll(double dx, double dy);

  /// [usbHid] is the USB HID usage (page << 16 | id), e.g. 0x00070004 = KeyA.
  void key(int usbHid, bool down);

  /// Types arbitrary unicode text (IME / soft keyboard input).
  void text(String text);

  Future<void> special(SpecialAction action);

  /// Releases every key/button this injector currently holds down.
  void releaseAll();
}

/// Optional capability of an [InputInjector] whose OS can silently refuse
/// injected events (Windows UIPI: an elevated window or the secure desktop has
/// focus). Kept apart from [InputInjector] so existing injectors need no change;
/// the host checks `injector is InjectionReport`.
abstract interface class InjectionReport {
  /// True while the OS is rejecting injected events; clears as soon as an
  /// injection (or a fresh check) succeeds. May do a cheap OS query: the host
  /// polls it every few seconds, never per event.
  bool get injectionRejected;
}

/// Everything the app needs from the OS to act as a host.
abstract class HostPlatform {
  static final HostPlatform instance = impl.createHostPlatform();

  /// Whether this OS build can act as a host at all (e.g. Linux Wayland
  /// without input support still returns true but [inputSupported] false).
  bool get hostSupported;

  /// False when input injection is impossible in this environment
  /// (e.g. Linux Wayland session in v0.1). The session then offers view-only.
  bool get inputSupported;

  Future<PermissionStatus> permissionStatus(HostPermission permission);

  /// Opens the OS prompt or the relevant settings page.
  Future<void> requestPermission(HostPermission permission);

  Future<List<HostDisplay>> displays();

  /// Called right before screen capture starts (Android: start the
  /// mediaProjection foreground service). Must complete before
  /// getDisplayMedia is called.
  Future<void> beforeCapture();

  /// Called after the last capture stopped (Android: stop the service).
  Future<void> afterCapture();

  InputInjector get input;
}
