import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/protocol/control_messages.dart';
import 'package:thelxis/protocol/input_messages.dart';
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/protocol/signaling_messages.dart';

Map<String, dynamic> _roundTrip(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

void main() {
  group('control messages', () {
    test('hello', () {
      final m = ControlMessage.parse(_roundTrip(
        const HelloMessage(methods: ['trusted', 'password', 'request'], nonce: 'abc').toJson(),
      ))! as HelloMessage;
      expect(m.methods, ['trusted', 'password', 'request']);
      expect(m.nonce, 'abc');
      expect(m.version, 2);
    });

    test('auth methods', () {
      expect(const AuthMessage.trusted().toJson(), {'t': 'auth', 'method': 'trusted'});
      final pw = ControlMessage.parse(_roundTrip(const AuthMessage.password('PROOF').toJson()))! as AuthMessage;
      expect(pw.method, 'password');
      expect(pw.proof, 'PROOF');
      final rq = ControlMessage.parse(_roundTrip(const AuthMessage.request('Alice').toJson()))! as AuthMessage;
      expect(rq.method, 'request');
      expect(rq.user, 'Alice');
    });

    test('auth_result ok carries permissions and trusted flag', () {
      final m = ControlMessage.parse(_roundTrip(
        const AuthResultMessage.ok(Permissions(control: false), trusted: true).toJson(),
      ))! as AuthResultMessage;
      expect(m.ok, isTrue);
      expect(m.trusted, isTrue);
      expect(m.permissions, const Permissions(control: false));
    });

    test('auth_result failure carries reason and retry', () {
      final m = ControlMessage.parse(_roundTrip(
        const AuthResultMessage.fail('bad_password', retry: true).toJson(),
      ))! as AuthResultMessage;
      expect(m.ok, isFalse);
      expect(m.reason, 'bad_password');
      expect(m.retry, isTrue);
      expect(m.permissions, isNull);
    });

    test('displays', () {
      final m = ControlMessage.parse(_roundTrip(const DisplaysMessage(
        items: [
          DisplayInfo(id: '0', name: 'Display 1', width: 2560, height: 1440, primary: true),
          DisplayInfo(id: '1', name: 'Display 2', width: 1920, height: 1080),
        ],
        active: '1',
      ).toJson()))! as DisplaysMessage;
      expect(m.items, hasLength(2));
      expect(m.items.first.primary, isTrue);
      expect(m.items.last.width, 1920);
      expect(m.active, '1');
    });

    test('select_display, quality, clipboard, chat, permissions, bye', () {
      expect((ControlMessage.parse(_roundTrip(const SelectDisplayMessage('2').toJson()))! as SelectDisplayMessage).id, '2');
      for (final p in QualityPreset.values) {
        expect((ControlMessage.parse(_roundTrip(QualityMessage(p).toJson()))! as QualityMessage).preset, p);
      }
      expect((ControlMessage.parse(_roundTrip(const ClipboardMessage('héllo').toJson()))! as ClipboardMessage).text, 'héllo');
      expect((ControlMessage.parse(_roundTrip(const ChatMessage('hi').toJson()))! as ChatMessage).text, 'hi');
      expect(
        (ControlMessage.parse(_roundTrip(const PermissionsMessage(Permissions.viewOnly).toJson()))! as PermissionsMessage).permissions,
        Permissions.viewOnly,
      );
      expect((ControlMessage.parse(_roundTrip(const ByeMessage('timeout').toJson()))! as ByeMessage).reason, 'timeout');
    });

    test('unknown types and malformed input are ignored', () {
      expect(ControlMessage.parse({'t': 'from_the_future', 'x': 1}), isNull);
      expect(ControlMessage.parse({'t': 'quality', 'preset': 'ludicrous'}), isNull);
      expect(ControlMessage.parse('not a map'), isNull);
      expect(ControlMessage.parse({'no_t': true}), isNull);
    });

    test('unknown fields are ignored', () {
      final m = ControlMessage.parse({'t': 'hello', 'v': 2, 'methods': ['password'], 'nonce': 'n', 'extra': {'a': 1}})! as HelloMessage;
      expect(m.methods, ['password']);
    });
  });

  group('input messages', () {
    test('every message round-trips with the exact wire shape', () {
      final cases = <InputMessage, Map<String, dynamic>>{
        const MouseMove(0.5123, 0.2211): {'t': 'mm', 'x': 0.5123, 'y': 0.2211},
        const MouseDown(0, 0.51, 0.22): {'t': 'md', 'b': 0, 'x': 0.51, 'y': 0.22},
        const MouseUp(2, 0.51, 0.22): {'t': 'mu', 'b': 2, 'x': 0.51, 'y': 0.22},
        const Wheel(0.0, 60.0): {'t': 'wh', 'dx': 0.0, 'dy': 60.0},
        const KeyDown(458756): {'t': 'kd', 'c': 458756},
        const KeyUp(458756): {'t': 'ku', 'c': 458756},
        const TextInput('Привет'): {'t': 'txt', 's': 'Привет'},
        const SpecialInput('ctrl_alt_del'): {'t': 'sp', 'a': 'ctrl_alt_del'},
      };
      cases.forEach((msg, wire) {
        expect(msg.toJson(), wire);
        final parsed = InputMessage.parse(_roundTrip(wire))!;
        expect(parsed.runtimeType, msg.runtimeType);
        expect(parsed.toJson(), wire);
      });
    });

    test('coordinates are rounded to four decimals', () {
      expect(const MouseMove(0.123456789, 0.987654321).toJson(), {'t': 'mm', 'x': 0.1235, 'y': 0.9877});
    });

    test('malformed or unknown input is dropped', () {
      expect(InputMessage.parse({'t': 'mm', 'x': 'a', 'y': 1}), isNull);
      expect(InputMessage.parse({'t': 'md', 'x': 0.1, 'y': 0.1}), isNull);
      expect(InputMessage.parse({'t': 'kd'}), isNull);
      expect(InputMessage.parse({'t': 'zzz'}), isNull);
      expect(InputMessage.parse(42), isNull);
    });
  });

  group('signaling messages', () {
    test('dialer hello', () {
      const hello = HsHello(
        isListener: false,
        key: 'K',
        name: 'MacBook',
        os: 'macos',
        app: '0.1.0',
        nonce: 'N',
        want: HelloWant.beControlled,
        dialed: '203.0.113.5:47100',
        resume: 'sid-1',
        addresses: ['192.168.1.5:47100'],
      );
      final wire = _roundTrip(hello.toJson());
      expect(wire['role'], 'dialer');
      expect(wire['want'], 'be_controlled');
      expect(wire['v'], 2);
      final parsed = SignalingMessage.parse(wire)! as HsHello;
      expect(parsed.isListener, isFalse);
      expect(parsed.want, HelloWant.beControlled);
      expect(parsed.dialed, '203.0.113.5:47100');
      expect(parsed.resume, 'sid-1');
      expect(parsed.addresses, ['192.168.1.5:47100']);
    });

    test('listener hello carries a signature and no want', () {
      final wire = _roundTrip(const HsHello(
        isListener: true,
        key: 'K',
        name: 'PC',
        os: 'windows',
        app: '0.1.0',
        nonce: 'N',
        sig: 'SIG',
      ).toJson());
      expect(wire['role'], 'listener');
      expect(wire.containsKey('want'), isFalse);
      final parsed = SignalingMessage.parse(wire)! as HsHello;
      expect(parsed.isListener, isTrue);
      expect(parsed.sig, 'SIG');
    });

    test('hello_ack, session with and without turn', () {
      expect((SignalingMessage.parse(_roundTrip(const HsAck('S').toJson()))! as HsAck).sig, 'S');
      final withTurn = SignalingMessage.parse(_roundTrip(const HsSession(
        'sid',
        TurnInfo(username: 'u', credential: 'c', udpPort: 47100, tcpPort: 47101),
      ).toJson()))! as HsSession;
      expect(withTurn.turn!.tcpPort, 47101);
      expect(withTurn.turn!.username, 'u');
      final without = SignalingMessage.parse(_roundTrip(const HsSession('sid', null).toJson()))! as HsSession;
      expect(without.turn, isNull);
    });

    test('error, signal, bye, ping, pong', () {
      final err = SignalingMessage.parse(_roundTrip(const SigError('busy', 'later').toJson()))! as SigError;
      expect(err.code, 'busy');
      final sig = SignalingMessage.parse(_roundTrip(const SigSignal({'type': 'offer', 'sdp': 'x', 'sig': 'y'}).toJson()))! as SigSignal;
      expect(sig.type, 'offer');
      expect((SignalingMessage.parse(_roundTrip(const SigBye('denied').toJson()))! as SigBye).reason, 'denied');
      expect(SignalingMessage.parse({'t': 'ping'}), isA<SigPing>());
      expect(SignalingMessage.parse({'t': 'pong'}), isA<SigPong>());
    });

    test('unknown types are ignored and strings are clipped', () {
      expect(SignalingMessage.parse({'t': 'nope'}), isNull);
      final hello = SignalingMessage.parse({
        't': 'hello',
        'v': 2,
        'role': 'dialer',
        'key': 'K',
        'name': 'x' * 500,
        'nonce': 'n',
        'want': 'control',
      })! as HsHello;
      expect(hello.name.length, 64);
    });
  });

  group('Permissions', () {
    test('intersect and viewOnly', () {
      const a = Permissions();
      expect(a.intersect(Permissions.viewOnly), Permissions.viewOnly);
      expect(Permissions.fromJson(null), Permissions.none);
      expect(Permissions.fromJson({'view': true}), const Permissions(control: false, clipboard: false, files: false));
    });
  });
}
