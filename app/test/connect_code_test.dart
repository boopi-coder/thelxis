import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/core/settings.dart';
import 'package:thelxis/core/trusted_devices.dart';
import 'package:thelxis/core/base64url.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/net/connect_code.dart';
import 'package:thelxis/net/handshake.dart';
import 'package:thelxis/net/inband_signaling.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/net/signaling_channel.dart';
import 'package:thelxis/protocol/control_messages.dart';
import 'package:thelxis/session/capture.dart';
import 'package:thelxis/session/host_credentials.dart';
import 'package:thelxis/session/host_session.dart';
import 'package:thelxis/session/prompts.dart';
import 'package:thelxis/session/session_base.dart';
import 'package:thelxis/session/viewer_session.dart';

import 'support/fakes.dart';
import 'support/host_rig.dart';

const _sdp = 'v=0\r\no=- 123 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n'
    'a=fingerprint:sha-256 AA:BB:CC\r\na=candidate:1 1 udp 2122260223 192.168.1.5 50000 typ host\r\n';

Future<Identity> _id(int fill) => Identity.fromSeed(List<int>.generate(32, (i) => (i * 5 + fill) & 0xff));

/// Re-packs the JSON of a code after [change], keeping the old signature.
String _tamper(String code, void Function(Map<String, dynamic> json) change) {
  final prefix = code.substring(0, 4);
  final raw = ZLibCodec(raw: true).decode(b64uDecode(code.substring(4)));
  final json = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
  change(json);
  return prefix + b64uEncode(ZLibCodec(raw: true).encode(utf8.encode(jsonEncode(json))));
}

void main() {
  Logger.sink = (_, _) {};

  late Identity host;
  late Identity viewer;
  late String hostNonce;
  late int exp;
  final now = DateTime.now();

  setUp(() async {
    host = await _id(1);
    viewer = await _id(2);
    hostNonce = generateNonce();
    exp = now.add(kCodeLifetime).millisecondsSinceEpoch ~/ 1000;
  });

  Future<String> offer({String sdp = _sdp, int? expiry}) => buildOfferCode(
        identity: host,
        name: 'Office PC',
        os: 'windows',
        nonce: hostNonce,
        exp: expiry ?? exp,
        sdp: sdp,
      );

  group('offer code (TX1)', () {
    test('round trip: the viewer learns who made it and gets the exact SDP', () async {
      final code = await offer();
      expect(code, startsWith('TX1.'));
      expect(code, matches(RegExp(r'^TX1\.[A-Za-z0-9_-]+$')), reason: 'one token, safe to paste anywhere');
      final parsed = await parseOfferCode(code);
      expect(parsed.sdp, _sdp);
      expect(parsed.nonce, hostNonce);
      expect(parsed.name, 'Office PC');
      expect(parsed.os, 'windows');
      expect(parsed.exp, exp);
      expect(parsed.peer.id, host.id, reason: 'the ID comes from the key, never from the text');
      expect(parsed.key, host.publicKeyB64);
    });

    test('the SDP is compressed: a realistic offer fits a short code', () async {
      final big = StringBuffer(_sdp);
      for (var i = 0; i < 60; i++) {
        big.write('a=rtpmap:${96 + i} H264/90000\r\na=fmtp:${96 + i} level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f\r\n');
      }
      final code = await offer(sdp: big.toString());
      expect(code.length, lessThan(big.length ~/ 3));
      expect((await parseOfferCode(code)).sdp, big.toString());
    });

    test('whitespace and line wraps added by a messenger do not matter', () async {
      final code = await offer();
      final wrapped = '  ${code.replaceAllMapped(RegExp(r'.{40}'), (m) => '${m[0]}\n')}  ';
      expect((await parseOfferCode(wrapped)).sdp, _sdp);
    });

    test('expired offers are rejected', () async {
      final old = await offer(expiry: now.subtract(const Duration(seconds: 5)).millisecondsSinceEpoch ~/ 1000);
      await expectLater(parseOfferCode(old), throwsA(_code(CodeError.expired)));
      // The same code is fine when the clock is earlier.
      final ok = await parseOfferCode(old, now: now.subtract(const Duration(minutes: 1)));
      expect(ok.sdp, _sdp);
    });

    test('an expiry absurdly far in the future is rejected (codes live 10 minutes)', () async {
      final far = await offer(expiry: now.add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000);
      await expectLater(parseOfferCode(far), throwsA(_code(CodeError.expired)));
    });

    test('tampering with any signed field breaks the signature', () async {
      final code = await offer();
      await expectLater(parseOfferCode(_tamper(code, (j) => j['sdp'] = '${j['sdp']}a=evil\r\n')), throwsA(_code(CodeError.badSignature)));
      await expectLater(parseOfferCode(_tamper(code, (j) => j['exp'] = (j['exp'] as int) - 100)), throwsA(_code(CodeError.badSignature)));
      await expectLater(parseOfferCode(_tamper(code, (j) => j['nonce'] = generateNonce())), throwsA(_code(CodeError.badSignature)));
    });

    test('swapping in another key (an impersonator re-signing nothing) fails', () async {
      final code = await offer();
      await expectLater(
        parseOfferCode(_tamper(code, (j) => j['k'] = viewer.publicKeyB64)),
        throwsA(_code(CodeError.badSignature)),
      );
    });

    test('a signature made by another key for the same text does not verify', () async {
      final forged = kOfferPrefix +
          b64uEncode(ZLibCodec(raw: true).encode(utf8.encode(jsonEncode({
            'v': 1,
            'k': host.publicKeyB64,
            'n': 'Office PC',
            'os': 'windows',
            'nonce': hostNonce,
            'exp': exp,
            'sdp': _sdp,
            'sig': await signPayload(viewer, offerSignaturePayload(nonce: hostNonce, exp: exp, sdp: _sdp)),
          }))));
      await expectLater(parseOfferCode(forged), throwsA(_code(CodeError.badSignature)));
    });

    test('your own code is refused', () async {
      await expectLater(
        parseOfferCode(await offer(), ownKey: host.publicKeyB64),
        throwsA(_code(CodeError.mismatch)),
      );
    });

    test('malformed input of every kind is rejected without crashing', () async {
      for (final bad in [
        '',
        'TX1.',
        'TX1.!!!',
        'TX2.${b64uEncode(utf8.encode('{}'))}',
        'hello',
        'TX1.${b64uEncode([1, 2, 3, 4, 5])}',
        'TX1.${b64uEncode(ZLibCodec(raw: true).encode(utf8.encode('not json')))}',
        'TX1.${b64uEncode(ZLibCodec(raw: true).encode(utf8.encode('[1,2]')))}',
        'TX1.${b64uEncode(ZLibCodec(raw: true).encode(utf8.encode('{"v":1}')))}',
        'TX1.${b64uEncode(ZLibCodec(raw: true).encode(utf8.encode('{"v":1,"k":"x","nonce":"y","sdp":"z","sig":"s","exp":1}')))}',
      ]) {
        await expectLater(parseOfferCode(bad), throwsA(isA<CodeException>()), reason: bad);
      }
    });

    test('a newer code version is reported as unsupported', () async {
      final code = await offer();
      await expectLater(parseOfferCode(_tamper(code, (j) => j['v'] = 2)), throwsA(_code(CodeError.unsupported)));
    });

    test('codes over 16 KiB are rejected before they are inflated', () async {
      final huge = 'TX1.${'A' * (kMaxCodeChars + 1)}';
      await expectLater(parseOfferCode(huge), throwsA(_code(CodeError.tooLarge)));
    });

    test('a deflate bomb is stopped by the inflated-size limit', () async {
      // 8 MiB of zeros deflates to a few KiB.
      final bomb = ZLibCodec(raw: true, level: 9).encode(List<int>.filled(8 * 1024 * 1024, 0x20));
      final code = 'TX1.${b64uEncode(bomb)}';
      expect(code.length, lessThan(kMaxCodeChars), reason: 'small enough to pass the size check');
      await expectLater(parseOfferCode(code), throwsA(_code(CodeError.tooLarge)));
    });

    test('looksLikeConnectionCode routes pasted text', () {
      expect(looksLikeConnectionCode('TX1.abc'), isTrue);
      expect(looksLikeConnectionCode('  TX2.abc'), isTrue);
      expect(looksLikeConnectionCode('K7M2-P9XQ-4TAB-8HDE@1.2.3.4'), isFalse);
      expect(looksLikeConnectionCode('thelxis://connect?id=x'), isFalse);
    });
  });

  group('answer code (TX2)', () {
    late String viewerNonce;
    setUp(() => viewerNonce = generateNonce());

    Future<String> answer({String? forHostNonce, String sdp = _sdp}) => buildAnswerCode(
          identity: viewer,
          name: 'Home Mac',
          os: 'macos',
          hostNonce: forHostNonce ?? hostNonce,
          viewerNonce: viewerNonce,
          sdp: sdp,
        );

    test('round trip against the offer it answers', () async {
      final code = await answer();
      expect(code, startsWith('TX2.'));
      final parsed = await parseAnswerCode(code, hostNonce: hostNonce);
      expect(parsed.sdp, _sdp);
      expect(parsed.nonce, viewerNonce);
      expect(parsed.peer.id, viewer.id);
      expect(parsed.name, 'Home Mac');
    });

    test('an answer made for another offer is rejected (the host nonce is signed)', () async {
      await expectLater(
        parseAnswerCode(await answer(forHostNonce: generateNonce()), hostNonce: hostNonce),
        throwsA(_code(CodeError.badSignature)),
      );
    });

    test('tampered answers fail', () async {
      final code = await answer();
      await expectLater(
        parseAnswerCode(_tamper(code, (j) => j['sdp'] = 'v=0\r\nevil'), hostNonce: hostNonce),
        throwsA(_code(CodeError.badSignature)),
      );
      await expectLater(
        parseAnswerCode(_tamper(code, (j) => j['nonce'] = generateNonce()), hostNonce: hostNonce),
        throwsA(_code(CodeError.badSignature)),
      );
    });

    test('an offer code is not an answer code, and vice versa', () async {
      await expectLater(parseAnswerCode(await offer(), hostNonce: hostNonce), throwsA(_code(CodeError.malformed)));
      await expectLater(parseOfferCode(await answer()), throwsA(_code(CodeError.malformed)));
    });

    test('your own answer is refused', () async {
      await expectLater(
        parseAnswerCode(await answer(), hostNonce: hostNonce, ownKey: viewer.publicKeyB64),
        throwsA(_code(CodeError.mismatch)),
      );
    });

    test('oversized and malformed answers are rejected', () async {
      await expectLater(parseAnswerCode('TX2.${'B' * (kMaxCodeChars + 1)}', hostNonce: hostNonce), throwsA(_code(CodeError.tooLarge)));
      await expectLater(parseAnswerCode('TX2.@@@', hostNonce: hostNonce), throwsA(_code(CodeError.malformed)));
    });
  });

  group('in-band signaling (rtc messages on the control channel)', () {
    late String viewerNonce;
    late InBandSignaling hostSide;
    late InBandSignaling viewerSide;
    final toViewer = <Map<String, dynamic>>[];
    final toHost = <Map<String, dynamic>>[];

    setUp(() {
      viewerNonce = generateNonce();
      toViewer.clear();
      toHost.clear();
      hostSide = InBandSignaling(
        identity: host,
        role: SignalingRole.listener,
        peerKey: viewer.publicKeyB64,
        hostNonce: hostNonce,
        viewerNonce: viewerNonce,
      );
      viewerSide = InBandSignaling(
        identity: viewer,
        role: SignalingRole.dialer,
        peerKey: host.publicKeyB64,
        hostNonce: hostNonce,
        viewerNonce: viewerNonce,
      );
    });

    test('an ICE-restart offer from the host reaches the viewer verified, and the answer returns', () async {
      final viewerEvents = <SignalEvent>[];
      final hostEvents = <SignalEvent>[];
      viewerSide.events.listen(viewerEvents.add);
      hostSide.events.listen(hostEvents.add);
      hostSide.attachTransport(toViewer.add);
      viewerSide.attachTransport(toHost.add);

      await hostSide.sendOffer('offer-sdp');
      expect(toViewer.single['type'], 'offer');
      await viewerSide.onRtc(toViewer.single);
      await Future<void>.delayed(Duration.zero);
      expect((viewerEvents.single as RemoteSdp).sdp, 'offer-sdp');

      await viewerSide.sendAnswer('answer-sdp');
      await hostSide.onRtc(toHost.single);
      await Future<void>.delayed(Duration.zero);
      expect((hostEvents.single as RemoteSdp).type, 'answer');
      expect((hostEvents.single as RemoteSdp).sdp, 'answer-sdp');
    });

    test('signatures use nH|nV in the sdp transcript of section 4.2', () async {
      hostSide.attachTransport(toViewer.add);
      await hostSide.sendOffer('X');
      final sig = toViewer.single['sig'] as String;
      expect(
        await verifyPayload(
          peerKey: host.publicKeyB64,
          signature: sig,
          payload: 'thelxis-sdp-v2|$hostNonce|$viewerNonce|offer|X',
        ),
        isTrue,
      );
    });

    test('a tampered SDP, a wrong-nonce signature or a foreign key is a SignatureFailure', () async {
      hostSide.attachTransport(toViewer.add);
      await hostSide.sendOffer('real');

      final events = <SignalEvent>[];
      final sub = viewerSide.events.listen(events.add);
      await viewerSide.onRtc({...toViewer.single, 'sdp': 'fake'});
      await Future<void>.delayed(Duration.zero);
      expect(events.single, isA<SignatureFailure>());
      expect(viewerSide.isClosed, isTrue);
      await sub.cancel();

      // Signed with the right key but for another session.
      final other = InBandSignaling(
        identity: host,
        role: SignalingRole.listener,
        peerKey: viewer.publicKeyB64,
        hostNonce: generateNonce(),
        viewerNonce: viewerNonce,
      )..attachTransport(toViewer.add);
      await other.sendOffer('real');
      final fresh = InBandSignaling(
        identity: viewer,
        role: SignalingRole.dialer,
        peerKey: host.publicKeyB64,
        hostNonce: hostNonce,
        viewerNonce: viewerNonce,
      );
      final ev2 = <SignalEvent>[];
      fresh.events.listen(ev2.add);
      await fresh.onRtc(toViewer.last);
      await Future<void>.delayed(Duration.zero);
      expect(ev2.single, isA<SignatureFailure>());
    });

    test('the host takes only answers and candidates; the viewer only offers and candidates', () async {
      final hostEvents = <SignalEvent>[];
      final viewerEvents = <SignalEvent>[];
      hostSide.events.listen(hostEvents.add);
      viewerSide.events.listen(viewerEvents.add);
      viewerSide.attachTransport(toHost.add);
      hostSide.attachTransport(toViewer.add);

      // A viewer cannot make the host process an offer, even a correctly signed one.
      final asOffer = InBandSignaling(
        identity: viewer,
        role: SignalingRole.dialer,
        peerKey: host.publicKeyB64,
        hostNonce: hostNonce,
        viewerNonce: viewerNonce,
      )..attachTransport(toHost.add);
      await asOffer.sendOffer('sneaky');
      await hostSide.onRtc(toHost.last);
      await Future<void>.delayed(Duration.zero);
      expect(hostEvents, isEmpty);

      await hostSide.sendAnswer('wrong direction');
      await viewerSide.onRtc(toViewer.last);
      await Future<void>.delayed(Duration.zero);
      expect(viewerEvents, isEmpty);

      await viewerSide.onRtc({'type': 'candidate', 'candidate': 'candidate:1 1 udp 1 1.2.3.4 5 typ host', 'sdpMid': '0', 'sdpMLineIndex': 0});
      await Future<void>.delayed(Duration.zero);
      expect(viewerEvents.single, isA<RemoteCandidate>());
    });

    test('messages sent before the control channel exists wait for it; candidates before it are dropped', () async {
      hostSide.sendCandidate(candidate: 'candidate:early', sdpMid: '0', sdpMLineIndex: 0);
      await hostSide.sendOffer('queued offer');
      expect(hostSide.isAttached, isFalse);
      hostSide.attachTransport(toViewer.add);
      expect(toViewer.map((m) => m['type']), ['offer'], reason: 'the early candidate was already in the code\'s SDP');
      hostSide.sendCandidate(candidate: 'candidate:late', sdpMid: '0', sdpMLineIndex: 0);
      expect(toViewer.last['candidate'], 'candidate:late');
    });

    test('malformed rtc data never throws', () async {
      for (final bad in <Map<String, dynamic>>[
        {},
        {'type': 'answer'},
        {'type': 'answer', 'sdp': 5, 'sig': 'x'},
        {'type': 'candidate', 'candidate': 5},
        {'type': 'candidate', 'candidate': 'x' * 5000},
        {'type': 'bogus'},
      ]) {
        await hostSide.onRtc(bad);
      }
    });

    test('bye closes it', () async {
      hostSide.bye('user');
      expect(hostSide.isClosed, isTrue);
      await hostSide.closed;
    });
  });

  group('sessions route rtc messages of code sessions', () {
    test('the host session passes rtc to in-band signaling and sends its own over the control channel', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = AppSettings(prefs, defaultDeviceName: 'Host');
      final channel = _RecordingInBand(
        identity: host,
        role: SignalingRole.listener,
        peerKey: viewer.publicKeyB64,
        hostNonce: hostNonce,
        viewerNonce: generateNonce(),
      );
      final sent = <Map<String, dynamic>>[];
      final session = HostSession(
        env: HostEnv(
          settings: settings,
          identity: host,
          trusted: TrustedDevices(prefs),
          credentials: HostCredentials(identity: host, settings: settings),
          platform: FakeHostPlatform(),
          captures: CaptureRegistry(),
          requestApproval: (p) async => ApprovalResult.denied,
          onNotice: (t, m) {},
          startCapture: (d, all, {int fps = 30}) => throw UnimplementedError(),
        ),
        peer: PeerIdentity(key: viewer.publicKeyB64, id: viewer.id, name: 'V', os: 'macos'),
        sid: 'sid',
        channel: channel,
        forcePublicStun: true,
      )..debugControlTap = sent.add;
      expect(session.forcePublicStun, isTrue);

      session.debugReceiveControl({
        't': 'rtc',
        'data': {'type': 'answer', 'sdp': 'a', 'sig': 'b'},
      });
      expect(channel.received.single['type'], 'answer');

      expect(channel.isAttached, isFalse);
      session.debugControlOpened();
      expect(channel.isAttached, isTrue, reason: 'the control channel is now the transport');
      await channel.sendOffer('restart-offer');
      final rtc = sent.firstWhere((m) => m['t'] == 'rtc');
      expect((rtc['data'] as Map)['type'], 'offer');
      expect((rtc['data'] as Map)['sdp'], 'restart-offer');
      await session.end('user');
    });

    test('the viewer session does the same', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final channel = _RecordingInBand(
        identity: viewer,
        role: SignalingRole.dialer,
        peerKey: host.publicKeyB64,
        hostNonce: hostNonce,
        viewerNonce: generateNonce(),
      );
      final sent = <Map<String, dynamic>>[];
      final session = ViewerSession(
        env: ViewerEnv(settings: AppSettings(prefs, defaultDeviceName: 'V'), userName: 'V'),
        peer: PeerIdentity(key: host.publicKeyB64, id: host.id, name: 'H', os: 'windows'),
        sid: 'sid',
        channel: channel,
        forcePublicStun: true,
      )..debugControlTap = sent.add;
      session.debugReceiveControl({
        't': 'rtc',
        'data': {'type': 'offer', 'sdp': 'o', 'sig': 's'},
      });
      expect(channel.received.single['type'], 'offer');
      session.debugControlOpened();
      expect(channel.isAttached, isTrue);
      await channel.sendAnswer('restart-answer');
      expect(sent.firstWhere((m) => m['t'] == 'rtc')['data']['type'], 'answer');
      await session.end('user');
    });

    test('rtc messages are ordinary control messages for the parser', () {
      final m = ControlMessage.parse({'t': 'rtc', 'data': {'type': 'candidate'}});
      expect(m, isA<RtcMessage>());
      expect((m as RtcMessage).toJson(), {'t': 'rtc', 'data': {'type': 'candidate'}});
      expect(ControlMessage.parse({'t': 'rtc', 'data': 'nope'}), isNull);
    });

    test('a plain WebSocket session ignores rtc entirely', () async {
      // No in-band signaling: the message is simply dropped.
      final rig = HostRig();
      await rig.setUp();
      addTearDown(rig.tearDown);
      rig.session.debugReceiveControl({'t': 'rtc', 'data': {'type': 'answer'}});
      expect(rig.session.phase, isNot(SessionPhase.ended));
    });
  });
}

Matcher _code(CodeError e) => isA<CodeException>().having((x) => x.error, 'error', e);

class _RecordingInBand extends InBandSignaling {
  _RecordingInBand({required super.identity, required super.role, required super.peerKey, required super.hostNonce, required super.viewerNonce});

  final List<Map<String, dynamic>> received = [];

  @override
  Future<void> onRtc(Map<String, dynamic> data) async => received.add(data);
}
