import 'dart:math' as math;
import 'dart:ui';

/// Largest rectangle with the video's aspect ratio that fits [viewport],
/// centred (BoxFit.contain). Returns [Rect.zero] while the video size is
/// unknown.
Rect computeVideoRect(Size viewport, Size video) {
  if (video.width <= 0 || video.height <= 0 || viewport.isEmpty) return Rect.zero;
  final scale = math.min(viewport.width / video.width, viewport.height / video.height);
  final w = video.width * scale;
  final h = video.height * scale;
  return Rect.fromLTWH((viewport.width - w) / 2, (viewport.height - h) / 2, w, h);
}

/// Maps a point in the letterboxed [videoRect] to 0..1 display coordinates.
/// Returns null when the point is outside the rectangle, unless [clamp] is set
/// (used for moves so the cursor can reach the edge of the remote screen).
Offset? mapToNormalized(Offset point, Rect videoRect, {bool clamp = false}) {
  if (videoRect.isEmpty) return null;
  var nx = (point.dx - videoRect.left) / videoRect.width;
  var ny = (point.dy - videoRect.top) / videoRect.height;
  final inside = nx >= 0 && nx <= 1 && ny >= 0 && ny <= 1;
  if (!inside && !clamp) return null;
  nx = nx.clamp(0.0, 1.0);
  ny = ny.clamp(0.0, 1.0);
  return Offset(nx, ny);
}

/// Inverse of [mapToNormalized].
Offset normalizedToPoint(Offset normalized, Rect videoRect) => Offset(
      videoRect.left + normalized.dx * videoRect.width,
      videoRect.top + normalized.dy * videoRect.height,
    );

/// Zoom/pan applied on top of the fitted video: `viewport = scene * scale +
/// translation`. Immutable; every operation returns a clamped copy.
class ViewTransform {
  const ViewTransform({this.scale = 1.0, this.translation = Offset.zero});

  static const ViewTransform identity = ViewTransform();

  static const double maxScale = 8.0;

  final double scale;
  final Offset translation;

  bool get isIdentity => scale == 1.0 && translation == Offset.zero;

  /// Scene point (fitted-video coordinates) for a viewport point.
  Offset toScene(Offset viewportPoint) =>
      (viewportPoint - translation) / scale;

  /// Viewport point for a scene point.
  Offset toViewport(Offset scenePoint) => scenePoint * scale + translation;

  /// Zoom by [factor] keeping the scene point under [focal] fixed.
  ViewTransform zoomAt(Offset focal, double factor, Size viewport, {double minScale = 1.0}) {
    final next = (scale * factor).clamp(minScale, maxScale);
    final k = next / scale;
    final t = focal - (focal - translation) * k;
    return ViewTransform(scale: next, translation: t).clamped(viewport);
  }

  ViewTransform panBy(Offset delta, Size viewport) =>
      ViewTransform(scale: scale, translation: translation + delta).clamped(viewport);

  /// Keeps the content covering the viewport when it is larger than it, and
  /// centred when smaller (1:1 mode of a small remote screen).
  ViewTransform clamped(Size viewport) {
    double axis(double t, double extent) {
      final content = extent * scale;
      if (content <= extent) return (extent - content) / 2;
      return t.clamp(extent - content, 0.0);
    }

    return ViewTransform(
      scale: scale,
      translation: Offset(
        axis(translation.dx, viewport.width),
        axis(translation.dy, viewport.height),
      ),
    );
  }

  /// Scale at which one video pixel equals one device pixel.
  static double actualSizeScale({
    required Rect fitted,
    required Size video,
    required double devicePixelRatio,
  }) {
    if (fitted.isEmpty || video.isEmpty) return 1.0;
    return (video.width / devicePixelRatio) / fitted.width;
  }

  @override
  bool operator ==(Object other) =>
      other is ViewTransform && other.scale == scale && other.translation == translation;

  @override
  int get hashCode => Object.hash(scale, translation);
}

/// Full pipeline: a point in viewport coordinates -> normalised display
/// coordinates, taking the zoom/pan [transform] into account.
Offset? viewportToNormalized({
  required Offset point,
  required Size viewport,
  required Size video,
  ViewTransform transform = ViewTransform.identity,
  bool clamp = false,
}) {
  final fitted = computeVideoRect(viewport, video);
  return mapToNormalized(transform.toScene(point), fitted, clamp: clamp);
}
