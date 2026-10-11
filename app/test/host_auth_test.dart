import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/password_proof.dart';
import 'package:thelxis/core/settings.dart';
import 'package:thelxis/core/trusted_devices.dart';
import 'package:thelxis/protocol/control_messages.dart';
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/session/host_auth.dart';
import 'package:thelxis/session/host_credentials.dart';
import 'package:thelxis/session/password_guard.dart';

const _fpLocal = 'sha-256 AA:BB';
const _fpRemote = 'sha-256 CC:DD';
const _nonce = 'bm9uY2U';

void main() {
  late Identity host;
  late AppSettings settings;
  late TrustedDevices trusted;
  late HostCredentials creds;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    host = await Identity.fromSeed(List<int>.generate(32, (i) => i + 1));
    settings = AppSettings(prefs, defaultDeviceName: 'Test PC');
    trusted = TrustedDevices(prefs);
    creds = HostCredentials(identity: host, settings: settings);
  });

  HostAuthenticator authFor({
    String peerKey = 'peer-key',
    bool requireApproval = false,
    bool inputSupported = true,
    Permissions? reverse,
  }) =>
      HostAuthenticator(
        nonce: _nonce,
        peerKey: peerKey,
        trust: trusted,
        credentials: creds,
        requireApproval: requireApproval,
        defaultPermissions: const Permissions(),
        inputSupported: inputSupported,
        preApprovedPermissions: reverse,
      );

  Future<AuthMessage> proofFor(String password) async => AuthMessage.password(
        await computePasswordProofB64(
          key: await derivePasswordKeySync(password, host.id),
          nonce: _nonce,
          fingerprintA: _fpLocal,
          fingerprintB: _fpRemote,
        ),
      );

  Future<AuthDecision> evaluate(HostAuthenticator a, AuthMessage m) =>
      a.evaluate(m, localFingerprint: _fpLocal, remoteFingerprint: _fpRemote);

  group('methods', () {
    test('password and request are always offered; trusted only for a trusted key', () async {
      expect(authFor().methods, ['password', 'request']);
      await trusted.add(key: 'peer-key', id: 'X', name: 'N', permissions: const Permissions());
      expect(authFor().methods, ['trusted', 'password', 'request']);
      expect(authFor(peerKey: 'someone-else').methods, ['password', 'request']);
    });

    test('reverse mode offers only request', () {
      expect(authFor(reverse: const Permissions()).methods, ['request']);
    });
  });

  group('one-time password', () {
    test('the current one-time password is accepted and bound to the session', () async {
      final a = authFor();
      final ok = await evaluate(a, await proofFor(creds.oneTimePassword));
      expect(ok, isA<AuthGrant>());
      expect((ok as AuthGrant).permissions, const Permissions());
    });

    test('a wrong password is refused with retry, a replayed proof from another session is refused', () async {
      final a = authFor();
      final bad = await evaluate(a, await proofFor('wrong-password'));
      expect(bad, isA<AuthDeny>());
      expect((bad as AuthDeny).reason, 'bad_password');
      expect(bad.retry, isTrue);

      final proof = await proofFor(creds.oneTimePassword);
      final other = HostAuthenticator(
        nonce: 'different-nonce',
        peerKey: 'peer-key',
        trust: trusted,
        credentials: creds,
        requireApproval: false,
        defaultPermissions: const Permissions(),
        inputSupported: true,
      );
      expect(await evaluate(other, proof), isA<AuthDeny>());
    });

    test('rotating invalidates the old password', () async {
      final old = creds.oneTimePassword;
      creds.rotate();
      expect(creds.oneTimePassword, isNot(old));
      expect(await evaluate(authFor(), await proofFor(old)), isA<AuthDeny>());
      expect(await evaluate(authFor(), await proofFor(creds.oneTimePassword)), isA<AuthGrant>());
    });
  });

  group('permanent password', () {
    test('works alongside the one-time password and is stored only as a key', () async {
      await creds.setPermanentPassword('correct horse battery');
      expect(settings.hasPermanentPassword, isTrue);
      expect(await evaluate(authFor(), await proofFor('correct horse battery')), isA<AuthGrant>());
      expect(await evaluate(authFor(), await proofFor('correct horse')), isA<AuthDeny>());
      await creds.clearPermanentPassword();
      expect(await evaluate(authFor(), await proofFor('correct horse battery')), isA<AuthDeny>());
    });
  });

  group('lockout', () {
    test('5 failures lock password auth; correct password is then refused too', () async {
      final a = authFor();
      for (var i = 0; i < 5; i++) {
        final r = await evaluate(a, await proofFor('nope$i'));
        expect((r as AuthDeny).reason, 'bad_password');
        if (i < 4) expect(r.retry, isTrue);
      }
      final locked = await evaluate(a, await proofFor(creds.oneTimePassword));
      expect(locked, isA<AuthDeny>());
      expect((locked as AuthDeny).reason, 'locked');
      expect(locked.retry, isFalse);
    });

    test('PasswordGuard unlocks after the lockout time and counts only recent failures', () {
      var now = DateTime(2030, 1, 1, 12);
      final g = PasswordGuard(clock: () => now);
      for (var i = 0; i < 4; i++) {
        g.recordFailure();
      }
      expect(g.isLocked, isFalse);
      g.recordFailure();
      expect(g.isLocked, isTrue);
      now = now.add(const Duration(minutes: 4, seconds: 59));
      expect(g.isLocked, isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(g.isLocked, isFalse);
      // Old failures expire.
      g.recordFailure();
      now = now.add(const Duration(minutes: 6));
      for (var i = 0; i < 4; i++) {
        g.recordFailure();
      }
      expect(g.isLocked, isFalse);
      g.recordSuccess();
      g.recordFailure();
      expect(g.isLocked, isFalse);
    });
  });

  group('approval', () {
    test('request always needs the local user', () async {
      final r = await evaluate(authFor(), const AuthMessage.request('Alice'));
      expect(r, isA<AuthNeedsApproval>());
      expect((r as AuthNeedsApproval).user, 'Alice');
    });

    test('with "ask before every connection" even a valid password needs approval', () async {
      final r = await evaluate(authFor(requireApproval: true), await proofFor(creds.oneTimePassword));
      expect(r, isA<AuthNeedsApproval>());
    });

    test('approved() applies the chosen permissions and the trust flag', () {
      final a = authFor();
      final g = a.approved(const Permissions(control: false), alwaysAllow: true) as AuthGrant;
      expect(g.permissions.control, isFalse);
      expect(g.trusted, isTrue);
      expect(a.approved(Permissions.none), isA<AuthDeny>());
    });

    test('control is stripped when this system cannot inject input', () async {
      final a = authFor(inputSupported: false);
      expect((a.approved(const Permissions()) as AuthGrant).permissions.control, isFalse);
      expect(((await evaluate(a, await proofFor(creds.oneTimePassword))) as AuthGrant).permissions.control, isFalse);
    });

    test('user names are clipped', () async {
      final r = await evaluate(authFor(), AuthMessage.request('x' * 500));
      expect((r as AuthNeedsApproval).user.length, 64);
    });
  });

  group('trusted devices', () {
    test('a trusted key is granted its stored permissions without a prompt', () async {
      await trusted.add(
        key: 'peer-key',
        id: 'ID',
        name: 'Alice',
        permissions: const Permissions(clipboard: false),
      );
      final r = await evaluate(authFor(), const AuthMessage.trusted());
      expect(r, isA<AuthGrant>());
      expect((r as AuthGrant).trusted, isTrue);
      expect(r.permissions, const Permissions(clipboard: false));
    });

    test('an untrusted key gets not_trusted with retry so the viewer can fall back', () async {
      final r = await evaluate(authFor(peerKey: 'stranger'), const AuthMessage.trusted());
      expect((r as AuthDeny).reason, 'not_trusted');
      expect(r.retry, isTrue);
    });

    test('revoking removes access immediately', () async {
      await trusted.add(key: 'peer-key', id: 'ID', name: 'Alice', permissions: const Permissions());
      await trusted.revoke('peer-key');
      expect((await evaluate(authFor(), const AuthMessage.trusted()) as AuthDeny).reason, 'not_trusted');
    });
  });

  group('reverse mode', () {
    test('request is granted with the preset permissions, password/trusted are refused', () async {
      final a = authFor(reverse: const Permissions(control: false));
      final r = await evaluate(a, const AuthMessage.request('Bob'));
      expect(r, isA<AuthGrant>());
      expect((r as AuthGrant).permissions.control, isFalse);
      expect((await evaluate(a, await proofFor(creds.oneTimePassword)) as AuthDeny).reason, 'not_allowed');
      expect((await evaluate(a, const AuthMessage.trusted()) as AuthDeny).reason, 'not_allowed');
    });
  });

  test('unknown auth methods are refused', () async {
    final r = await evaluate(authFor(), AuthMessage.fromJson({'t': 'auth', 'method': 'magic'}));
    expect((r as AuthDeny).reason, 'not_allowed');
  });
}
