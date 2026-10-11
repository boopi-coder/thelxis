import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/session/geometry.dart';
import 'package:thelxis/session/mouse_buttons.dart';

void main() {
  group('letterbox rect', () {
    test('wide video in a tall viewport is centred with bars top and bottom', () {
      final r = computeVideoRect(const Size(1000, 1000), const Size(1920, 1080));
      expect(r.left, closeTo(0, 1e-9));
      expect(r.width, closeTo(1000, 1e-9));
      expect(r.height, closeTo(562.5, 1e-9));
      expect(r.top, closeTo(218.75, 1e-9));
    });

    test('tall video in a wide viewport has bars left and right', () {
      final r = computeVideoRect(const Size(1000, 500), const Size(1080, 1920));
      expect(r.height, closeTo(500, 1e-9));
      expect(r.width, closeTo(281.25, 1e-9));
      expect(r.left, closeTo(359.375, 1e-9));
      expect(r.top, closeTo(0, 1e-9));
    });

    test('unknown video size yields an empty rect', () {
      expect(computeVideoRect(const Size(100, 100), Size.zero), Rect.zero);
      expect(computeVideoRect(Size.zero, const Size(10, 10)), Rect.zero);
    });
  });

  group('normalised mapping', () {
    final rect = computeVideoRect(const Size(1000, 1000), const Size(2000, 1000)); // 1000x500 at y=250

    test('corners and centre', () {
      expect(mapToNormalized(const Offset(0, 250), rect), const Offset(0, 0));
      expect(mapToNormalized(const Offset(1000, 750), rect), const Offset(1, 1));
      expect(mapToNormalized(const Offset(500, 500), rect), const Offset(0.5, 0.5));
    });

    test('the black bars are outside unless clamped', () {
      expect(mapToNormalized(const Offset(500, 100), rect), isNull);
      expect(mapToNormalized(const Offset(500, 900), rect), isNull);
      expect(mapToNormalized(const Offset(500, 100), rect, clamp: true), const Offset(0.5, 0));
      expect(mapToNormalized(const Offset(-50, 900), rect, clamp: true), const Offset(0, 1));
    });

    test('normalizedToPoint inverts mapToNormalized', () {
      for (final p in const [Offset(10, 260), Offset(321, 444), Offset(999, 749)]) {
        final n = mapToNormalized(p, rect)!;
        final back = normalizedToPoint(n, rect);
        expect((back - p).distance, lessThan(1e-9));
      }
    });
  });

  group('ViewTransform (zoom and pan)', () {
    const viewport = Size(800, 600);

    test('identity maps points to themselves', () {
      expect(ViewTransform.identity.toScene(const Offset(123, 45)), const Offset(123, 45));
    });

    test('zoomAt keeps the point under the focal fixed', () {
      const focal = Offset(300, 200);
      final z = ViewTransform.identity.zoomAt(focal, 3, viewport);
      expect(z.scale, 3);
      final scene = ViewTransform.identity.toScene(focal);
      final shown = z.toViewport(scene);
      expect((shown - focal).distance, lessThan(1e-9));
      expect((z.toScene(focal) - scene).distance, lessThan(1e-9));
    });

    test('zoom is clamped to [1, max] and pan keeps content covering the viewport', () {
      final z = ViewTransform.identity.zoomAt(const Offset(0, 0), 100, viewport);
      expect(z.scale, ViewTransform.maxScale);
      final panned = z.panBy(const Offset(5000, 5000), viewport);
      expect(panned.translation.dx, 0);
      expect(panned.translation.dy, 0);
      final far = z.panBy(const Offset(-99999, -99999), viewport);
      expect(far.translation.dx, viewport.width * (1 - z.scale));
      expect(far.translation.dy, viewport.height * (1 - z.scale));
      expect(ViewTransform.identity.zoomAt(const Offset(1, 1), 0.1, viewport).scale, 1);
    });

    test('a smaller-than-viewport scale (1:1 of a small screen) is centred', () {
      final t = const ViewTransform(scale: 0.5).clamped(viewport);
      expect(t.translation, const Offset(200, 150));
    });

    test('full pipeline: zoomed tap lands on the right remote pixel', () {
      const video = Size(1920, 1080);
      final fitted = computeVideoRect(viewport, video); // 800 x 450 at y=75
      // Zoom 2x around the viewport centre, then tap the viewport centre.
      final t = ViewTransform.identity.zoomAt(viewport.center(Offset.zero), 2, viewport);
      final n = viewportToNormalized(point: viewport.center(Offset.zero), viewport: viewport, video: video, transform: t)!;
      expect(n.dx, closeTo(0.5, 1e-9));
      expect(n.dy, closeTo(0.5, 1e-9));
      // The left edge of the viewport shows the video at x = 25%.
      final left = viewportToNormalized(point: const Offset(0, 300), viewport: viewport, video: video, transform: t)!;
      expect(left.dx, closeTo(0.25, 1e-9));
      // Pan to the bottom-right corner: viewport corner shows normalised (1,1) edge.
      final panned = t.panBy(const Offset(-99999, -99999), viewport);
      // Scene point (fitted.right, fitted.bottom) is shown at scale*scene + translation.
      final corner = panned.toViewport(Offset(fitted.right, fitted.bottom));
      final br = viewportToNormalized(
        point: corner,
        viewport: viewport,
        video: video,
        transform: panned,
      )!;
      expect(br.dx, closeTo(1.0, 1e-9));
      expect(br.dy, closeTo(1.0, 1e-9));
    });

    test('actualSizeScale makes one video pixel one device pixel', () {
      const video = Size(3840, 2160);
      final fitted = computeVideoRect(viewport, video);
      final s = ViewTransform.actualSizeScale(fitted: fitted, video: video, devicePixelRatio: 2);
      expect(fitted.width * s * 2, closeTo(video.width, 1e-6));
    });
  });

  group('MouseButtonTracker', () {
    test('translates button masks to wire numbers and diffs transitions', () {
      final t = MouseButtonTracker();
      expect(t.update(0x1), [(0, true)]);
      expect(t.update(0x1 | 0x2), [(2, true)]);
      expect(t.held, [0, 2]);
      expect(t.update(0x2), [(0, false)]);
      expect(t.update(0), [(2, false)]);
      expect(t.update(0x4 | 0x8 | 0x10), [(1, true), (3, true), (4, true)]);
      t.reset();
      expect(t.held, isEmpty);
    });
  });
}
