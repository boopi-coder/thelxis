import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/platform/host_platform.dart';
import 'package:thelxis/protocol/control_messages.dart';
import 'package:thelxis/protocol/models.dart';

import 'support/host_rig.dart';

/// Injector that, like the Windows one, can report that the OS refuses events.
class _ReportingInput extends InputRecorder implements InjectionReport {
  @override
  bool injectionRejected = false;
}

const _tick = Duration(milliseconds: 20);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.sink = (_, _) {};

  late HostRig r;
  tearDown(() => r.tearDown());

  Future<void> authorize() async {
    r.open();
    r.session.debugReceiveControl(await r.passwordAuth(r.creds.oneTimePassword));
    await r.nextOf('displays');
  }

  List<Map<String, dynamic>> states() => r.sent.where((m) => m['t'] == 'input_state').toList();

  group('missing OS permission (macOS Accessibility, Android accessibility service)', () {
    setUp(() async {
      r = HostRig();
      await r.setUp(inputCheckInterval: _tick);
      r.platform.inputControlStatus = PermissionStatus.denied;
    });

    test('control granted without the grant: the viewer is told, and the OS prompt is raised exactly once', () async {
      await authorize();
      final msg = await r.nextOf('input_state');
      expect(msg, {'t': 'input_state', 'ok': false, 'reason': 'permission'});
      expect(r.session.inputIssue, InputIssue.permission);
      expect(r.platform.permissionRequests, [HostPermission.inputControl]);

      // Several re-check periods later: still one prompt, one message.
      await Future<void>.delayed(_tick * 6);
      expect(r.platform.permissionRequests, hasLength(1));
      expect(states(), hasLength(1));
    });

    test('granting the permission mid-session reports ok:true within one re-check', () async {
      await authorize();
      await r.nextOf('input_state');
      r.platform.inputControlStatus = PermissionStatus.granted;
      await untilTrue(() => states().length == 2);
      expect(states().last, {'t': 'input_state', 'ok': true});
      expect(r.session.inputIssue, isNull);
    });

    test('revoking it again prompts again', () async {
      await authorize();
      await r.nextOf('input_state');
      r.platform.inputControlStatus = PermissionStatus.granted;
      await untilTrue(() => states().length == 2);
      r.platform.inputControlStatus = PermissionStatus.denied;
      await untilTrue(() => states().length == 3);
      expect(states().last['reason'], 'permission');
      expect(r.platform.permissionRequests, hasLength(2));
    });

    test('a viewer without control is not nagged about a permission it cannot use', () async {
      await r.tearDown();
      r = HostRig();
      await r.setUp(inputCheckInterval: _tick, reverse: const Permissions(control: false));
      r.platform.inputControlStatus = PermissionStatus.denied;
      r.open();
      r.session.debugReceiveControl({'t': 'auth', 'method': 'request'});
      await r.nextOf('displays');
      await Future<void>.delayed(_tick * 4);
      expect(states(), isEmpty);
      expect(r.platform.permissionRequests, isEmpty);
    });

    test('pausing control stops the checks; resuming them re-reports the problem', () async {
      await authorize();
      await r.nextOf('input_state');
      r.session.setControlAllowed(false);
      expect(r.session.inputIssue, isNull);
      final before = r.platform.permissionRequests.length;
      await Future<void>.delayed(_tick * 4);
      expect(states(), hasLength(1), reason: 'nothing while paused');

      r.session.setControlAllowed(true);
      await untilTrue(() => states().length == 2);
      expect(states().last['reason'], 'permission');
      expect(r.platform.permissionRequests.length, before + 1);
    });
  });

  group('healthy host', () {
    test('sends nothing when input works', () async {
      r = HostRig();
      await r.setUp(inputCheckInterval: _tick);
      await authorize();
      await Future<void>.delayed(_tick * 5);
      expect(states(), isEmpty);
      expect(r.session.inputIssue, isNull);
      expect(r.platform.permissionRequests, isEmpty);
    });
  });

  group('input rejected by the OS (Windows UIPI)', () {
    late _ReportingInput injector;

    setUp(() async {
      injector = _ReportingInput();
      r = HostRig();
      await r.setUp(inputCheckInterval: _tick, recorder: injector);
    });

    test('reports blocked while the OS refuses, and recovers when it stops', () async {
      injector.injectionRejected = true;
      await authorize();
      expect(await r.nextOf('input_state'), {'t': 'input_state', 'ok': false, 'reason': 'blocked'});
      expect(r.session.inputIssue, InputIssue.blocked);
      expect(r.platform.permissionRequests, isEmpty, reason: 'there is no permission to ask for');

      injector.injectionRejected = false;
      await untilTrue(() => states().length == 2);
      expect(states().last, {'t': 'input_state', 'ok': true});
    });

    test('also catches a block that starts mid-session', () async {
      await authorize();
      await Future<void>.delayed(_tick * 2);
      expect(states(), isEmpty);
      injector.injectionRejected = true;
      await untilTrue(() => states().isNotEmpty);
      expect(states().single['reason'], 'blocked');
    });

    test('ending the session stops the checks', () async {
      injector.injectionRejected = true;
      await authorize();
      await r.nextOf('input_state');
      await r.session.end('user');
      final count = states().length;
      injector.injectionRejected = false;
      await Future<void>.delayed(_tick * 4);
      expect(states(), hasLength(count));
    });
  });
}
