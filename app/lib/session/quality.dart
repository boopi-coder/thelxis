import '../protocol/models.dart';

/// Sender-side limits for a [QualityPreset] (PROTOCOL.md section 5.2).
///
/// flutter_webrtc only applies non-null encoding fields, so "no cap" cannot be
/// expressed as null when lifting an earlier cap; the [uncapped*] constants are
/// high enough to never bind.
class QualityProfile {
  const QualityProfile({
    required this.maxFramerate,
    required this.maxBitrate,
    required this.degradation,
    required this.captureFps,
  });

  static const int uncappedBitrate = 100000000;
  static const int uncappedFramerate = 120;

  final int maxFramerate;
  final int maxBitrate;

  /// `balanced`, `maintain-framerate` or `maintain-resolution`.
  final String degradation;

  /// Frame rate to request from the screen capturer.
  final int captureFps;
}

QualityProfile qualityProfileFor(QualityPreset preset) {
  switch (preset) {
    case QualityPreset.auto:
      return const QualityProfile(
        maxFramerate: QualityProfile.uncappedFramerate,
        maxBitrate: QualityProfile.uncappedBitrate,
        degradation: 'balanced',
        captureFps: 30,
      );
    case QualityPreset.speed:
      return const QualityProfile(
        maxFramerate: 30,
        maxBitrate: 2500000,
        degradation: 'maintain-framerate',
        captureFps: 30,
      );
    case QualityPreset.balanced:
      return const QualityProfile(
        maxFramerate: 30,
        maxBitrate: 6000000,
        degradation: 'balanced',
        captureFps: 30,
      );
    case QualityPreset.quality:
      return const QualityProfile(
        maxFramerate: 60,
        maxBitrate: QualityProfile.uncappedBitrate,
        degradation: 'maintain-resolution',
        captureFps: 60,
      );
  }
}
