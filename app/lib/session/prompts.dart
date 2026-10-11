import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/net_address.dart';
import '../net/peer_identity.dart';
import '../protocol/models.dart';

/// A question or notice the UI must show to the local user. The session layer
/// awaits [result]; the UI completes it through [resolve].
sealed class Prompt<T> {
  Prompt() : _completer = Completer<T>();

  final Completer<T> _completer;

  Future<T> get result => _completer.future;
  bool get isResolved => _completer.isCompleted;

  void resolve(T value) {
    if (!_completer.isCompleted) _completer.complete(value);
  }
}

/// Outcome of [AcceptRequestPrompt].
class ApprovalResult {
  const ApprovalResult({
    required this.accepted,
    this.permissions = Permissions.none,
    this.alwaysAllow = false,
  });

  static const ApprovalResult denied = ApprovalResult(accepted: false);

  final bool accepted;
  final Permissions permissions;
  final bool alwaysAllow;
}

/// "X wants to control this device" (PROTOCOL.md 6.1 `request`, or a password
/// session when approval is required). Auto-denies after [timeout].
class AcceptRequestPrompt extends Prompt<ApprovalResult> {
  AcceptRequestPrompt({
    required this.peer,
    required this.claimedUser,
    required this.proposed,
    required this.canControl,
    this.viaPassword = false,
    this.timeout = const Duration(seconds: 30),
  }) : deadline = DateTime.now().add(timeout);

  final PeerIdentity peer;

  /// Name the viewer typed for itself; unverified, shown with the verified ID.
  final String claimedUser;
  final Permissions proposed;

  /// False when this platform cannot inject input (view-only only).
  final bool canControl;
  final bool viaPassword;
  final Duration timeout;
  final DateTime deadline;
}

/// "Bob offers you control of his computer" (reverse connection).
class ReverseOfferPrompt extends Prompt<bool> {
  ReverseOfferPrompt({required this.peer});
  final PeerIdentity peer;
}

/// First contact with a bare address: show the peer's verified ID and name
/// and let the user pin it (trust on first use).
class FirstContactPrompt extends Prompt<bool> {
  FirstContactPrompt({required this.peer, required this.address});
  final PeerIdentity peer;
  final NetAddress address;
}

/// Security notices that need acknowledgement (identity mismatch, failed
/// signature).
class WarningPrompt extends Prompt<void> {
  WarningPrompt({required this.title, required this.message});
  final String title;
  final String message;
}

/// FIFO of prompts shown one at a time.
class PromptQueue extends ChangeNotifier {
  final List<Prompt<Object?>> _items = [];

  Prompt<Object?>? get current => _items.isEmpty ? null : _items.first;
  int get length => _items.length;

  /// Queues [prompt]; it leaves the queue when resolved.
  Future<T> push<T>(Prompt<T> prompt) {
    _items.add(prompt as Prompt<Object?>);
    notifyListeners();
    unawaited(prompt.result.whenComplete(() {
      _items.remove(prompt);
      notifyListeners();
    }));
    return prompt.result;
  }

  /// Drops every unresolved prompt of type [P] (e.g. when its session ended).
  void cancelWhere(bool Function(Prompt<Object?> p) test) {
    for (final p in _items.where(test).toList()) {
      switch (p) {
        case AcceptRequestPrompt():
          p.resolve(ApprovalResult.denied);
        case ReverseOfferPrompt():
          p.resolve(false);
        case FirstContactPrompt():
          p.resolve(false);
        case WarningPrompt():
          p.resolve(null);
      }
    }
  }
}
