import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../session/geometry.dart';

enum FitMode {
  /// Whole remote screen visible (letterboxed).
  fit,

  /// One remote pixel per device pixel.
  actual,
}

/// Zoom/pan state of the remote picture and the mapping from viewport
/// positions to remote coordinates. Shared by the toolbar (fit / 1:1), the
/// pointer layers, and the painted video so all three always agree.
class ViewController extends ChangeNotifier {
  ViewController({this.followPointer = false});

  /// Desktop: in 1:1 mode the view pans with the pointer (the remote cursor
  /// stays under the local pointer). Touch: pan and zoom are explicit.
  final bool followPointer;

  /// Touch devices: the virtual remote cursor in normalised remote
  /// coordinates. Lives here (not in the touch layer) so the on-screen mouse
  /// buttons can press at the same spot the touch layer points to.
  final ValueNotifier<Offset> cursor = ValueNotifier(const Offset(0.5, 0.5));

  FitMode _mode = FitMode.fit;
  ViewTransform _explicit = ViewTransform.identity;
  Offset _pointer = Offset.zero;

  @override
  void dispose() {
    cursor.dispose();
    super.dispose();
  }

  FitMode get mode => _mode;
  ViewTransform get explicit => _explicit;

  void setMode(FitMode mode) {
    if (_mode == mode && _explicit.isIdentity) return;
    _mode = mode;
    _explicit = ViewTransform.identity;
    notifyListeners();
  }

  void reset() {
    _mode = FitMode.fit;
    _explicit = ViewTransform.identity;
    notifyListeners();
  }

  /// Last pointer position in viewport coordinates (follow-pointer mode).
  void movePointer(Offset p) {
    if (p == _pointer) return;
    _pointer = p;
    if (_mode == FitMode.actual && followPointer) notifyListeners();
  }

  void zoomAt(Offset focal, double factor, Size viewport) {
    _explicit = _explicit.zoomAt(focal, factor, viewport);
    _mode = FitMode.fit;
    notifyListeners();
  }

  void panBy(Offset delta, Size viewport) {
    if (_explicit.scale <= 1.0) return;
    _explicit = _explicit.panBy(delta, viewport);
    notifyListeners();
  }

  /// Touch devices: jump to 1:1 around the viewport centre.
  void setActualSize(Size viewport, Size video, double devicePixelRatio) {
    final fitted = computeVideoRect(viewport, video);
    final s = ViewTransform.actualSizeScale(
      fitted: fitted,
      video: video,
      devicePixelRatio: devicePixelRatio,
    );
    final center = viewport.center(Offset.zero);
    _explicit = ViewTransform.identity.zoomAt(center, s, viewport, minScale: 0.1);
    _mode = FitMode.actual;
    notifyListeners();
  }

  /// The transform to paint and map with for the current state.
  ViewTransform effective(Size viewport, Size video, double devicePixelRatio) {
    if (_mode == FitMode.actual && followPointer) {
      final fitted = computeVideoRect(viewport, video);
      final s = ViewTransform.actualSizeScale(
        fitted: fitted,
        video: video,
        devicePixelRatio: devicePixelRatio,
      );
      if (s <= 1.0) return ViewTransform(scale: s).clamped(viewport);
      final v = viewport;
      final px = v.width == 0 ? 0.0 : (_pointer.dx / v.width).clamp(0.0, 1.0);
      final py = v.height == 0 ? 0.0 : (_pointer.dy / v.height).clamp(0.0, 1.0);
      return ViewTransform(
        scale: s,
        translation: Offset(-px * v.width * (s - 1), -py * v.height * (s - 1)),
      ).clamped(viewport);
    }
    return _explicit.clamped(viewport);
  }
}
