// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:thelxis/files/files.dart';
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

    rig.viewer.clipboard.text = 'from the viewer: привет';
    await waitUntil(
      () => rig.host.clipboard.text == 'from the viewer: привет',
      timeout: wait,
      what: 'viewer clipboard reaches the host',
    );
    rig.host.clipboard.text = 'from the host: 你好';
    await waitUntil(
      () => rig.viewer.clipboard.text == 'from the host: 你好',
      timeout: wait,
      what: 'host clipboard reaches the viewer',
    );

    // A large clipboard still fits one SCTP message.
    final big = 'x' * (150 * 1024);
    rig.viewer.clipboard.text = big;
    await waitUntil(() => rig.host.clipboard.text == big, timeout: wait, what: '150 KiB clipboard reaches the host');

    // The receiving side must not echo what it was just given.
    await Future<void>.delayed(const Duration(seconds: 3));
    String summary(Iterable<Map<String, dynamic>> msgs) =>
        msgs.map((m) => '${(m['text'] as String).length}:${(m['text'] as String).substring(0, 8)}').toList().toString();
    expect(rig.viewer.sent('clipboard').length, 2,
        reason: 'viewer sent its two own changes only: ${summary(rig.viewer.sent('clipboard'))}');
    expect(rig.host.sent('clipboard').length, 1,
        reason: 'host sent its one own change only: ${summary(rig.host.sent('clipboard'))}');

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
}

/// Runs [body] against a fresh host and viewer, prints the state when it
/// fails, tears everything down and then checks that no timer was left behind.
void e2e(
  String name,
  Future<void> Function(E2ERig rig) body, {
  Permissions? hostPermissions,
}) {
  testWidgets(name, (tester) async {
    final audit = TimerAudit();
    await runZoned(() async {
      final rig = await E2ERig.start(hostPermissions: hostPermissions);
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
