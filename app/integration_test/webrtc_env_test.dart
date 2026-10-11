import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

/// Environment probe: proves the runner can run libwebrtc at all (native library
/// loads, ICE/DTLS/SCTP work over the host network, the X11 capturer sees the
/// virtual display) before any Thelxis code is involved. When this fails the
/// problem is the runner or the plugin, not the application.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('two raw peers exchange a data channel message', (tester) async {
    final a = await createPeerConnection({'iceServers': <dynamic>[]});
    final b = await createPeerConnection({'iceServers': <dynamic>[]});
    final received = Completer<String>();
    a.onIceCandidate = (c) => b.addCandidate(c);
    b.onIceCandidate = (c) => a.addCandidate(c);
    b.onDataChannel = (dc) {
      dc.onMessage = (m) {
        if (!received.isCompleted) received.complete(m.text);
      };
    };
    final dc = await a.createDataChannel('probe', RTCDataChannelInit());
    final opened = Completer<void>();
    dc.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen && !opened.isCompleted) opened.complete();
    };
    final offer = await a.createOffer();
    await a.setLocalDescription(offer);
    await b.setRemoteDescription(offer);
    final answer = await b.createAnswer();
    await b.setLocalDescription(answer);
    await a.setRemoteDescription(answer);
    await opened.future.timeout(const Duration(seconds: 20));
    await dc.send(RTCDataChannelMessage('ping'));
    expect(await received.future.timeout(const Duration(seconds: 10)), 'ping');
    await dc.close();
    await a.close();
    await b.close();
  });

  testWidgets('the X11 capturer delivers decoded frames from the virtual display', (tester) async {
    final sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
    // ignore: avoid_print
    print('capture sources: ${[for (final s in sources) '${s.id}/${s.name}']}');
    expect(sources, isNotEmpty);

    final stream = await navigator.mediaDevices.getDisplayMedia({
      'video': {
        'deviceId': {'exact': sources.first.id},
        'mandatory': {'frameRate': 30.0},
      },
      'audio': false,
    });
    final track = stream.getVideoTracks().first;

    final a = await createPeerConnection({'iceServers': <dynamic>[]});
    final b = await createPeerConnection({'iceServers': <dynamic>[]});
    a.onIceCandidate = (c) => b.addCandidate(c);
    b.onIceCandidate = (c) => a.addCandidate(c);
    final gotTrack = Completer<void>();
    b.onTrack = (e) {
      if (!gotTrack.isCompleted) gotTrack.complete();
    };
    await a.addTrack(track, stream);
    final offer = await a.createOffer();
    await a.setLocalDescription(offer);
    await b.setRemoteDescription(offer);
    final answer = await b.createAnswer();
    await b.setLocalDescription(answer);
    await a.setRemoteDescription(answer);
    await gotTrack.future.timeout(const Duration(seconds: 20));

    num decoded = 0;
    num width = 0;
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 20) && (decoded == 0 || width == 0)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (final r in await b.getStats()) {
        if (r.type == 'inbound-rtp' && (r.values['kind'] ?? r.values['mediaType']) == 'video') {
          decoded = _num(r.values['framesDecoded']);
          width = _num(r.values['frameWidth']);
        }
      }
    }
    // ignore: avoid_print
    print('framesDecoded=$decoded frameWidth=$width');
    expect(decoded, greaterThan(0));
    expect(width, greaterThan(0));

    await track.stop();
    await stream.dispose();
    await a.close();
    await b.close();
  });
}

num _num(Object? v) => v is num ? v : (v is String ? num.tryParse(v) ?? 0 : 0);
