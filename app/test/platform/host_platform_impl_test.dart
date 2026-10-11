import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/platform/host_platform.dart';
import 'package:thelxis/platform/impl/host_platform_impl.dart';
import 'package:thelxis/platform/impl/linux_host.dart';
import 'package:thelxis/platform/impl/unsupported_host.dart';

void main() {
  group('isWaylandSession', () {
    test('XDG_SESSION_TYPE is authoritative', () {
      expect(isWaylandSession({'XDG_SESSION_TYPE': 'wayland'}), isTrue);
      expect(isWaylandSession({'XDG_SESSION_TYPE': 'Wayland'}), isTrue);
      expect(isWaylandSession({'XDG_SESSION_TYPE': 'x11'}), isFalse);
      expect(
        isWaylandSession({
          'XDG_SESSION_TYPE': 'x11',
          'WAYLAND_DISPLAY': 'wayland-0',
        }),
        isFalse,
      );
    });

    test('falls back to WAYLAND_DISPLAY when the type is unset', () {
      expect(isWaylandSession({'WAYLAND_DISPLAY': 'wayland-0'}), isTrue);
      expect(isWaylandSession({'DISPLAY': ':0'}), isFalse);
      expect(isWaylandSession({}), isFalse);
    });
  });

  group('LinuxHostPlatform capability flags', () {
    test('Wayland: host yes, input no', () {
      final p = LinuxHostPlatform(
        env: {
          'XDG_SESSION_TYPE': 'wayland',
          'WAYLAND_DISPLAY': 'wayland-0',
          'DISPLAY': ':0',
        },
      );
      expect(p.hostSupported, isTrue);
      expect(p.inputSupported, isFalse);
    });

    test('no graphical session: neither', () {
      final p = LinuxHostPlatform(env: {});
      expect(p.hostSupported, isFalse);
      expect(p.inputSupported, isFalse);
    });
  });

  test('UnsupportedHostPlatform is inert', () async {
    final p = UnsupportedHostPlatform();
    expect(p.hostSupported, isFalse);
    expect(p.inputSupported, isFalse);
    expect(await p.displays(), isEmpty);
    p.input.key(0x00070004, true);
    p.input.releaseAll();
    await p.input.special(SpecialAction.lock);
  });

  test('factory returns an implementation for this OS without throwing', () {
    expect(createHostPlatform(), isA<HostPlatform>());
  });
}
