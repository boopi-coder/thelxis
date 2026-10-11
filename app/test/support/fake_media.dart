import 'package:flutter_webrtc/flutter_webrtc.dart';

/// A capture "stream" that records whether it was stopped, for host tests.
class FakeTrack extends MediaStreamTrack {
  FakeTrack(this._id);

  final String _id;
  bool stopped = false;

  @override
  String? get id => _id;
  @override
  String? get label => 'fake';
  @override
  String? get kind => 'video';
  @override
  bool enabled = true;
  @override
  bool? get muted => false;

  @override
  Future<void> stop() async => stopped = true;

  @override
  // ignore: deprecated_member_use
  Future<void> dispose() async => stopped = true;
}

class FakeStream extends MediaStream {
  FakeStream(String id) : super(id, 'local') {
    track = FakeTrack('track-$id');
  }

  late final FakeTrack track;
  bool disposed = false;

  @override
  bool? get active => !disposed;
  @override
  Future<void> getMediaTracks() async {}
  @override
  Future<void> addTrack(MediaStreamTrack track, {bool addToNative = true}) async {}
  @override
  Future<void> removeTrack(MediaStreamTrack track, {bool removeFromNative = true}) async {}
  @override
  List<MediaStreamTrack> getTracks() => [track];
  @override
  List<MediaStreamTrack> getAudioTracks() => const [];
  @override
  List<MediaStreamTrack> getVideoTracks() => [track];

  @override
  Future<void> dispose() async => disposed = true;
}
