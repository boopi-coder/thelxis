import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../session/touch_gestures.dart';
import '../../session/viewer_session.dart';
import 'desktop_input_layer.dart';
import 'touch_input_layer.dart';
import 'view_controller.dart';

/// The remote picture with zoom/pan applied, and the input layer on top.
/// Reports its viewport and video size so the toolbar can compute 1:1.
class RemoteSurface extends StatelessWidget {
  const RemoteSurface({
    super.key,
    required this.session,
    required this.view,
    required this.isDesktop,
    required this.touchMode,
    required this.onMetrics,
    this.onPointerActivity,
  });

  final ViewerSession session;
  final ViewController view;
  final bool isDesktop;
  final TouchMode touchMode;
  final void Function(Size viewport, Size video) onMetrics;
  final ValueChanged<Offset>? onPointerActivity;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        return ValueListenableBuilder<RTCVideoValue>(
          valueListenable: session.renderer,
          builder: (context, value, _) {
            final video = Size(value.width, value.height);
            onMetrics(viewport, video);
            return Stack(
              fit: StackFit.expand,
              children: [
                ClipRect(
                  child: ListenableBuilder(
                    listenable: view,
                    builder: (context, child) {
                      final t = view.effective(viewport, video, dpr);
                      return Transform(
                        alignment: Alignment.topLeft,
                        transform: Matrix4.identity()
                          ..translateByDouble(t.translation.dx, t.translation.dy, 0, 1)
                          ..scaleByDouble(t.scale, t.scale, 1, 1),
                        child: child,
                      );
                    },
                    child: RTCVideoView(
                      session.renderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
                if (video.width > 0)
                  Positioned.fill(
                    child: isDesktop
                        ? DesktopInputLayer(
                            session: session,
                            view: view,
                            viewport: viewport,
                            video: video,
                            devicePixelRatio: dpr,
                            onActivity: onPointerActivity,
                          )
                        : TouchInputLayer(
                            session: session,
                            view: view,
                            viewport: viewport,
                            video: video,
                            devicePixelRatio: dpr,
                            mode: touchMode,
                          ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}
