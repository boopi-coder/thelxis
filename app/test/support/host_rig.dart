import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:thelxis/core/identity.dart';
import 'package:thelxis/core/password_proof.dart';
import 'package:thelxis/core/settings.dart';
import 'package:thelxis/core/trusted_devices.dart';
import 'package:thelxis/net/peer_identity.dart';
import 'package:thelxis/platform/host_platform.dart';
import 'package:thelxis/protocol/models.dart';
import 'package:thelxis/session/capture.dart';
import 'package:thelxis/session/host_credentials.dart';
import 'package:thelxis/session/host_session.dart';
import 'package:thelxis/session/prompts.dart';

import 'channel_pair.dart';
import 'fake_media.dart';
import 'fakes.dart';

const kFpLocal = 'sha-256 AA:BB';
const kFpRemote = 'sha-256 CC:DD';

class InputRecorder implements InputInjector {
  final List<String> calls = [];
  @override
  void mouseMove(HostDisplay d, double nx, double ny) => calls.add('move ${d.id} $nx $ny');
  @override
  void mouseButton(MouseButton b, bool down) => calls.add('btn ${b.name} $down');
  @override
  void scroll(double dx, double dy) => calls.add('scroll $dx $dy');
  @override
  void key(int usbHid, bool down) => calls.add('key $usbHid $down');
  @override
  void text(String text) => calls.add('text $text');
  @override
  Future<void> special(SpecialAction action) async => calls.add('special ${action.name}');
  @override
  void releaseAll() => calls.add('releaseAll');
}

Future<void> untilTrue(bool Function() cond) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > const Duration(seconds: 8)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class HostRig {
  late Identity hostId;
  late Identity viewerId;
  late AppSettings settings;
  late TrustedDevices trusted;
  late HostCredentials creds;
  late FakeHostPlatform platform;
  late InputRecorder input;
  late ChannelPair pair;
  late HostSession session;
  final List<Map<String, dynamic>> sent = [];
  final List<String> notices = [];
  final List<FakeStream> streams = [];
  final List<int> captureFps = [];
  Future<ApprovalResult> Function(AcceptRequestPrompt prompt) approval =
      (p) async => ApprovalResult.denied;
  Object? captureError;

  /// Where received files land (tests point it at a temp folder).
  Future<Directory> Function()? incomingDir;

  /// Creates the fake capture stream for [d] and remembers it.
  Future<FakeStream> streamFor(HostDisplay d) async {
    final s = FakeStream('${d.id}-${streams.length}');
    streams.add(s);
    return s;
  }

  Future<void> setUp({
    int displays = 1,
    Permissions? reverse,
    InputRecorder? recorder,
    Duration inputCheckInterval = const Duration(seconds: 3),
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    hostId = await Identity.fromSeed(List<int>.filled(32, 11));
    viewerId = await Identity.fromSeed(List<int>.filled(32, 12));
    settings = AppSettings(prefs, defaultDeviceName: 'Host');
    trusted = TrustedDevices(prefs);
    creds = HostCredentials(identity: hostId, settings: settings);
    input = recorder ?? InputRecorder();
    platform = FakeHostPlatform(displayCount: displays, injector: input);
    pair = await ChannelPair.create(self: hostId, peerKey: viewerId.publicKeyB64);
    session = HostSession(
      env: HostEnv(
        settings: settings,
        identity: hostId,
        trusted: trusted,
        credentials: creds,
        platform: platform,
        captures: CaptureRegistry(),
        requestApproval: (p) => approval(p),
        incomingDir: incomingDir,
        onNotice: (t, m) => notices.add(t),
        startCapture: (d, all, {int fps = 30}) async {
          if (captureError != null) throw captureError!;
          captureFps.add(fps);
          final s = FakeStream('${d.id}-${streams.length}');
          streams.add(s);
          return s;
        },
      ),
      peer: PeerIdentity(
        key: viewerId.publicKeyB64,
        id: viewerId.id,
        name: 'Alice Mac',
        os: 'macos',
      ),
      channel: pair.channel,
      sid: 'test-sid',
      reversePermissions: reverse,
      inputCheckInterval: inputCheckInterval,
    )
      ..debugControlTap = sent.add
      ..debugFingerprints = () async => (local: kFpLocal, remote: kFpRemote);
  }

  Future<void> tearDown() async {
    await session.end('user');
    await pair.close();
  }

  Map<String, dynamic> hello() => sent.firstWhere((m) => m['t'] == 'hello');

  Future<Map<String, dynamic>> passwordAuth(String password) async => {
        't': 'auth',
        'method': 'password',
        'proof': await computePasswordProofB64(
          key: await derivePasswordKeySync(password, hostId.id),
          nonce: hello()['nonce'] as String,
          fingerprintA: kFpRemote,
          fingerprintB: kFpLocal,
        ),
      };

  Future<Map<String, dynamic>> nextOf(String type, {int after = 0}) async {
    late Map<String, dynamic> found;
    await untilTrue(() {
      final m = sent.skip(after).where((m) => m['t'] == type);
      if (m.isEmpty) return false;
      found = m.first;
      return true;
    });
    return found;
  }

  void open() => session.debugControlOpened();
}

