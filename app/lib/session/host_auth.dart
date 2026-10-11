import '../core/password_proof.dart';
import '../core/trusted_devices.dart';
import '../protocol/control_messages.dart';
import '../protocol/models.dart';
import 'host_credentials.dart';

/// Result of evaluating one `auth` message on the host.
sealed class AuthDecision {
  const AuthDecision();
}

/// Grant immediately with [permissions].
class AuthGrant extends AuthDecision {
  const AuthGrant(this.permissions, {this.trusted = false});
  final Permissions permissions;

  /// The viewer was already trusted (reported back in `auth_result`).
  final bool trusted;
}

class AuthDeny extends AuthDecision {
  const AuthDeny(this.reason, {this.retry = false});
  final String reason;
  final bool retry;
}

/// The local user must accept; [method] and [user] describe how the viewer
/// asked. [proofValid] is true when a password was verified first.
class AuthNeedsApproval extends AuthDecision {
  const AuthNeedsApproval({required this.method, this.user = ''});
  final String method;
  final String user;
}

/// Host-side authorization state machine for one session (PROTOCOL.md 6.1).
/// Pure logic: no I/O except PBKDF2-free proof verification.
class HostAuthenticator {
  HostAuthenticator({
    required this.nonce,
    required this.peerKey,
    required this.trust,
    required this.credentials,
    required this.requireApproval,
    required this.defaultPermissions,
    required this.inputSupported,
    this.preApprovedPermissions,
  });

  final String nonce;
  final String peerKey;
  final TrustLookup trust;
  final HostCredentials credentials;
  final bool requireApproval;
  final Permissions defaultPermissions;
  final bool inputSupported;

  /// Reverse mode: the local user already chose to share, so a `request` is
  /// granted with these permissions and nothing else is offered.
  final Permissions? preApprovedPermissions;

  bool get isReverse => preApprovedPermissions != null;

  /// Methods advertised in `hello` ("only what the host currently allows").
  List<String> get methods {
    if (isReverse) return const ['request'];
    return [
      if (trust.isTrusted(peerKey)) 'trusted',
      'password',
      'request',
    ];
  }

  Permissions _clamp(Permissions p) => inputSupported ? p : p.copyWith(control: false);

  /// Evaluates [msg]. [localFingerprint] and [remoteFingerprint] are the DTLS
  /// fingerprints of this session's SDPs.
  Future<AuthDecision> evaluate(
    AuthMessage msg, {
    required String? localFingerprint,
    required String? remoteFingerprint,
  }) async {
    switch (msg.method) {
      case 'trusted':
        if (isReverse) return const AuthDeny('not_allowed');
        if (!trust.isTrusted(peerKey)) return const AuthDeny('not_trusted', retry: true);
        final stored = trust.permissionsFor(peerKey) ?? defaultPermissions;
        return AuthGrant(_clamp(stored), trusted: true);

      case 'request':
        final preset = preApprovedPermissions;
        if (preset != null) return AuthGrant(_clamp(preset));
        return AuthNeedsApproval(method: 'request', user: _clipUser(msg.user));

      case 'password':
        if (isReverse) return const AuthDeny('not_allowed');
        final guard = credentials.guard;
        if (guard.isLocked) return const AuthDeny('locked');
        final proof = msg.proof;
        if (proof == null || localFingerprint == null || remoteFingerprint == null) {
          return const AuthDeny('not_allowed');
        }
        final ok = await _verify(proof, localFingerprint, remoteFingerprint);
        if (!ok) {
          guard.recordFailure();
          return AuthDeny('bad_password', retry: !guard.isLocked);
        }
        guard.recordSuccess();
        if (requireApproval) {
          return const AuthNeedsApproval(method: 'password');
        }
        return AuthGrant(_clamp(defaultPermissions));
    }
    return const AuthDeny('not_allowed');
  }

  /// Applies the outcome of the accept prompt.
  AuthDecision approved(Permissions chosen, {bool alwaysAllow = false}) {
    if (!chosen.view) return const AuthDeny('denied');
    return AuthGrant(_clamp(chosen), trusted: alwaysAllow);
  }

  Future<bool> _verify(String proof, String localFp, String remoteFp) async {
    final otp = await credentials.oneTimeKey;
    if (otp.isNotEmpty &&
        await verifyPasswordProof(
          key: otp,
          nonce: nonce,
          fingerprintA: localFp,
          fingerprintB: remoteFp,
          proof: proof,
        )) {
      return true;
    }
    final permanent = credentials.permanentKey;
    if (permanent != null &&
        await verifyPasswordProof(
          key: permanent,
          nonce: nonce,
          fingerprintA: localFp,
          fingerprintB: remoteFp,
          proof: proof,
        )) {
      return true;
    }
    return false;
  }

  static String _clipUser(String? user) {
    final u = (user ?? '').trim();
    return u.length <= 64 ? u : u.substring(0, 64);
  }
}
