import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:thelxis/files/file_channel.dart';
import 'package:thelxis/files/file_transfer_endpoint.dart';
import 'package:thelxis/files/hashing.dart';
import 'package:thelxis/files/protocol.dart';

/// A viewer endpoint and a host endpoint wired through an in-memory channel,
/// each with its own temp folders.
class Rig {
  Rig._(this.root, this.config, this.hostRoots, this.viewerAcceptIncoming, this.tamperViewer);

  final Directory root;
  final TransferConfig config;
  final FsRootsProvider? hostRoots;
  final FutureOr<bool> Function(IncomingOffer)? viewerAcceptIncoming;
  final FileChannel Function(FileChannel inner)? tamperViewer;

  late FileChannelPair pair;
  late FileTransferEndpoint viewer;
  late FileTransferEndpoint host;
  late final Directory viewerIncoming;
  late final Directory hostIncoming;
  late final Directory source;

  bool hostAllowed = true;

  /// Text frames each side sent, decoded.
  final List<FileMsg> viewerSent = [];
  final List<FileMsg> hostSent = [];
  final List<FileTransferEvent> viewerEvents = [];
  final List<FileTransferEvent> hostEvents = [];

  static Future<Rig> create({
    TransferConfig config = const TransferConfig(),
    FsRootsProvider? hostRoots,
    FutureOr<bool> Function(IncomingOffer)? viewerAcceptIncoming,
    FileChannel Function(FileChannel inner)? tamperViewer,
  }) async {
    final root = await Directory.systemTemp.createTemp('thelxis_files_test_');
    final rig = Rig._(root, config, hostRoots, viewerAcceptIncoming, tamperViewer);
    rig.viewerIncoming = await Directory('${root.path}/viewer_in').create();
    rig.hostIncoming = await Directory('${root.path}/host_in').create();
    rig.source = await Directory('${root.path}/src').create();
    rig._wire();
    return rig;
  }

  void _wire() {
    pair = FileChannelPair();
    pair.a.onSend = (m) {
      if (m is FileTextMessage) {
        final d = FileMsg.decode(m.text);
        if (d != null) viewerSent.add(d);
      }
    };
    pair.b.onSend = (m) {
      if (m is FileTextMessage) {
        final d = FileMsg.decode(m.text);
        if (d != null) hostSent.add(d);
      }
    };
    final tamper = tamperViewer;
    viewer = FileTransferEndpoint(
      channel: tamper != null ? tamper(pair.a) : pair.a,
      isHost: false,
      filesAllowed: () => true,
      incomingDir: () async => viewerIncoming,
      onEvent: viewerEvents.add,
      acceptIncoming: viewerAcceptIncoming,
      config: config,
    );
    host = FileTransferEndpoint(
      channel: pair.b,
      isHost: true,
      filesAllowed: () => hostAllowed,
      incomingDir: () async => hostIncoming,
      onEvent: hostEvents.add,
      rootsProvider: hostRoots,
      config: config,
    );
  }

  /// Drops the connection and sets up fresh endpoints on the same folders,
  /// like a new session after a network failure.
  Future<void> reconnect() async {
    await viewer.dispose();
    await host.dispose();
    viewerSent.clear();
    hostSent.clear();
    _wire();
  }

  Future<void> dispose() async {
    await viewer.dispose();
    await host.dispose();
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Temp cleanup is best effort.
    }
  }

  Future<File> makeFile(String relative, int size, {int seed = 1, Directory? inside}) async {
    final file = File('${(inside ?? source).path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(randomBytes(size, seed));
    return file;
  }

  /// Waits (bounded) until [test] holds.
  static Future<void> until(bool Function() test, {Duration timeout = const Duration(seconds: 20)}) async {
    final sw = Stopwatch()..start();
    while (!test()) {
      if (sw.elapsed > timeout) throw TimeoutException('condition not reached');
      await Future<void>.delayed(const Duration(milliseconds: 4));
    }
  }
}

Uint8List randomBytes(int length, int seed) {
  final rnd = Random(seed);
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = rnd.nextInt(256);
  }
  return out;
}

Future<String> sha256OfFile(File file) async {
  final hasher = FileHasher();
  await for (final chunk in file.openRead()) {
    hasher.add(chunk);
  }
  return hasher.finish();
}

/// Passes everything through but corrupts the first binary frame it sends.
class CorruptingChannel implements FileChannel {
  CorruptingChannel(this.inner);
  final FileChannel inner;
  bool _done = false;

  @override
  void sendText(String text) => inner.sendText(text);

  @override
  void sendBinary(Uint8List bytes) {
    if (!_done && bytes.length > 8) {
      _done = true;
      final copy = Uint8List.fromList(bytes);
      copy[copy.length - 1] ^= 0xFF;
      inner.sendBinary(copy);
    } else {
      inner.sendBinary(bytes);
    }
  }

  @override
  Stream<FileChannelMessage> get messages => inner.messages;
  @override
  int get bufferedAmount => inner.bufferedAmount;
  @override
  Future<void> waitBufferedBelow(int bytes) => inner.waitBufferedBelow(bytes);
  @override
  bool get isOpen => inner.isOpen;
  @override
  Future<void> close() => inner.close();
}
