import 'package:flutter/foundation.dart';

import '../session/viewer_session.dart';

/// Navigation state of the main window: which page is shown and which
/// outgoing session (if any) is in front.
class ShellController extends ChangeNotifier {
  ShellController({this._pendingInvite});

  int _page = 0;
  ViewerSession? _front;
  String? _pendingInvite;

  /// Returns (once) an invite link the app was launched with, so the Connect
  /// field can show it.
  String? takePendingInvite() {
    final v = _pendingInvite;
    _pendingInvite = null;
    return v;
  }

  static const int pageHome = 0;
  static const int pageDevices = 1;
  static const int pageSessions = 2;
  static const int pageSettings = 3;

  int get page => _page;

  /// The session shown full-window, or null when a page is shown.
  ViewerSession? get front => _front;

  void goTo(int page) {
    if (_page == page && _front == null) return;
    _page = page;
    _front = null;
    notifyListeners();
  }

  void showSession(ViewerSession session) {
    _front = session;
    notifyListeners();
  }

  /// Back to the pages without ending the session.
  void showPages() {
    if (_front == null) return;
    _front = null;
    notifyListeners();
  }

  void sessionClosed(ViewerSession session) {
    if (_front == session) {
      _front = null;
      notifyListeners();
    }
  }
}
