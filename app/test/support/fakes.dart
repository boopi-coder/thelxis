import 'dart:async';

import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:thelxis/platform/host_platform.dart';
import 'package:thelxis/platform/session_badge.dart';
import 'package:thelxis/net/connectivity/connectivity.dart';

/// Connectivity stand-in for tests: records grants and advertises a fixed
/// address list.
class FakeConnectivity implements Connectivity {
  FakeConnectivity({this.addresses = const []});

  final List<String> addresses;
  final ValueNotifier<ReachabilityReport> _report =
      ValueNotifier(const ReachabilityReport());
  final List<TurnGrant> issued = [];
  final List<TurnGrant> revoked = [];
  bool listening = false;
  bool started = false;
  bool? lastPortMapping;
  ManualForwarding? manualForwarding;
  final List<ManualForwarding?> manualHistory = [];
  final List<bool> gatewayGrants = [];
  int _n = 0;

  /// Publishes a connectivity snapshot (tests drive the reachability UI).
  void publish(ReachabilityReport r) => _report.value = r;

  @override
  Future<void> start({required bool portMapping}) async {
    started = true;
    lastPortMapping = portMapping;
  }

  @override
  Future<void> stop() async {
    started = false;
  }

  @override
  Future<void> refresh() async {}

  @override
  ValueListenable<ReachabilityReport> get report => _report;

  @override
  void setManualForwarding(ManualForwarding? forwarding) {
    manualForwarding = forwarding;
    manualHistory.add(forwarding);
  }

  @override
  void setListening(bool value) {
    listening = value;
  }

  @override
  List<String> advertisedAddresses() => addresses;

  @override
  TurnGrant? issueTurnGrant({
    String? dialedAddress,
    Duration ttl = const Duration(hours: 12),
    bool gateway = false,
  }) {
    gatewayGrants.add(gateway);
    final g = TurnGrant(
      username: 'user${_n++}',
      credential: 'cred',
      udpPort: 47100,
      tcpPort: 47101,
      expiresAt: DateTime.now().add(ttl),
    );
    issued.add(g);
    return g;
  }

  @override
  void revokeTurnGrant(TurnGrant grant) {
    revoked.add(grant);
  }
}

/// Records every event of a (single-subscription) stream so tests can await
/// specific event types in any order without losing earlier ones.
class EventLog<T> {
  EventLog(Stream<T> stream) {
    _sub = stream.listen((e) {
      _events.add(e);
      _check();
    });
  }

  late final StreamSubscription<T> _sub;
  final List<T> _events = [];
  final List<_Waiter> _waiters = [];

  List<T> get events => List.unmodifiable(_events);

  /// Completes with the first not-yet-consumed event of type [R].
  Future<R> waitFor<R extends T>({Duration timeout = const Duration(seconds: 8)}) {
    final w = _Waiter<R>();
    _waiters.add(w);
    _check();
    return w.completer.future.timeout(timeout);
  }

  void _check() {
    for (final w in _waiters.toList()) {
      for (var i = 0; i < _events.length; i++) {
        final e = _events[i];
        if (w.matches(e)) {
          _events.removeAt(i);
          _waiters.remove(w);
          w.complete(e);
          break;
        }
      }
    }
  }

  Future<void> cancel() => _sub.cancel();
}

class _Waiter<R> {
  final Completer<R> completer = Completer<R>();
  bool matches(Object? e) => e is R;
  void complete(Object? e) => completer.complete(e as R);
}


/// HostPlatform stand-in: one 1920x1080 display, records capture start/stop.
class FakeHostPlatform implements HostPlatform {
  FakeHostPlatform({this.supported = true, this.inputOk = true, int displayCount = 1, InputInjector? injector})
      : displayList = [
          for (var i = 0; i < displayCount; i++)
            HostDisplay(
              id: '$i',
              name: 'Display ${i + 1}',
              bounds: Rect.fromLTWH(i * 1920.0, 0, 1920, 1080),
              pixelWidth: 1920,
              pixelHeight: 1080,
              primary: i == 0,
            ),
        ],
        _injector = injector ?? _NoopInput();

  final bool supported;
  final bool inputOk;
  final List<HostDisplay> displayList;
  int beforeCaptureCalls = 0;
  int afterCaptureCalls = 0;
  final InputInjector _injector;

  @override
  bool get hostSupported => supported;

  @override
  bool get inputSupported => inputOk;

  @override
  Future<PermissionStatus> permissionStatus(HostPermission permission) async => PermissionStatus.granted;

  @override
  Future<void> requestPermission(HostPermission permission) async {}

  @override
  Future<List<HostDisplay>> displays() async => displayList;

  @override
  Future<void> beforeCapture() async => beforeCaptureCalls++;

  @override
  Future<void> afterCapture() async => afterCaptureCalls++;

  @override
  InputInjector get input => _injector;
}

class _NoopInput implements InputInjector {
  @override
  void mouseMove(HostDisplay display, double nx, double ny) {}
  @override
  void mouseButton(MouseButton button, bool down) {}
  @override
  void scroll(double dx, double dy) {}
  @override
  void key(int usbHid, bool down) {}
  @override
  void text(String text) {}
  @override
  Future<void> special(SpecialAction action) async {}
  @override
  void releaseAll() {}
}


/// Records what the session badge was asked to show.
class FakeBadge implements SessionBadge {
  final List<BadgeState> shown = [];
  int dismissCalls = 0;
  final StreamController<void> _stops = StreamController<void>.broadcast();

  /// The state currently on screen, or null when dismissed.
  BadgeState? get current => _visible ? shown.last : null;

  bool _visible = false;

  @override
  Future<void> show(BadgeState state) async {
    _visible = true;
    shown.add(state);
  }

  @override
  Future<void> dismiss() async {
    _visible = false;
    dismissCalls++;
  }

  @override
  Stream<void> get stopRequests => _stops.stream;

  void pressStop() => _stops.add(null);
}
