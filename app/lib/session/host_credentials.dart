
import 'package:flutter/foundation.dart';

import '../core/identity.dart';
import '../core/log.dart';
import '../core/one_time_password.dart';
import '../core/password_proof.dart';
import '../core/settings.dart';
import 'password_guard.dart';

const _log = Logger('credentials');

/// The passwords a host accepts: the rotating one-time password shown on the
/// Home screen and the optional permanent (unattended) password.
class HostCredentials extends ChangeNotifier {
  HostCredentials({required this.identity, required this.settings}) {
    _newOtp();
  }

  final Identity identity;
  final AppSettings settings;
  final PasswordGuard guard = PasswordGuard();

  late String _otp;
  late Future<Uint8List> _otpKey;

  /// Current one-time password (shown in the UI).
  String get oneTimePassword => _otp;

  /// PBKDF2 key of the current one-time password. Derived off the UI isolate
  /// as soon as the password is generated, so verification is instant.
  Future<Uint8List> get oneTimeKey => _otpKey;

  /// Key of the permanent password, if one is set.
  List<int>? get permanentKey => settings.unattendedKey;

  void rotate() {
    _newOtp();
    notifyListeners();
  }

  /// Called after a successful session.
  void onSessionSucceeded() {
    if (settings.rotateOneTimePassword) rotate();
  }

  Future<void> setPermanentPassword(String password) async {
    final key = await derivePasswordKey(password, identity.id);
    await settings.setUnattendedKey(key);
    notifyListeners();
  }

  Future<void> clearPermanentPassword() async {
    await settings.setUnattendedKey(null);
    notifyListeners();
  }

  void _newOtp() {
    _otp = generateOneTimePassword();
    _otpKey = derivePasswordKey(_otp, identity.id).catchError((Object e) {
      _log.e('one-time key derivation failed', e);
      return Uint8List(0);
    });
  }
}
