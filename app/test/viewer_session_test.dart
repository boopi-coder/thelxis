import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCIceConnectionState;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/core/password_proof.dart';
import 'package:thelxis/core/settings.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/session/session_base.dart';
import 'package:thelxis/session/viewer_session.dart';

import 'support/channel_pair.dart';

const _viewerFp = 'sha-256 11:22'; // the viewer's own (local) fingerprint
const _hostFp = 'sha-256 99:88';

Future<void> _until(bool Function() cond) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > const Duration(seconds: 8)) throw StateError('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.sink = (_, _) {};

  late Identity host;
  late Identity viewer;
  late ChannelPair pair;
  late ViewerSession session;
  final control = <Map<String, dynamic>>[];
  final input = <Map<String, dynamic>>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    host = await Identity.fromSeed(List<int>.filled(32, 21));
    viewer = await Identity.fromSeed(List<int>.filled(32, 22));
    pair = await ChannelPair.create(self: viewer, peerKey: host.publicKeyB64);
    control.clear();
    input.clear();
    session = ViewerSession(
      env: ViewerEnv(settings: AppSettings(prefs, defaultDeviceName: 'Mac'), userName: 'Alice (MacBook)'),
      peer: PeerIdentity(key: host.publicKeyB64, id: host.id, name: 'Office PC', os: 'windows'),
      sid: 'sid',
      channel: pair.channel,
    )
      ..debugControlTap = control.add
      ..debugInputTap = input.add
      ..debugFingerprints = () async => (local: _viewerFp, remote: _hostFp);
  });

  tearDown(() async {
    await session.end('user');
    await pair.close();
    session.dispose();
  });

  void hello(List<String> methods, {String nonce = 'bm9uY2U'}) =>
      session.debugReceiveControl({'t': 'hello', 'v': 2, 'methods': methods, 'nonce': nonce});

  void authOk({Map<String, dynamic>? perms, bool trusted = false}) => session.debugReceiveControl({
        't': 'auth_result',
        'ok': true,
        'trusted': trusted,
        'permissions': perms ?? {'view': true, 'control': true, 'clipboard': true, 'files': true},
      });

  test('with a password-only host the user is asked, and the proof binds nonce and fingerprints', () async {
    hello(['password']);
    expect(session.phase, SessionPhase.authenticating);
    expect(session.authPrompt, isNotNull);
    expect(session.authPrompt!.canPassword, isTrue);
    expect(session.authPrompt!.canRequest, isFalse);
    expect(control, isEmpty, reason: 'nothing is sent before the user acts');

    await session.submitPassword('k7m2p9xq');
    expect(control, hasLength(1));
    expect(control.single['t'], 'auth');
    expect(control.single['method'], 'password');
    final expected = await computePasswordProofB64(
      key: await derivePasswordKeySync('k7m2p9xq', host.id),
      nonce: 'bm9uY2U',
      fingerprintA: _hostFp,
      fingerprintB: _viewerFp,
    );
    expect(control.single['proof'], expected);
    expect(control.single.containsKey('password'), isFalse, reason: 'the password itself never leaves');
    expect(session.authPrompt, isNull);
  });

  test('a host that trusts this device is tried first, and falls back to the prompt', () {
    hello(['trusted', 'password', 'request']);
    expect(control.single, {'t': 'auth', 'method': 'trusted'});
    expect(session.authPrompt, isNull);
    session.debugReceiveControl({'t': 'auth_result', 'ok': false, 'reason': 'not_trusted', 'retry': true});
    expect(session.authPrompt, isNotNull);
    expect(session.authPrompt!.canPassword && session.authPrompt!.canRequest, isTrue);
    expect(control, hasLength(1), reason: 'trusted is only attempted once');
  });

  test('a request-only host gets the request immediately, with the user name', () {
    hello(['request']);
    expect(control.single, {'t': 'auth', 'method': 'request', 'user': 'Alice (MacBook)'});
    expect(session.phase, SessionPhase.awaitingApproval);
    expect(session.authPrompt, isNull);
  });

  test('"Request access instead" sends a request from the password prompt', () {
    hello(['password', 'request']);
    session.requestAccess();
    expect(control.single['method'], 'request');
    expect(session.phase, SessionPhase.awaitingApproval);
  });

  test('wrong password with retry shows an error and keeps the session', () {
    hello(['password', 'request']);
    session.debugReceiveControl({'t': 'auth_result', 'ok': false, 'reason': 'bad_password', 'retry': true});
    expect(session.authPrompt!.error, contains('Wrong password'));
    expect(session.isEnded, isFalse);
  });

  test('locked ends the session with an explanation', () async {
    hello(['password']);
    session.debugReceiveControl({'t': 'auth_result', 'ok': false, 'reason': 'locked', 'retry': false});
    await _until(() => session.isEnded);
    expect(session.notice, contains('5 minutes'));
  });

  test('denied ends the session and tells the user', () async {
    hello(['request']);
    session.debugReceiveControl({'t': 'auth_result', 'ok': false, 'reason': 'denied', 'retry': false});
    await _until(() => session.isEnded);
    expect(session.endReason, 'denied');
    expect(session.notice, contains('denied'));
    await _until(() => pair.gotBye);
    expect(pair.byeReason, 'denied');
  });

  test('not_allowed (host could not start sharing) is explained', () async {
    hello(['request']);
    session.debugReceiveControl({'t': 'auth_result', 'ok': false, 'reason': 'not_allowed', 'retry': false});
    await _until(() => session.isEnded);
    expect(session.notice, contains('screen sharing'));
  });

  group('authorized', () {
    setUp(() {
      hello(['request']);
      authOk();
      control.clear();
    });

    test('becomes active with the granted permissions', () {
      expect(session.phase, SessionPhase.active);
      expect(session.permissions, const Permissions());
      expect(session.viewOnly, isFalse);
      expect(session.becameTrusted, isFalse);
    });

    test('the host adding this device to its trusted list is surfaced', () {
      authOk(trusted: true);
      expect(session.becameTrusted, isTrue);
    });

    test('input is sent only while controlling', () {
      session.encoder.mouseMove(0.5, 0.5);
      session.encoder.keyDown(0x70004);
      expect(input.map((m) => m['t']), ['mm', 'kd']);
      input.clear();
      session.setViewOnly(true);
      expect(input.map((m) => m['t']), ['ku'], reason: 'held keys are released before going view-only');
      input.clear();
      session.encoder.mouseMove(0.1, 0.1);
      session.encoder.tapKey(0x70005);
      expect(input, isEmpty);
      expect(session.userViewOnly, isTrue);
      session.setViewOnly(false);
      session.encoder.keyDown(0x70006);
      expect(input.single['c'], 0x70006);
    });

    test('a host without control permission means view-only regardless of the toggle', () {
      session.debugReceiveControl({'t': 'permissions', 'permissions': {'view': true, 'control': false}});
      expect(session.viewOnly, isTrue);
      session.encoder.keyDown(1);
      expect(input, isEmpty);
    });

    test('revoking control releases held keys on the wire first', () {
      session.encoder.keyDown(0x700E0);
      input.clear();
      session.debugReceiveControl({'t': 'permissions', 'permissions': {'view': true, 'control': false}});
      expect(input.single, {'t': 'ku', 'c': 0x700E0});
    });

    test('displays, display selection and quality', () {
      session.debugReceiveControl({
        't': 'displays',
        'items': [
          {'id': '0', 'name': 'Display 1', 'width': 2560, 'height': 1440, 'primary': true},
          {'id': '1', 'name': 'Display 2', 'width': 1920, 'height': 1080},
        ],
        'active': '1',
      });
      expect(session.displays, hasLength(2));
      expect(session.activeDisplayId, '1');
      expect(session.activeDisplay!.width, 1920);
      session.selectDisplay('0');
      session.setQuality(QualityPreset.speed);
      expect(control, [
        {'t': 'select_display', 'id': '0'},
        {'t': 'quality', 'preset': 'speed'},
      ]);
      expect(session.quality, QualityPreset.speed);
    });

    test('chat from the host is kept; chat to the host is sent', () {
      session.debugReceiveControl({'t': 'chat', 'text': 'hello'});
      session.sendChat('hi back');
      session.sendChat('   ');
      expect(session.chatLog, ['hello', 'me: hi back']);
      expect(control, [
        {'t': 'chat', 'text': 'hi back'},
      ]);
    });

    test('a host bye ends the session', () async {
      session.debugReceiveControl({'t': 'bye', 'reason': 'user'});
      await _until(() => session.isEnded);
      expect(session.endReason, 'remote');
    });
  });

  group('connection state', () {
    setUp(() {
      hello(['request']);
      authOk();
    });

    test('ICE loss shows reconnecting and recovery returns to active', () {
      session.debugIceState(RTCIceConnectionState.RTCIceConnectionStateDisconnected);
      expect(session.phase, SessionPhase.reconnecting);
      session.debugIceState(RTCIceConnectionState.RTCIceConnectionStateFailed);
      expect(session.phase, SessionPhase.reconnecting);
      session.debugIceState(RTCIceConnectionState.RTCIceConnectionStateConnected);
      expect(session.phase, SessionPhase.active);
    });

    test('ending is idempotent and sends bye to the host', () async {
      await session.end('user');
      await session.end('user');
      expect(session.isEnded, isTrue);
      await _until(() => pair.gotBye);
      expect(pair.byeReason, 'user');
      expect(session.endReason, 'user');
    });
  });

  test('a second end() joins the one in flight, so awaiting it means the session has ended', () async {
    final first = session.end('remote');
    final second = session.end('user');
    expect(identical(first, second), isTrue);
    await second;
    expect(session.isEnded, isTrue);
    expect(session.endReason, 'remote', reason: 'the first reason wins');
  });

  test('debug seams are visible for testing only', () {
    expect(session.debugControlTap, isNotNull);
    expect(kDebugMode, isTrue);
  });
}
