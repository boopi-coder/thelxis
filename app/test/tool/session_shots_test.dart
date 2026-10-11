// Renders the session view (toolbar + files panel) to PNG. Opt-in like
// screenshots_test.dart: THELXIS_SHOTS=/dir flutter test test/tool/session_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoValue;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/app_services.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/log.dart';
import 'package:thelxis/core/settings.dart';
import 'package:thelxis/core/system_info.dart';
import 'package:thelxis/desktop/desktop_integration.dart';
import 'package:thelxis/files/files.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/session/session_manager.dart';
import 'package:thelxis/session/viewer_session.dart';
import 'package:thelxis/ui/session/session_view.dart';
import 'package:thelxis/ui/shell_controller.dart';
import 'package:thelxis/ui/theme.dart';

import '../files/support/test_fonts.dart';
import '../support/channel_pair.dart';
import '../support/fakes.dart';

final String? _out = Platform.environment['THELXIS_SHOTS'];
final GlobalKey _key = GlobalKey();

void main() {
  Logger.sink = (_, _) {};
  setUpAll(() async {
    await loadTestFonts();
    // macOS text uses the system font family; point it at Roboto here.
    final root0 = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/development/flutter';
    final sys = FontLoader('.AppleSystemUIFont');
    for (final n in ['Regular', 'Medium', 'Bold']) {
      sys.addFont(Future.value(ByteData.sublistView(
          File('$root0/bin/cache/artifacts/material_fonts/Roboto-$n.ttf').readAsBytesSync())));
    }
    await sys.load();
    final root = Platform.environment['FLUTTER_ROOT'] ?? '${Platform.environment['HOME']}/development/flutter';
    final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await loader.load();
    }
  });
  if (_out == null) {
    test('session screenshots are opt-in (set THELXIS_SHOTS)', () {}, skip: 'set THELXIS_SHOTS to render');
    return;
  }

  for (final (name, brightness) in [('light', Brightness.light), ('dark', Brightness.dark)]) {
    testWidgets('session view $name', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      tester.view.physicalSize = const Size(2400, 1500);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      late AppServices services;
      late ChannelPair pair;
      late ViewerSession session;
      final filesPair = FileChannelPair();
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final identity = await Identity.fromSeed(List<int>.filled(32, 61));
        services = AppServices.create(
          prefs: prefs,
          identity: identity,
          systemInfo: SystemInfo.fallback(),
          connectivity: FakeConnectivity(),
          platform: FakeHostPlatform(),
          badge: FakeBadge(),
        );
        final host = await Identity.fromSeed(List<int>.filled(32, 62));
        pair = await ChannelPair.create(self: identity, peerKey: host.publicKeyB64);
        session = ViewerSession(
          env: ViewerEnv(settings: services.settings, userName: 'Tester'),
          peer: PeerIdentity(key: host.publicKeyB64, id: host.id, name: 'Office PC', os: 'windows'),
          sid: 'sid',
          channel: pair.channel,
        )
          ..debugInputTap = (_) {}
          ..debugControlTap = (_) {}
          ..debugFingerprints = () async => (local: 'sha-256 11:22', remote: 'sha-256 99:88');
        session.debugAttachFiles(filesPair.a);
        session.debugReceiveControl({'t': 'hello', 'v': 2, 'methods': ['request'], 'nonce': 'n'});
        session.debugReceiveControl({
          't': 'auth_result',
          'ok': true,
          'permissions': {'view': true, 'control': true, 'clipboard': true, 'files': true},
        });
        session.renderer.value = RTCVideoValue(width: 1920, height: 1080);
        session.debugFirstFrame();
      });

      await tester.pumpWidget(RepaintBoundary(
        key: _key,
        child: MultiProvider(
          providers: [
            Provider<AppServices>.value(value: services),
            ChangeNotifierProvider<AppSettings>.value(value: services.settings),
            ChangeNotifierProvider<SessionManager>.value(value: services.sessions),
            Provider<DesktopIntegration>.value(value: services.desktop),
            ChangeNotifierProvider(create: (_) => ShellController()),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(brightness),
            home: Scaffold(body: SessionView(session: session)),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      Future<void> shot(String file) async {
        Directory(_out!).createSync(recursive: true);
        final boundary = _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$_out/$file.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      }

      await shot('session-$name-1-toolbar');
      await tester.tap(find.byTooltip('Files'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 400));
      await shot('session-$name-2-files');

      debugDefaultTargetPlatformOverride = null;
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await session.end('user');
        await pair.close();
        await filesPair.close();
      });
    });
  }
}
