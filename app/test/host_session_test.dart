import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/platform/impl/android_host.dart' show CapturePermissionDenied;
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/session/prompts.dart';
import 'package:thelxis/session/session_base.dart';

import 'support/host_rig.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.sink = (_, _) {};

  // Clipboard goes through the platform channel; keep a fake system clipboard.
  String? systemClipboard = '';
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') return <String, dynamic>{'text': systemClipboard};
        if (call.method == 'Clipboard.setData') {
          systemClipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
  });
  setUp(() => systemClipboard = '');

  late HostRig r;
  setUp(() async {
    r = HostRig();
    await r.setUp();
  });
  tearDown(() => r.tearDown());

  test('hello offers password and request, with a fresh 32-byte nonce', () {
    r.open();
    final hello = r.hello();
    expect(hello['v'], 2);
    expect(hello['methods'], ['password', 'request']);
    expect((hello['nonce'] as String).length, greaterThanOrEqualTo(40));
    expect(r.session.phase, SessionPhase.authenticating);
  });

  test('a trusted viewer is offered the trusted method', () async {
    await r.trusted.add(key: r.viewerId.publicKeyB64, id: r.viewerId.id, name: 'Alice', permissions: const Permissions());
    r.open();
    expect(r.hello()['methods'], ['trusted', 'password', 'request']);
  });

  test('video and input are withheld until authorization', () async {
    r.open();
    r.session.debugReceiveInput({'t': 'mm', 'x': 0.5, 'y': 0.5});
    r.session.debugReceiveControl({'t': 'select_display', 'id': '0'});
    r.session.debugReceiveControl({'t': 'quality', 'preset': 'speed'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(r.input.calls, isEmpty);
    expect(r.streams, isEmpty);
    expect(r.platform.beforeCaptureCalls, 0);
    expect(r.sent.where((m) => m['t'] == 'displays'), isEmpty);
  });

  test('the one-time password authorizes, capture starts, displays follow, OTP rotates after the session', () async {
    final otp = r.creds.oneTimePassword;
    r.open();
    r.session.debugReceiveControl(await r.passwordAuth(otp));
    final result = await r.nextOf('auth_result');
    expect(result['ok'], isTrue);
    expect(result['trusted'], isFalse);
    expect(result['permissions'], {'view': true, 'control': true, 'clipboard': true, 'files': true, 'audio': false});
    final displays = await r.nextOf('displays');
    expect((displays['items'] as List).single['name'], 'Display 1');
    expect(displays['active'], '0');
    // auth_result must precede displays.
    expect(r.sent.indexWhere((m) => m['t'] == 'auth_result'), lessThan(r.sent.indexWhere((m) => m['t'] == 'displays')));
    expect(r.session.phase, SessionPhase.active);
    expect(r.platform.beforeCaptureCalls, 1);
    expect(r.streams, hasLength(1));

    await r.session.end('user');
    expect(r.creds.oneTimePassword, isNot(otp), reason: 'rotated after a successful password session');
    expect(r.streams.single.disposed, isTrue);
    expect(r.streams.single.track.stopped, isTrue);
    expect(r.platform.afterCaptureCalls, 1);
    expect(r.pair.gotBye, isTrue);
  });

  test('a wrong password is refused with retry and nothing starts', () async {
    r.open();
    r.session.debugReceiveControl(await r.passwordAuth('definitely wrong'));
    final result = await r.nextOf('auth_result');
    expect(result, {'t': 'auth_result', 'ok': false, 'reason': 'bad_password', 'retry': true});
    expect(r.streams, isEmpty);
    expect(r.session.phase, isNot(SessionPhase.ended));
  });

  test('five wrong passwords lock the host and end the session', () async {
    r.open();
    for (var i = 0; i < 5; i++) {
      r.session.debugReceiveControl(await r.passwordAuth('wrong$i'));
      await untilTrue(() => r.sent.where((m) => m['t'] == 'auth_result').length == i + 1);
    }
    final last = r.sent.where((m) => m['t'] == 'auth_result').last;
    expect(last['retry'], isFalse);
    r.session.debugReceiveControl(await r.passwordAuth(r.creds.oneTimePassword));
    final locked = await r.nextOf('auth_result', after: r.sent.length - 1);
    expect(locked['reason'], anyOf('locked', 'bad_password'));
  });

  test('an accepted request grants the chosen permissions and can add the viewer to Trusted Devices', () async {
    r.approval = (p) async {
      expect(p.peer.name, 'Alice Mac');
      expect(p.claimedUser, 'Alice');
      return const ApprovalResult(
        accepted: true,
        alwaysAllow: true,
        permissions: Permissions(control: false),
      );
    };
    r.open();
    r.session.debugReceiveControl({'t': 'auth', 'method': 'request', 'user': 'Alice'});
    final result = await r.nextOf('auth_result');
    expect(result['ok'], isTrue);
    expect(result['trusted'], isTrue);
    expect((result['permissions'] as Map)['control'], isFalse);
    expect(r.trusted.isTrusted(r.viewerId.publicKeyB64), isTrue);
    expect(r.trusted.permissionsFor(r.viewerId.publicKeyB64)!.control, isFalse);
  });

  test('a denied request ends the session with reason denied', () async {
    r.approval = (p) async => ApprovalResult.denied;
    r.open();
    r.session.debugReceiveControl({'t': 'auth', 'method': 'request', 'user': 'Mallory'});
    final result = await r.nextOf('auth_result');
    expect(result['reason'], 'denied');
    await untilTrue(() => r.session.isEnded);
    expect(r.session.endReason, 'denied');
    await untilTrue(() => r.pair.gotBye);
    expect(r.pair.byeReason, 'denied');
    expect(r.streams, isEmpty);
  });

  test('a viewer that hangs up on reading the refusal does not turn "denied" into "remote"', () async {
    r.approval = (p) async => ApprovalResult.denied;
    r.open();
    r.session.debugReceiveControl({'t': 'auth', 'method': 'request', 'user': 'Mallory'});
    await r.nextOf('auth_result');
    r.session.debugReceiveControl({'t': 'bye', 'reason': 'user'});
    await untilTrue(() => r.session.isEnded);
    expect(r.session.endReason, 'denied');
  });

  test('a second end() joins the one in flight, so awaiting it means the session has ended', () async {
    r.open();
    final first = r.session.end('remote');
    final second = r.session.end('user');
    expect(identical(first, second), isTrue);
    await second;
    expect(r.session.isEnded, isTrue);
    expect(r.session.endReason, 'remote', reason: 'the first reason wins');
  });

  test('a trusted viewer connects without any prompt', () async {
    await r.trusted.add(key: r.viewerId.publicKeyB64, id: r.viewerId.id, name: 'Alice', permissions: const Permissions());
    r.approval = (p) async => fail('no prompt expected for a trusted device');
    r.open();
    r.session.debugReceiveControl({'t': 'auth', 'method': 'trusted'});
    final result = await r.nextOf('auth_result');
    expect(result['ok'], isTrue);
    expect(result['trusted'], isTrue);
  });

  test('refused screen capture reports not_allowed, tells the user, and ends', () async {
    r.captureError = const CapturePermissionDenied('declined');
    r.open();
    r.session.debugReceiveControl(await r.passwordAuth(r.creds.oneTimePassword));
    final result = await r.nextOf('auth_result');
    expect(result['ok'], isFalse);
    expect(result['reason'], 'not_allowed');
    await untilTrue(() => r.session.isEnded);
    expect(r.session.endReason, 'denied');
    expect(r.notices, ['Screen sharing was not allowed']);
    expect(r.platform.afterCaptureCalls, r.platform.beforeCaptureCalls);
  });

  group('after authorization', () {
    Future<void> authorize([Permissions? perms]) async {
      r.approval = (p) async => ApprovalResult(accepted: true, permissions: perms ?? const Permissions());
      r.open();
      r.session.debugReceiveControl({'t': 'auth', 'method': 'request', 'user': 'A'});
      await r.nextOf('displays');
    }

    test('input reaches the injector, normalised to the active display', () async {
      await authorize();
      r.session.debugReceiveInput({'t': 'mm', 'x': 0.25, 'y': 0.5});
      r.session.debugReceiveInput({'t': 'md', 'b': 0, 'x': 0.25, 'y': 0.5});
      r.session.debugReceiveInput({'t': 'kd', 'c': 458756});
      expect(r.input.calls, ['move 0 0.25 0.5', 'move 0 0.25 0.5', 'btn left true', 'key 458756 true']);
    });

    test('without the control permission nothing is injected', () async {
      await authorize(const Permissions(control: false));
      r.session.debugReceiveInput({'t': 'mm', 'x': 0.25, 'y': 0.5});
      r.session.debugReceiveInput({'t': 'kd', 'c': 458756});
      expect(r.input.calls, isEmpty);
    });

    test('pausing control releases held keys and tells the viewer', () async {
      await authorize();
      r.session.debugReceiveInput({'t': 'kd', 'c': 0x700E0});
      r.session.debugReceiveInput({'t': 'md', 'b': 2, 'x': 0.5, 'y': 0.5});
      r.input.calls.clear();
      r.session.setControlAllowed(false);
      expect(r.input.calls, containsAll(['key ${0x700E0} false', 'btn right false', 'releaseAll']));
      final msg = r.sent.lastWhere((m) => m['t'] == 'permissions');
      expect((msg['permissions'] as Map)['control'], isFalse);
      r.input.calls.clear();
      r.session.debugReceiveInput({'t': 'mm', 'x': 0.1, 'y': 0.1});
      expect(r.input.calls, isEmpty);
    });

    test('ending the session releases everything the viewer still held', () async {
      await authorize();
      r.session.debugReceiveInput({'t': 'kd', 'c': 0x70004});
      r.input.calls.clear();
      await r.session.end('user');
      expect(r.input.calls, contains('key ${0x70004} false'));
      expect(r.input.calls.last, 'releaseAll');
    });

    test('quality presets: 60 fps needs a new capture, others only change sender limits', () async {
      await authorize();
      expect(r.captureFps, [30]);
      r.session.debugReceiveControl({'t': 'quality', 'preset': 'quality'});
      await untilTrue(() => r.captureFps.length == 2);
      expect(r.captureFps.last, 60);
      expect(r.session.quality.name, 'quality');
      await untilTrue(() => r.streams.first.disposed); // the previous capture is stopped
      r.session.debugReceiveControl({'t': 'quality', 'preset': 'speed'});
      await untilTrue(() => r.captureFps.length == 3);
      expect(r.captureFps.last, 30);
      r.session.debugReceiveControl({'t': 'quality', 'preset': 'balanced'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(r.captureFps, hasLength(3), reason: '30 fps -> 30 fps keeps the capture');
    });

    test('clipboard text is applied only when permitted, and never echoed back', () async {
      await authorize();
      r.session.debugReceiveControl({'t': 'clipboard', 'text': 'from viewer'});
      await untilTrue(() => systemClipboard == 'from viewer');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(r.sent.where((m) => m['t'] == 'clipboard'), isEmpty, reason: 'no echo');
      systemClipboard = 'copied on host';
      await untilTrue(() => r.sent.any((m) => m['t'] == 'clipboard'));
      expect(r.sent.firstWhere((m) => m['t'] == 'clipboard')['text'], 'copied on host');
    });

    test('clipboard is ignored without the permission', () async {
      await authorize(const Permissions(clipboard: false));
      r.session.debugReceiveControl({'t': 'clipboard', 'text': 'sneaky'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(systemClipboard, '');
    });

    test('a viewer bye ends the session', () async {
      await authorize();
      r.session.debugReceiveControl({'t': 'bye', 'reason': 'user'});
      await untilTrue(() => r.session.isEnded);
      expect(r.session.endReason, 'remote');
    });
  });

  group('multi-monitor', () {
    setUp(() async {
      await r.tearDown();
      r = HostRig();
      await r.setUp(displays: 2);
    });

    test('displays are advertised and switching re-captures, updates input mapping and the active id', () async {
      r.approval = (p) async => const ApprovalResult(accepted: true, permissions: Permissions());
      r.open();
      r.session.debugReceiveControl({'t': 'auth', 'method': 'request'});
      final first = await r.nextOf('displays');
      expect((first['items'] as List), hasLength(2));
      expect(first['active'], '0');

      r.session.debugReceiveControl({'t': 'select_display', 'id': '1'});
      await untilTrue(() => r.sent.where((m) => m['t'] == 'displays').length == 2);
      expect(r.sent.where((m) => m['t'] == 'displays').last['active'], '1');
      expect(r.streams, hasLength(2));
      await untilTrue(() => r.streams.first.disposed);

      r.session.debugReceiveInput({'t': 'mm', 'x': 0.5, 'y': 0.5});
      expect(r.input.calls.last, 'move 1 0.5 0.5');

      r.session.debugReceiveControl({'t': 'select_display', 'id': '99'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(r.streams, hasLength(2), reason: 'unknown display ids are ignored');
    });
  });

  group('reverse mode (this host dialed out)', () {
    setUp(() async {
      await r.tearDown();
      r = HostRig();
      await r.setUp(reverse: const Permissions(control: false));
    });

    test('only "request" is offered and it is granted with the preset permissions', () async {
      r.approval = (p) async => fail('the user already consented by offering');
      r.open();
      expect(r.hello()['methods'], ['request']);
      r.session.debugReceiveControl({'t': 'auth', 'method': 'request', 'user': 'Bob'});
      final result = await r.nextOf('auth_result');
      expect(result['ok'], isTrue);
      expect((result['permissions'] as Map)['control'], isFalse);
    });

    test('passwords are not accepted in reverse mode', () async {
      r.open();
      r.session.debugReceiveControl(await r.passwordAuth(r.creds.oneTimePassword));
      final result = await r.nextOf('auth_result');
      expect(result['reason'], 'not_allowed');
    });
  });

  test('a session that never authenticates is not granted video', () async {
    r.open();
    r.session.debugReceiveControl({'t': 'auth', 'method': 'magic'});
    final result = await r.nextOf('auth_result');
    expect(result['reason'], 'not_allowed');
    expect(r.streams, isEmpty);
  });
}
