// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:thelxis/files/files.dart';
import 'package:thelxis/net/net_address.dart';
import 'package:thelxis/net/connect_target.dart';
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/session/hid.dart';
import 'package:thelxis/session/link_stats.dart';
import 'package:thelxis/session/prompts.dart';
import 'package:thelxis/session/session_base.dart';

import 'support/probe.dart';
import 'support/recorders.dart';
import 'support/rig.dart';

/// Two complete Thelxis peers in one process, talking over loopback through the
/// real stack: signed WebSocket handshake, signed SDP, libwebrtc ICE / DTLS /
/// SCTP / RTP, the embedded TURN server and screen capture of the (virtual)
/// display. Only OS-facing pieces are replaced by recorders: the input
/// injector, the session badge, prompts and the clipboards.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  E2ELog.install();

  e2e('a) a wrong password is refused with a retry, then the one-time password authorizes', (rig) async {
    final viewer = await rig.dial();
    await waitUntil(() => viewer.authPrompt != null, what: 'viewer is asked for a password');
    expect(viewer.authPrompt!.canPassword, isTrue);
    final host = await rig.host.awaitHostSession();
    expect(host.phase, SessionPhase.authenticating);
    expect(rig.host.sent('hello').single['methods'], containsAll(['password', 'request']));

    await viewer.submitPassword('this-is-not-the-password');
    await waitUntil(() => rig.host.sent('auth_result').isNotEmpty, what: 'host answers the wrong password');
    final refusal = rig.host.sent('auth_result').first;
    expect(refusal['ok'], isFalse);
    expect(refusal['reason'], 'bad_password');
    expect(refusal['retry'], isTrue);
    await waitUntil(() => viewer.authPrompt?.error != null, what: 'viewer shows the error and asks again');
    expect(viewer.authPrompt!.canPassword, isTrue);
    expect(viewer.phase, isNot(SessionPhase.active));
    expect(host.phase, SessionPhase.authenticating);
    expect(rig.host.badge.shown, isEmpty, reason: 'nothing is shared before authorization');
    expect(rig.host.platform.beforeCaptureCalls, 0);

    await viewer.submitPassword(rig.host.credentials.oneTimePassword);
    await rig.bothActive(viewer);
    final granted = rig.host.sent('auth_result').last;
    expect(granted['ok'], isTrue);
    expect(granted['trusted'], isFalse);
    expect(Permissions.fromJson(granted['permissions']), const Permissions());
    expect(viewer.permissions, const Permissions());
    expect(viewer.becameTrusted, isFalse);
    expect(host.permissions, const Permissions());
    expect(rig.host.trusted.devices, isEmpty, reason: 'a password does not add a trusted device');
    expect(rig.host.prompts.seen, isEmpty, reason: 'password authorization asks nobody');
  });

  e2e('b) real screen capture reaches the viewer and is decoded', (rig) async {
    final viewer = await rig.dial();
    final host = await rig.authorize(viewer);
    expect(host.sharing, isTrue);

    final pc = viewer.debugPeerConnection!;
    var last = const VideoProbe(0, 0, 0, 0);
    await waitUntilAsync(
      () async {
        last = await probeInboundVideo(pc);
        return last.decoding;
      },
      timeout: const Duration(seconds: 20),
      what: 'viewer decodes video frames (last: $last)',
    );
    print('viewer inbound video: $last');
    expect(last.framesDecoded, greaterThan(0));
    expect(last.width, greaterThan(0));
    expect(last.height, greaterThan(0));

    final pair = await probeSelectedPair(pc);
    print('viewer selected pair: $pair');
    expect(pair, isNotNull);
    expect(pair!.localType, isNot('relay'), reason: 'on one machine the direct path must win');

    // What the app itself shows from the same statistics.
    await waitUntil(
      () => (viewer.stats.value.width ?? 0) > 0 && (viewer.stats.value.height ?? 0) > 0,
      what: 'link stats report the frame size',
    );
    expect(viewer.stats.value.path, isNot(LinkPath.relay));
    expect(viewer.displays, isNotEmpty);
    expect(viewer.activeDisplay, isNotNull);
    print('renderer first frame drawn: ${viewer.hasFirstFrame}');
  });

  e2e('b2) switching quality re-captures and keeps the picture flowing', (rig) async {
    final viewer = await rig.dial();
    final host = await rig.authorize(viewer);
    final pc = viewer.debugPeerConnection!;
    await waitUntilAsync(
      () async => (await probeInboundVideo(pc)).decoding,
      timeout: const Duration(seconds: 20),
      what: 'first frames',
    );
    final before = (await probeInboundVideo(pc)).framesDecoded;

    viewer.setQuality(QualityPreset.quality);
    await waitUntil(() => host.quality == QualityPreset.quality, what: 'host applies the preset');
    await waitUntilAsync(
      () async => (await probeInboundVideo(pc)).framesDecoded > before,
      timeout: const Duration(seconds: 20),
      what: 'frames keep arriving after the re-capture',
    );
    expect(viewer.phase, SessionPhase.active);
  });

  e2e('c) viewer input arrives on the host with the right coordinates and key codes', (rig) async {
    final viewer = await rig.dial();
    await rig.authorize(viewer);
    final enc = viewer.encoder;
    final inj = rig.host.injector;

    // The input channel opens next to the control channel; make sure the first
    // scripted event is not the one that races it.
    await waitUntil(() {
      enc.mouseMove(0.01, 0.01);
      return inj.all<InjectedMove>().isNotEmpty;
    }, what: 'input channel delivers', timeout: const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final base = inj.events.length;

    enc.mouseMove(0.25, 0.75);
    enc.mouseDown(0, 0.25, 0.75);
    enc.mouseUp(0, 0.25, 0.75);
    enc.mouseDown(2, 0.5, 0.5);
    enc.mouseUp(2, 0.5, 0.5);
    enc.wheel(0, 60);
    enc.keyDown(Hid.shiftLeft);
    enc.keyDown(Hid.keyA);
    enc.keyUp(Hid.keyA);
    enc.keyUp(Hid.shiftLeft);
    enc.text('Привет, мир 🌍');
    enc.special('lock');

    await waitUntil(
      () => inj.events.skip(base).any((e) => e is InjectedSpecial),
      what: 'the whole script reaches the injector',
    );
    final got = inj.events.skip(base).map((e) => e.toString()).toList();
    expect(got, [
      'move(0, 0.25, 0.75)',
      'move(0, 0.25, 0.75)',
      'button(left, down)',
      'move(0, 0.25, 0.75)',
      'button(left, up)',
      'move(0, 0.5, 0.5)',
      'button(right, down)',
      'move(0, 0.5, 0.5)',
      'button(right, up)',
      'scroll(0.0, 60.0)',
      'key(0x700e1, down)',
      'key(0x70004, down)',
      'key(0x70004, up)',
      'key(0x700e1, up)',
      'text(Привет, мир 🌍)',
      'special(lock)',
    ]);
    expect(inj.all<InjectedMove>().every((m) => m.display.id == '0'), isTrue);
  });

  e2e('d) files move both ways over the real channel, byte for byte, and the host can be browsed',
      (rig) async {
    final tmp = await Directory.systemTemp.createTemp('thelxis_e2e_files_');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // Temp files only.
      }
    });
    final random = Random(42);
    Uint8List megabyte() => Uint8List.fromList(List<int>.generate(1 << 20, (_) => random.nextInt(256)));
    final upBytes = megabyte();
    final downBytes = megabyte();
    final pullBytes = megabyte();
    final up = await File('${tmp.path}/upload.bin').writeAsBytes(upBytes);
    final down = await File('${tmp.path}/pushed.bin').writeAsBytes(downBytes);
    final pull = await File('${tmp.path}/pulled.bin').writeAsBytes(pullBytes);
    final browse = await Directory('${tmp.path}/browse').create();
    await File('${browse.path}/note.txt').writeAsString('hello');
    await Directory('${browse.path}/sub').create();

    final viewer = await rig.dial();
    final host = await rig.authorize(viewer);
    await waitUntil(
      () => viewer.files != null && host.files != null,
      what: 'both file endpoints exist',
    );
    expect(host.files!.allowed, isTrue);
    final vf = viewer.files!;
    final hf = host.files!;
    const patience = Duration(seconds: 40);

    // Viewer -> host.
    await vf.sendFiles([up.path]);
    await vf.whenIdle().timeout(patience);
    final sentUp = vf.transfers.singleWhere((t) => t.isSend);
    expect(sentUp.status, TransferStatus.completed, reason: '${sentUp.error}');
    final landedUp = File('${rig.host.incoming.path}/upload.bin');
    expect(await landedUp.exists(), isTrue);
    expect(listEquals(await landedUp.readAsBytes(), upBytes), isTrue, reason: 'viewer -> host content');

    // Host -> viewer.
    await hf.sendFiles([down.path]);
    await hf.whenIdle().timeout(patience);
    final sentDown = hf.transfers.singleWhere((t) => t.isSend);
    expect(sentDown.status, TransferStatus.completed, reason: '${sentDown.error}');
    final landedDown = File('${rig.viewer.incoming.path}/pushed.bin');
    expect(await landedDown.exists(), isTrue);
    expect(listEquals(await landedDown.readAsBytes(), downBytes), isTrue, reason: 'host -> viewer content');

    // Viewer pulls a file from the host's disk.
    final pulledDir = await Directory('${tmp.path}/pulled_to').create();
    await vf.download(pull.path, localDir: pulledDir.path, isDirectory: false);
    await vf.whenIdle().timeout(patience);
    final pulled = File('${pulledDir.path}/pulled.bin');
    expect(await pulled.exists(), isTrue);
    expect(listEquals(await pulled.readAsBytes(), pullBytes), isTrue, reason: 'download content');

    // Remote browsing.
    final roots = await vf.remote.roots();
    expect(roots, isNotEmpty);
    final entries = await vf.remote.list(browse.path);
    expect({for (final e in entries) e.name: e.isDir}, {'note.txt': false, 'sub': true});
    expect(entries.firstWhere((e) => e.name == 'note.txt').size, 5);
    await expectLater(
      vf.remote.list('${tmp.path}/does-not-exist'),
      throwsA(isA<RemoteFsException>().having((e) => e.kind, 'kind', RemoteFsErrorKind.notFound)),
    );
  });

  e2e('e) clipboard text and chat travel both ways', (rig) async {
    final viewer = await rig.dial();
    final host = await rig.authorize(viewer);
    const wait = Duration(seconds: 8);

    for (var round = 1; round <= 6; round++) {
      final fromViewer = 'round $round from the viewer: привет';
      rig.viewer.clipboard.text = fromViewer;
      await waitUntil(
        () => rig.host.clipboard.text == fromViewer,
        timeout: wait,
        what: 'round $round: viewer clipboard reaches the host',
      );
      final fromHost = 'round $round from the host: 你好';
      rig.host.clipboard.text = fromHost;
      await waitUntil(
        () => rig.viewer.clipboard.text == fromHost,
        timeout: wait,
        what: 'round $round: host clipboard reaches the viewer',
      );
    }

    // A large clipboard still fits one SCTP message.
    final big = 'x' * (150 * 1024);
    rig.viewer.clipboard.text = big;
    await waitUntil(() => rig.host.clipboard.text == big, timeout: wait, what: '150 KiB clipboard reaches the host');

    // The receiving side must not echo what it was just given.
    await Future<void>.delayed(const Duration(seconds: 3));
    String summary(Iterable<Map<String, dynamic>> msgs) => msgs
        .map((m) => '${(m['text'] as String).length}:${(m['text'] as String).substring(0, 8)}')
        .toList()
        .toString();
    final viewerSent = summary(rig.viewer.sent('clipboard'));
    final hostSent = summary(rig.host.sent('clipboard'));
    print('clipboard messages sent by the viewer: $viewerSent; by the host: $hostSent');
    final timeline = ([...rig.viewer.clipboard.timeline, ...rig.host.clipboard.timeline]
          ..sort((a, b) => int.parse(a.split(' ').first).compareTo(int.parse(b.split(' ').first))))
        .join('\n');
    expect(rig.viewer.sent('clipboard').length, 7,
        reason: 'viewer sent its own seven changes only: $viewerSent\n$timeline');
    expect(rig.host.sent('clipboard').length, 6, reason: 'host sent its own six changes only: $hostSent\n$timeline');

    viewer.sendChat('hello from the viewer');
    await waitUntil(() => host.chatLog.contains('hello from the viewer'), what: 'chat reaches the host');
  });

  e2e('f) relay-only: the viewer reaches the host through the embedded TURN server', (rig) async {
    final viewer = await rig.dial(relayOnly: true);
    final host = await rig.authorize(viewer);
    final pc = viewer.debugPeerConnection!;

    SelectedPair? pair;
    await waitUntilAsync(
      () async {
        pair = await probeSelectedPair(pc);
        return pair?.localType != null;
      },
      what: 'viewer has a selected candidate pair',
    );
    print('viewer selected pair (relay-only): $pair raw=${pair!.raw}');
    expect(pair!.localType, 'relay', reason: 'with a relay-only policy the viewer can only use our TURN');
    await waitUntil(() => viewer.stats.value.path == LinkPath.relay, what: 'app reports the relay path');
    print('host selected pair: ${await probeSelectedPair(host.debugPeerConnection!)}');

    // Everything must flow over that path: video, input, files, clipboard.
    var video = const VideoProbe(0, 0, 0, 0);
    await waitUntilAsync(
      () async {
        video = await probeInboundVideo(pc);
        return video.decoding;
      },
      timeout: const Duration(seconds: 25),
      what: 'video decodes over the relay (last: $video)',
    );

    final inj = rig.host.injector;
    await waitUntil(() {
      viewer.encoder.mouseMove(0.4, 0.6);
      return inj.all<InjectedMove>().isNotEmpty;
    }, what: 'input arrives over the relay');

    final tmp = await Directory.systemTemp.createTemp('thelxis_e2e_relay_');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // Temp files only.
      }
    });
    final bytes = Uint8List.fromList(List<int>.generate(256 * 1024, (i) => (i * 31) & 0xff));
    final file = await File('${tmp.path}/relay.bin').writeAsBytes(bytes);
    await waitUntil(() => viewer.files != null, what: 'viewer file endpoint');
    await viewer.files!.sendFiles([file.path]);
    await viewer.files!.whenIdle().timeout(const Duration(seconds: 40));
    final landed = File('${rig.host.incoming.path}/relay.bin');
    expect(listEquals(await landed.readAsBytes(), bytes), isTrue);

    rig.viewer.clipboard.text = 'through the relay';
    await waitUntil(() => rig.host.clipboard.text == 'through the relay', what: 'clipboard over the relay');
  });

  e2e('g) the session badge appears with the shared screen and goes away with the session', (rig) async {
    expect(rig.host.badge.shown, isEmpty);
    final viewer = await rig.dial();
    await rig.authorize(viewer);
    await waitUntil(() => rig.host.badge.current != null, what: 'badge is shown');
    final shown = rig.host.badge.current!;
    expect(shown.peers, ['Viewer']);
    expect(shown.controlActive, isTrue);
    expect(shown.label, contains('Viewer'));
    expect(rig.host.badge.dismissCalls, 0);
    expect(rig.host.manager.liveHostSessions, hasLength(1));

    // The viewer leaves: the badge must go.
    await viewer.end('user');
    await waitUntil(() => rig.host.badge.current == null, what: 'badge is dismissed after the viewer left');
    expect(rig.host.badge.dismissCalls, greaterThanOrEqualTo(1));
    expect(rig.host.manager.hostSessions, isEmpty);

    // And the Stop button on the badge ends a running session.
    final again = await rig.dial();
    await rig.authorize(again);
    await waitUntil(() => rig.host.badge.current != null, what: 'badge is shown again');
    rig.host.badge.pressStop();
    await waitUntil(() => again.isEnded, what: 'Stop on the badge ends the viewer session');
    expect(again.endReason, 'remote');
    await waitUntil(() => rig.host.badge.current == null, what: 'badge is dismissed after Stop');
  });

  e2e('h) ending a session releases input, capture, channels and leaves the listener reusable', (rig) async {
    final viewer = await rig.dial();
    final host = await rig.authorize(viewer);
    final inj = rig.host.injector;
    await waitUntil(() => viewer.files != null && host.files != null, what: 'file endpoints');
    expect(rig.host.manager.captures.active, 1);

    // The viewer is holding Shift and the left button when the host stops it.
    await waitUntil(() {
      viewer.encoder.mouseMove(0.1, 0.1);
      return inj.all<InjectedMove>().isNotEmpty;
    }, what: 'input channel delivers');
    viewer.encoder.keyDown(Hid.shiftLeft);
    viewer.encoder.mouseDown(0, 0.5, 0.5);
    await waitUntil(
      () => inj.all<InjectedKey>().any((k) => k.down) && inj.all<InjectedButton>().any((b) => b.down),
      what: 'held input reaches the host',
    );
    final mark = inj.events.length;

    await rig.host.manager.stopAllHostSessions();
    await waitUntil(() => host.isEnded && viewer.isEnded, what: 'both sessions end');
    expect(host.endReason, 'user');
    expect(viewer.endReason, 'remote');

    final released = inj.events.skip(mark).map((e) => e.toString()).toList();
    expect(released, contains('key(0x700e1, up)'));
    expect(released, contains('button(left, up)'));
    expect(released, contains('releaseAll()'));
    expect(rig.host.manager.captures.active, 0);
    expect(rig.host.platform.beforeCaptureCalls, 1);
    expect(rig.host.platform.afterCaptureCalls, 1);
    expect(host.sharing, isFalse);
    expect(host.files, isNull);
    expect(host.filesChannel, isNull);
    expect(viewer.files, isNull);
    expect(viewer.filesChannel, isNull);
    expect(viewer.renderer.srcObject, isNull);
    expect(rig.host.manager.hostSessions, isEmpty);
    expect(rig.host.manager.liveHostSessions, isEmpty);
    expect(rig.host.badge.current, isNull);
    expect(rig.host.manager.history.records, hasLength(1));
    expect(rig.host.manager.history.records.single.incoming, isTrue);

    // The listener and the embedded TURN serve the next session as before; the
    // one-time password was rotated by the successful password session.
    final second = await rig.dial();
    final secondHost = await rig.authorize(second);
    final probe = second.debugPeerConnection!;
    await waitUntilAsync(
      () async => (await probeInboundVideo(probe)).decoding,
      timeout: const Duration(seconds: 25),
      what: 'second session decodes video',
    );
    expect(secondHost.sharing, isTrue);
    expect(rig.host.platform.beforeCaptureCalls, 2);
    await second.end('user');
    await waitUntil(() => secondHost.isEnded, what: 'second host session ends');
    expect(rig.host.manager.captures.active, 0);
    expect(rig.host.platform.afterCaptureCalls, 2);
  });

  e2e('i) "always allow" turns a request into a trusted device that reconnects without asking', (rig) async {
    rig.host.prompts
      ..accept = true
      ..alwaysAllow = true;
    final viewer = await rig.dial();
    await waitUntil(() => viewer.authPrompt != null, what: 'viewer is offered the request method');
    expect(viewer.authPrompt!.canRequest, isTrue);
    viewer.requestAccess();
    await rig.bothActive(viewer);
    expect(viewer.becameTrusted, isTrue);
    final asked = rig.host.prompts.asked<AcceptRequestPrompt>().single;
    expect(asked.peer.id, rig.viewer.identity.id, reason: 'the prompt shows the verified identity');
    expect(rig.host.trusted.isTrusted(rig.viewer.identity.publicKeyB64), isTrue);
    await viewer.end('user');
    await waitUntil(() => rig.host.manager.hostSessions.isEmpty, what: 'first session gone');

    final again = await rig.dial();
    await rig.bothActive(again);
    expect(rig.host.prompts.asked<AcceptRequestPrompt>(), hasLength(1), reason: 'trusted: nobody is asked');
    expect(rig.viewer.sentControl.where((m) => m['t'] == 'auth').last['method'], 'trusted');
    expect(rig.host.sent('auth_result').last['trusted'], isTrue);
  });

  e2e('j) dialing the LAN address of the host works like loopback', (rig) async {
    final lan = rig.host.connectivity.report.value.lanIPv4;
    print('host LAN addresses: $lan');
    expect(lan, isNotEmpty, reason: 'the runner must have a LAN interface for this scenario');
    final viewer = await rig.dial(
      to: ConnectTarget(
        id: rig.host.identity.id,
        addresses: [NetAddress(lan.first, rig.host.manager.listener.port)],
      ),
    );
    await rig.authorize(viewer);
    final pc = viewer.debugPeerConnection!;
    await waitUntilAsync(
      () async => (await probeInboundVideo(pc)).decoding,
      timeout: const Duration(seconds: 25),
      what: 'video over the LAN address',
    );
    final pair = await probeSelectedPair(pc);
    print('selected pair over the LAN address: $pair');
    expect(pair!.localType, isNot('relay'));
    expect(viewer.peer.addresses, isNotEmpty, reason: 'the host advertises where it can be reached');
  });

  e2e('k) a denied request ends the session without ever capturing the screen', (rig) async {
    rig.host.prompts.accept = false;
    final viewer = await rig.dial();
    await waitUntil(() => viewer.authPrompt != null, what: 'viewer is offered the request method');
    viewer.requestAccess();
    await waitUntil(() => viewer.isEnded, what: 'viewer session ends after the denial');
    expect(viewer.endReason, 'denied');
    await waitUntil(() => rig.host.manager.history.records.isNotEmpty, what: 'host records the session');
    expect(rig.host.manager.history.records.single.reason, 'denied');
    expect(rig.host.prompts.asked<AcceptRequestPrompt>(), hasLength(1));
    expect(rig.host.platform.beforeCaptureCalls, 0, reason: 'a denied viewer never sees the screen');
    expect(rig.host.badge.shown, isEmpty);
    expect(rig.host.manager.hostSessions, isEmpty);
  });

  e2e('l) five wrong passwords lock password authorization out', (rig) async {
    var viewer = await rig.dial();
    await waitUntil(() => viewer.authPrompt != null, what: 'viewer is asked for a password');
    for (var i = 1; i <= 5; i++) {
      await viewer.submitPassword('wrong-$i');
      if (i < 5) {
        await waitUntil(() => rig.host.sent('auth_result').length == i, what: 'refusal $i');
        expect(rig.host.sent('auth_result').last['retry'], isTrue);
        await waitUntil(() => viewer.authPrompt?.error != null, what: 'viewer asks again after $i');
      }
    }
    await waitUntil(() => viewer.isEnded, what: 'the fifth failure ends the session');
    final fifth = rig.host.sent('auth_result').last;
    expect(fifth['reason'], 'bad_password');
    expect(fifth['retry'], isFalse);

    // Even the right password is refused now.
    viewer = await rig.dial();
    await waitUntil(() => viewer.authPrompt != null, what: 'second session asks for a password');
    await viewer.submitPassword(rig.host.credentials.oneTimePassword);
    await waitUntil(() => viewer.isEnded, what: 'the locked host refuses');
    expect(rig.host.sent('auth_result').last['reason'], 'locked');
    expect(rig.host.platform.beforeCaptureCalls, 0);
  });

  e2e('m) a view-only grant lets the picture through and keeps files and clipboard shut',
      (rig) async {
    final tmp = await Directory.systemTemp.createTemp('thelxis_e2e_viewonly_');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // Temp files only.
      }
    });
    final secret = await File('${tmp.path}/secret.txt').writeAsString('not for you');
    final viewer = await rig.dial();
    final host = await rig.authorize(viewer);
    expect(viewer.permissions, Permissions.viewOnly);
    expect(viewer.viewOnly, isTrue);
    expect(host.controlEnabled, isFalse);

    final pc = viewer.debugPeerConnection!;
    await waitUntilAsync(
      () async => (await probeInboundVideo(pc)).decoding,
      timeout: const Duration(seconds: 25),
      what: 'view-only still gets the picture',
    );

    await waitUntil(() => viewer.files != null && host.files != null, what: 'file endpoints');
    expect(host.files!.allowed, isFalse);
    await expectLater(
      viewer.files!.remote.roots(),
      throwsA(isA<RemoteFsException>().having((e) => e.kind, 'kind', RemoteFsErrorKind.denied)),
    );
    await expectLater(
      viewer.files!.remote.list(tmp.path),
      throwsA(isA<RemoteFsException>().having((e) => e.kind, 'kind', RemoteFsErrorKind.denied)),
    );
    await viewer.files!.sendFiles([secret.path]);
    await viewer.files!.whenIdle().timeout(const Duration(seconds: 20));
    final upload = viewer.files!.transfers.singleWhere((t) => t.isSend);
    expect(upload.status, TransferStatus.failed);
    expect(upload.error, TransferError.denied);
    expect(await rig.host.incoming.list().toList(), isEmpty);

    rig.viewer.clipboard.text = 'must stay local';
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(rig.host.clipboard.text, isNull);
    expect(rig.viewer.sent('clipboard'), isEmpty);
    expect(rig.host.injector.events, isEmpty, reason: 'no input reaches a view-only host');
  }, hostPermissions: Permissions.viewOnly);

  e2e('n) pausing control on the host stops input at once and releases what was held', (rig) async {
    final viewer = await rig.dial();
    final host = await rig.authorize(viewer);
    final inj = rig.host.injector;
    await waitUntil(() {
      viewer.encoder.mouseMove(0.1, 0.1);
      return inj.all<InjectedMove>().isNotEmpty;
    }, what: 'input channel delivers');
    viewer.encoder.keyDown(Hid.controlLeft);
    await waitUntil(() => inj.all<InjectedKey>().any((k) => k.down), what: 'held key reaches the host');
    final mark = inj.events.length;

    host.setControlAllowed(false);
    await waitUntil(() => viewer.viewOnly, what: 'viewer learns control was paused');
    expect(viewer.permissions!.control, isFalse);
    expect(inj.events.skip(mark).map((e) => e.toString()), containsAll(['key(0x700e0, up)', 'releaseAll()']));
    expect(viewer.encoder.heldKeys, isEmpty);

    final paused = inj.events.length;
    viewer.encoder.mouseMove(0.9, 0.9);
    viewer.encoder.keyDown(Hid.keyA);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(inj.events.length, paused, reason: 'nothing is injected while control is paused');

    host.setControlAllowed(true);
    await waitUntil(() => !viewer.viewOnly, what: 'viewer learns control is back');
    await waitUntil(() {
      viewer.encoder.mouseMove(0.2, 0.2);
      return inj.events.skip(paused).any((e) => e is InjectedMove);
    }, what: 'input flows again');
  });

  e2e('o) switching the display re-captures and aims input at the new display', (rig) async {
    final viewer = await rig.dial();
    final host = await rig.authorize(viewer);
    await waitUntil(() => viewer.displays.length == 2, what: 'viewer lists both displays');
    expect(viewer.activeDisplayId, '0');
    final pc = viewer.debugPeerConnection!;
    await waitUntilAsync(
      () async => (await probeInboundVideo(pc)).decoding,
      timeout: const Duration(seconds: 25),
      what: 'first display decodes',
    );
    final before = (await probeInboundVideo(pc)).framesDecoded;

    viewer.selectDisplay('1');
    await waitUntil(() => viewer.activeDisplayId == '1', what: 'host confirms the new display');
    await waitUntilAsync(
      () async => (await probeInboundVideo(pc)).framesDecoded > before,
      timeout: const Duration(seconds: 25),
      what: 'frames keep arriving after the switch',
    );
    final inj = rig.host.injector;
    await waitUntil(() {
      viewer.encoder.mouseMove(0.5, 0.5);
      return inj.all<InjectedMove>().any((m) => m.display.id == '1');
    }, what: 'input now targets display 1');
    expect(host.phase, SessionPhase.active);
  }, hostDisplays: 2);

  e2e('p) two viewers at once: the badge lists both and capture stops with the last one', (rig) async {
    final first = await rig.dial();
    await rig.authorize(first);
    final second = await rig.connectExtra(await rig.addViewer('Viewer2'));
    await waitUntil(() => rig.host.manager.liveHostSessions.length == 2, what: 'two live sessions');
    await waitUntil(() => (rig.host.badge.current?.peers.length ?? 0) == 2, what: 'badge lists both viewers');
    expect(rig.host.badge.current!.peers, unorderedEquals(['Viewer', 'Viewer2']));
    expect(rig.host.manager.captures.active, 2);
    expect(rig.host.platform.beforeCaptureCalls, 1, reason: 'the capture service starts with the first viewer');

    for (final s in [first, second]) {
      await waitUntilAsync(
        () async => (await probeInboundVideo(s.debugPeerConnection!)).decoding,
        timeout: const Duration(seconds: 25),
        what: 'both viewers decode video',
      );
    }

    await first.end('user');
    await waitUntil(() => rig.host.manager.liveHostSessions.length == 1, what: 'first viewer gone');
    await waitUntil(() => rig.host.badge.current?.peers.length == 1, what: 'badge shrinks to one viewer');
    expect(rig.host.badge.current!.peers, ['Viewer2']);
    expect(rig.host.badge.dismissCalls, 0, reason: 'the badge stays while anyone is watching');
    expect(rig.host.platform.afterCaptureCalls, 0);

    await second.end('user');
    await waitUntil(() => rig.host.badge.current == null, what: 'badge goes with the last viewer');
    expect(rig.host.manager.captures.active, 0);
    expect(rig.host.platform.afterCaptureCalls, 1);
  });

  e2e('q) reverse connection: the controlled device dials out and offers control', (rig) async {
    final hostSession = await rig.host.manager.offerControl(ConnectTarget(
      id: rig.viewer.identity.id,
      addresses: [NetAddress('127.0.0.1', rig.viewer.manager.listener.port)],
    ));
    await waitUntil(() => rig.viewer.manager.viewerSessions.isNotEmpty, what: 'the viewer side accepts the offer');
    final viewer = rig.viewer.manager.viewerSessions.single;
    await rig.bothActive(viewer);
    expect(rig.viewer.prompts.asked<ReverseOfferPrompt>().single.peer.id, rig.host.identity.id);
    expect(viewer.permissions, const Permissions());
    expect(hostSession.sharing, isTrue);

    final pc = viewer.debugPeerConnection!;
    await waitUntilAsync(
      () async => (await probeInboundVideo(pc)).decoding,
      timeout: const Duration(seconds: 25),
      what: 'video flows in reverse mode',
    );
    final inj = rig.host.injector;
    await waitUntil(() {
      viewer.encoder.mouseMove(0.3, 0.7);
      return inj.all<InjectedMove>().isNotEmpty;
    }, what: 'input flows in reverse mode');
  }, viewerListens: true);

  e2e('r) the session survives a dropped signaling connection and resumes it', (rig) async {
    final viewer = await rig.dial();
    final host = await rig.authorize(viewer);
    final pc = viewer.debugPeerConnection!;
    await waitUntilAsync(
      () async => (await probeInboundVideo(pc)).decoding,
      timeout: const Duration(seconds: 25),
      what: 'video before the drop',
    );

    viewer.channel.debugDropSocket();
    await waitUntil(() => viewer.signalingDetached, what: 'viewer notices the dropped socket');
    expect(viewer.phase, SessionPhase.active, reason: 'media does not depend on signaling');
    await waitUntil(
      () => !viewer.signalingDetached && viewer.channel.isAttached && host.channel.isAttached,
      timeout: const Duration(seconds: 20),
      what: 'both ends have a signaling socket again',
    );
    expect(viewer.phase, SessionPhase.active);
    expect(host.phase, SessionPhase.active);

    final inj = rig.host.injector;
    await waitUntil(() {
      viewer.encoder.mouseMove(0.6, 0.4);
      return inj.all<InjectedMove>().isNotEmpty;
    }, what: 'input still flows after the resume');

    // The resumed socket carries the farewell.
    await viewer.end('user');
    await waitUntil(() => host.isEnded, what: 'host session ends');
    expect(host.endReason, 'remote');
  });
}

/// Runs [body] against a fresh host and viewer, prints the state when it
/// fails, tears everything down and then checks that no timer was left behind.
void e2e(
  String name,
  Future<void> Function(E2ERig rig) body, {
  Permissions? hostPermissions,
  bool viewerListens = false,
  int hostDisplays = 1,
}) {
  testWidgets(name, (tester) async {
    final audit = TimerAudit();
    await runZoned(() async {
      final rig = await E2ERig.start(
        hostPermissions: hostPermissions,
        viewerListens: viewerListens,
        hostDisplays: hostDisplays,
      );
      try {
        await body(rig);
      } catch (_) {
        print('--- state at failure ---\n${rig.describe()}');
        rethrow;
      } finally {
        await rig.dispose();
      }
    }, zoneSpecification: audit.specification);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final leaks = audit.leaks();
    expect(leaks, isEmpty, reason: 'timers still running after the scenario ended (of ${audit.created} created)');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
