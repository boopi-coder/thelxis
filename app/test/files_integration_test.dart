import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/app.dart';
import 'package:thelxis/app_services.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/files/files.dart';
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/session/prompts.dart';
import 'package:thelxis/session/session_manager.dart';
import 'package:thelxis/session/viewer_session.dart';
import 'package:thelxis/net/peer_identity.dart';

import 'support/channel_pair.dart';
import 'support/fakes.dart';
import 'support/host_rig.dart';

/// The file-transfer module wired into the real sessions: gating by the
/// authorization state and `permissions.files`, an end-to-end transfer
/// between a viewer session and a host session over in-memory channels,
/// notifications, and the host-side UI entry points.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Logger.sink = (_, _) {};

  late Directory tmp;
  late Directory hostIn;
  late Directory viewerIn;
  late File source;
  late HostRig rig;
  late FileChannelPair files;
  ViewerSession? viewer;
  ChannelPair? viewerPair;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('thelxis_fi_');
    hostIn = await Directory('${tmp.path}/host_in').create();
    viewerIn = await Directory('${tmp.path}/viewer_in').create();
    source = await File('${tmp.path}/hello.txt').writeAsString('hello world, this is a file');
    rig = HostRig()..incomingDir = () async => hostIn;
    await rig.setUp();
    files = FileChannelPair();
  });

  tearDown(() async {
    await viewer?.end('user');
    await viewerPair?.close();
    viewer = null;
    viewerPair = null;
    await rig.tearDown();
    await files.close();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  /// A real viewer session whose `files` channel is the in-memory [files].a.
  Future<ViewerSession> makeViewer() async {
    final id = await Identity.fromSeed(List<int>.filled(32, 77));
    viewerPair = await ChannelPair.create(self: id, peerKey: rig.hostId.publicKeyB64);
    final s = ViewerSession(
      env: ViewerEnv(settings: rig.settings, userName: 'Alice', incomingDir: () async => viewerIn),
      peer: PeerIdentity(key: rig.hostId.publicKeyB64, id: rig.hostId.id, name: 'Office PC', os: 'windows'),
      sid: 'sid',
      channel: viewerPair!.channel,
    )..debugAttachFiles(files.a);
    viewer = s;
    return s;
  }

  Future<void> authorizeWithOneTimePassword() async {
    rig.open();
    rig.session.debugReceiveControl(await rig.passwordAuth(rig.creds.oneTimePassword));
    await rig.nextOf('auth_result');
  }

  group('host gating', () {
    test('the host endpoint refuses everything until auth_result ok', () async {
      rig.open();
      rig.session.debugAttachFiles(files.b);
      final host = rig.session.files!;
      final v = await makeViewer();
      expect(host.allowed, isFalse, reason: 'the channel exists before anyone is authorized');

      await expectLater(
        v.files!.remote.roots(),
        throwsA(isA<RemoteFsException>().having((e) => e.kind, 'kind', RemoteFsErrorKind.denied)),
      );
      await v.files!.sendFiles([source.path]);
      await v.files!.whenIdle();
      expect(v.files!.transfers.single.status, TransferStatus.failed);
      expect(v.files!.transfers.single.error, TransferError.denied);
      expect(await hostIn.list().toList(), isEmpty);

      await authorizeWithOneTimePassword();
      expect(host.allowed, isTrue);
    });

    test('permissions.files = false keeps the endpoint closed even when authorized', () async {
      rig.approval = (p) async => const ApprovalResult(accepted: true, permissions: Permissions(files: false));
      rig.open();
      rig.session.debugAttachFiles(files.b);
      rig.session.debugReceiveControl({'t': 'auth', 'method': 'request', 'user': 'x'});
      final result = await rig.nextOf('auth_result');
      expect(result['ok'], isTrue);
      expect((result['permissions'] as Map)['files'], isFalse);
      expect(rig.session.files!.allowed, isFalse);

      final v = await makeViewer();
      await v.files!.sendFiles([source.path]);
      await v.files!.whenIdle();
      expect(v.files!.transfers.single.error, TransferError.denied);
      expect(await hostIn.list().toList(), isEmpty);
    });

    test('ending the session closes the endpoint and refuses further use', () async {
      await authorizeWithOneTimePassword();
      rig.session.debugAttachFiles(files.b);
      final host = rig.session.files!;
      expect(host.allowed, isTrue);
      await rig.session.end('user');
      expect(rig.session.files, isNull);
      expect(host.isClosed, isTrue);
      expect(host.allowed, isFalse);
    });

    test('a channel attached after the session ended is ignored', () async {
      rig.open();
      await rig.session.end('user');
      rig.session.debugAttachFiles(files.b);
      expect(rig.session.files, isNull);
    });
  });

  group('end to end', () {
    test('a file sent by the viewer lands in the host folder, byte for byte', () async {
      await authorizeWithOneTimePassword();
      rig.session.debugAttachFiles(files.b);
      final v = await makeViewer();

      await v.files!.sendFiles([source.path]);
      await v.files!.whenIdle();
      await untilTrue(() => File('${hostIn.path}/hello.txt').existsSync());
      await untilTrue(() => rig.session.files!.transfers.every((t) => t.status == TransferStatus.completed));
      expect(await File('${hostIn.path}/hello.txt').readAsString(), 'hello world, this is a file');
      expect(v.files!.transfers.single.status, TransferStatus.completed);
    });

    test('files the host sends arrive in the viewer folder', () async {
      await authorizeWithOneTimePassword();
      rig.session.debugAttachFiles(files.b);
      final v = await makeViewer();

      await rig.session.files!.sendFiles([source.path]);
      await untilTrue(() => File('${viewerIn.path}/hello.txt').existsSync());
      await untilTrue(() => v.files!.transfers.every((t) => t.status == TransferStatus.completed));
      expect(await File('${viewerIn.path}/hello.txt').readAsString(), 'hello world, this is a file');
    });
  });

  group('notifications', () {
    Future<AppServices> services() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      return AppServices.create(
        prefs: prefs,
        identity: await Identity.fromSeed(List<int>.filled(32, 90)),
        systemInfo: SystemInfo.fallback(),
        connectivity: FakeConnectivity(),
        platform: FakeHostPlatform(),
        badge: FakeBadge(),
      );
    }

    test('the session manager turns file events into notices with the peer name', () async {
      final sv = await services();
      addTearDown(() async {
        // The manager hears about the session ending, so it goes second.
        await rig.session.end('user');
        sv.sessions.dispose();
      });
      await authorizeWithOneTimePassword();
      sv.sessions.trackHostSession(rig.session);
      rig.session.debugAttachFiles(files.b);
      final v = await makeViewer();

      final texts = <String>[];
      final sub = sv.sessions.fileNotices.listen((n) {
        final t = n.text(FilesStrings.forLanguage('en'));
        if (t != null) texts.add(t);
      });
      addTearDown(sub.cancel);

      await v.files!.sendFiles([source.path]);
      await untilTrue(() => texts.any((t) => t.contains('sent hello.txt')));
      expect(texts, contains('Alice Mac sent hello.txt'));
      expect(texts, contains('Alice Mac is sending hello.txt'), reason: 'the controlled device hears about incoming files');
    });

    test('the viewer is not told about its own upload starting, only that it was sent', () async {
      await authorizeWithOneTimePassword();
      rig.session.debugAttachFiles(files.b);
      final v = await makeViewer();

      // Viewer sessions are tracked by the manager only after a real dial; the
      // hook it installs is the same one.
      final texts = <String>[];
      v.onFileEvent = (session, event) {
        final t = FileNotice(session, event).text(FilesStrings.forLanguage('en'));
        if (t != null) texts.add(t);
      };

      await v.files!.sendFiles([source.path]);
      await untilTrue(() => texts.contains('Sent hello.txt'));
      expect(texts.where((t) => t.contains('is sending')), isEmpty);
    });

    testWidgets('a received file shows up as a toast in the running app', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sv = (await tester.runAsync(services))!;
      await tester.runAsync(() async {
        await authorizeWithOneTimePassword();
        sv.sessions.trackHostSession(rig.session);
        rig.session.debugAttachFiles(files.b);
        await makeViewer();
      });
      await tester.pumpWidget(ThelxisApp(services: sv));
      await tester.pump(const Duration(milliseconds: 300));

      await tester.runAsync(() async {
        await viewer!.files!.sendFiles([source.path]);
        await untilTrue(() => File('${hostIn.path}/hello.txt').existsSync());
        await untilTrue(() => viewer!.files!.transfers.every((t) => t.status == TransferStatus.completed));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Alice Mac sent hello.txt'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 9));
    });
  });

  group('host-side entry points', () {
    Future<AppServices> servicesWithHost(WidgetTester tester, {required bool filesPermission}) async {
      final sv = (await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        return AppServices.create(
          prefs: prefs,
          identity: await Identity.fromSeed(List<int>.filled(32, 91)),
          systemInfo: SystemInfo.fallback(),
          connectivity: FakeConnectivity(),
          platform: FakeHostPlatform(),
          badge: FakeBadge(),
        );
      }))!;
      await tester.runAsync(() async {
        rig.approval = (p) async => ApprovalResult(accepted: true, permissions: Permissions(files: filesPermission));
        rig.open();
        rig.session.debugReceiveControl({'t': 'auth', 'method': 'request', 'user': 'x'});
        await rig.nextOf('auth_result');
        rig.session.debugAttachFiles(files.b);
        sv.sessions.trackHostSession(rig.session);
      });
      return sv;
    }

    testWidgets('the controlled banner and the Sessions screen open the file panel when files are allowed', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sv = await servicesWithHost(tester, filesPermission: true);
      await tester.pumpWidget(ThelxisApp(services: sv));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byKey(const ValueKey('banner-files')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('banner-files')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(FileTransferPanel), findsOneWidget);
      // The host side only has the Transfers tab (no remote browsing).
      await tester.tap(find.byTooltip('Close'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(FileTransferPanel), findsNothing);

      await tester.tap(find.text('Sessions').first);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('host-files')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('host-files')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(FileTransferPanel), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 9));
    });

    testWidgets('no Files button for the host when the viewer has no file access', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sv = await servicesWithHost(tester, filesPermission: false);
      await tester.pumpWidget(ThelxisApp(services: sv));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('banner-files')), findsNothing);
      await tester.tap(find.text('Sessions').first);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('host-files')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 9));
    });
  });
}
