import 'dart:async';

import 'package:flutter/foundation.dart';
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
  int _n = 0;

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
  void setListening(bool value) {
    listening = value;
  }

  @override
  List<String> advertisedAddresses() => addresses;

  @override
  TurnGrant? issueTurnGrant({String? dialedAddress, Duration ttl = const Duration(hours: 12)}) {
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
