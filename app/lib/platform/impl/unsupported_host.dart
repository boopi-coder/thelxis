// Fallback for operating systems the app cannot host from (iOS, web, ...).

import '../host_platform.dart';

class UnsupportedHostPlatform implements HostPlatform {
  final _NoopInjector _input = _NoopInjector();

  @override
  bool get hostSupported => false;

  @override
  bool get inputSupported => false;

  @override
  Future<PermissionStatus> permissionStatus(HostPermission permission) async =>
      PermissionStatus.notRequired;

  @override
  Future<void> requestPermission(HostPermission permission) async {}

  @override
  Future<List<HostDisplay>> displays() async => const [];

  @override
  Future<void> beforeCapture() async {}

  @override
  Future<void> afterCapture() async {}

  @override
  InputInjector get input => _input;
}

class _NoopInjector implements InputInjector {
  @override
  void mouseMove(HostDisplay display, double nx, double ny) {}

  @override
  void mouseButton(MouseButton button, bool down) {}

  @override
  void scroll(double dx, double dy) {}

  @override
  void key(int usbHid, bool down) {}

  @override
  void text(String text) {}

  @override
  Future<void> special(SpecialAction action) async {}

  @override
  void releaseAll() {}
}
