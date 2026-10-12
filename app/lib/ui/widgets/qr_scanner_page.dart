import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../core/log.dart';
import '../../l10n/strings.dart';
import '../../net/scan_payload.dart';
import '../../platform/host_platform.dart';
import '../../platform/impl/android_host.dart';
import '../theme.dart';

const _log = Logger('qr-scan');

/// Opens a scanner and resolves to the scanned text, or null when the user
/// closed it. Injected into the entry points so tests need no camera.
typedef QrScanLauncher = Future<String?> Function(BuildContext context, Set<ScanKind> accept);

/// Scanning is wired on Android only: it is the platform where typing or
/// pasting a long link/code is the real pain, and the only mobile one shipped.
/// `defaultTargetPlatform` (not `dart:io`) so widget tests can switch it.
bool get qrScanSupported => defaultTargetPlatform == TargetPlatform.android;

/// The real [QrScanLauncher]: a full-screen [QrScannerPage].
Future<String?> openQrScanner(BuildContext context, Set<ScanKind> accept) {
  HostPlatform? platform;
  try {
    platform = context.read<HostPlatform>();
  } on ProviderNotFoundException {
    platform = null;
  }
  final host = platform;
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => QrScannerPage(
        accept: accept,
        onOpenSettings: host is AndroidHostPlatform ? host.openAppDetails : null,
      ),
    ),
  );
}

/// Picks the first scanned value whose kind is in [accept], trimmed; null when
/// none qualifies.
String? firstAcceptedScan(Iterable<String?> values, Set<ScanKind> accept) {
  for (final v in values) {
    if (v == null) continue;
    if (accept.contains(classifyScan(v))) return v.trim();
  }
  return null;
}

/// Full-screen camera view that pops with the first QR code of an accepted
/// [ScanKind]. Everything else gets "not a Thelxis QR code" and scanning goes
/// on. Decoding is ML Kit's bundled on-device model (no network).
class QrScannerPage extends StatefulWidget {
  const QrScannerPage({
    super.key,
    required this.accept,
    this.onOpenSettings,
    @visibleForTesting this.debugPreview,
  });

  final Set<ScanKind> accept;

  /// Opens the system app settings, offered when camera access was denied.
  final Future<void> Function()? onOpenSettings;

  /// Replaces the camera (tests): gets the callback a detection would call.
  final Widget Function(void Function(List<String?> values) onScan)? debugPreview;

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> with WidgetsBindingObserver {
  MobileScannerController? _controller;
  bool _done = false;
  bool _rejected = false;
  bool _awaitingSettings = false;
  Timer? _rejectTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.debugPreview == null) {
      _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rejectTimer?.cancel();
    // Ours, not the MobileScanner widget's: disposing it releases the camera.
    unawaited(_controller?.dispose());
    super.dispose();
  }

  /// With its own controller the MobileScanner widget leaves the app
  /// lifecycle to us: release the camera in the background, take it back on
  /// return. After a trip to the app settings, start even without a previous
  /// grant so a fresh one takes effect; otherwise a denied permission is left
  /// alone (the permission prompt itself makes the app inactive/resumed).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        if (_awaitingSettings || c.value.hasCameraPermission) {
          _awaitingSettings = false;
          unawaited(_restart());
        }
      case AppLifecycleState.inactive:
        if (c.value.hasCameraPermission) unawaited(c.stop());
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        break;
    }
  }

  Future<void> _restart() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.start();
    } on MobileScannerException catch (e) {
      _log.w('camera restart failed', e.errorCode.name);
    }
  }

  Future<void> _openSettings() async {
    _awaitingSettings = true;
    await widget.onOpenSettings?.call();
  }

  void _onScan(List<String?> values) {
    if (_done || !mounted) return;
    final hit = firstAcceptedScan(values, widget.accept);
    if (hit != null) {
      _done = true;
      unawaited(HapticFeedback.mediumImpact());
      Navigator.of(context).pop(hit);
      return;
    }
    if (values.every((v) => v == null)) return;
    // The same foreign code is seen several times a second: keep the message
    // up while it stays in view instead of flickering it.
    _rejectTimer?.cancel();
    _rejectTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _rejected = false);
    });
    if (!_rejected) setState(() => _rejected = true);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final controller = _controller;
    final preview = widget.debugPreview?.call(_onScan) ??
        MobileScanner(
          controller: controller,
          onDetect: (capture) => _onScan([for (final b in capture.barcodes) b.rawValue]),
          errorBuilder: (context, error) => _ScanError(
            denied: error.errorCode == MobileScannerErrorCode.permissionDenied,
            onOpenSettings: widget.onOpenSettings == null ? null : _openSettings,
            onRetry: _restart,
          ),
        );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            preview,
            if (controller == null)
              _Viewfinder(hint: s.t('scan.hint'), rejected: _rejected ? s.t('scan.notThelxis') : null)
            else
              ValueListenableBuilder<MobileScannerState>(
                valueListenable: controller,
                builder: (context, state, _) => state.error != null
                    ? const SizedBox.shrink()
                    : _Viewfinder(hint: s.t('scan.hint'), rejected: _rejected ? s.t('scan.notThelxis') : null),
              ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(Gap.s),
                child: Row(
                  children: [
                    _RoundButton(
                      key: const ValueKey('scan-close'),
                      icon: Icons.close_rounded,
                      tooltip: s.t('common.close'),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                    if (controller != null)
                      ValueListenableBuilder<MobileScannerState>(
                        valueListenable: controller,
                        builder: (context, state, _) {
                          if (state.torchState == TorchState.unavailable || state.error != null) {
                            return const SizedBox.shrink();
                          }
                          final on = state.torchState == TorchState.on;
                          return _RoundButton(
                            key: const ValueKey('scan-torch'),
                            icon: on ? Icons.flashlight_off_rounded : Icons.flashlight_on_rounded,
                            tooltip: on ? s.t('scan.torchOff') : s.t('scan.torchOn'),
                            onPressed: () => unawaited(controller.toggleTorch()),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dimmed surroundings, a rounded frame and the hint under it.
class _Viewfinder extends StatelessWidget {
  const _Viewfinder({required this.hint, this.rejected});

  final String hint;
  final String? rejected;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, box) {
        final side = (box.biggest.shortestSide * 0.7).clamp(180.0, 320.0);
        final frame = Rect.fromCenter(
          center: Offset(box.maxWidth / 2, box.maxHeight * 0.44),
          width: side,
          height: side,
        );
        return Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _FramePainter(frame))),
            Positioned(
              left: Gap.xl,
              right: Gap.xl,
              top: frame.bottom + Gap.xl,
              child: Column(
                children: [
                  Text(
                    hint,
                    textAlign: TextAlign.center,
                    style: t.titleSmall?.copyWith(color: Colors.white, height: 1.3),
                  ),
                  const SizedBox(height: Gap.m),
                  AnimatedOpacity(
                    opacity: rejected == null ? 0 : 1,
                    duration: const Duration(milliseconds: 180),
                    child: Container(
                      key: const ValueKey('scan-rejected'),
                      padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
                      decoration: BoxDecoration(
                        color: const Color(0xE6FF9F0A),
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                      child: Text(
                        rejected ?? '',
                        textAlign: TextAlign.center,
                        style: t.labelLarge?.copyWith(color: Colors.black),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FramePainter extends CustomPainter {
  _FramePainter(this.frame);

  final Rect frame;

  @override
  void paint(Canvas canvas, Size size) {
    final hole = RRect.fromRectAndRadius(frame, const Radius.circular(24));
    final scrim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(hole);
    canvas.drawPath(scrim, Paint()..color = const Color(0x8C000000));
    canvas.drawRRect(
      hole,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.frame != frame;
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: Colors.white),
      style: IconButton.styleFrom(backgroundColor: const Color(0x66000000), minimumSize: const Size(48, 48)),
    );
  }
}

/// No camera: either access was denied (offer the app settings) or it could
/// not start (busy, missing).
class _ScanError extends StatelessWidget {
  const _ScanError({required this.denied, required this.onOpenSettings, required this.onRetry});

  final bool denied;
  final VoidCallback? onOpenSettings;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(Gap.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                denied ? Icons.no_photography_outlined : Icons.videocam_off_outlined,
                color: Colors.white70,
                size: 48,
              ),
              const SizedBox(height: Gap.l),
              Text(
                denied ? s.t('scan.denied.title') : s.t('scan.unavailable.title'),
                textAlign: TextAlign.center,
                style: t.titleMedium?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: Gap.s),
              Text(
                denied ? s.t('scan.denied.body') : s.t('scan.unavailable.body'),
                textAlign: TextAlign.center,
                style: t.bodyMedium?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: Gap.xl),
              if (denied && onOpenSettings != null)
                FilledButton.icon(
                  key: const ValueKey('scan-open-settings'),
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: Text(s.t('scan.openSettings')),
                )
              else
                OutlinedButton(
                  onPressed: onRetry,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white54),
                  ),
                  child: Text(s.t('scan.retry')),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
