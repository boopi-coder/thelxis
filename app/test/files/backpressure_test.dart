import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/files/file_channel.dart';
import 'package:thelxis/files/file_transfer_endpoint.dart';
import 'package:thelxis/files/protocol.dart';

import 'support/rig.dart';

void main() {
  const limit = kHighWaterBytes + kMaxChunkBytes + kFrameHeaderBytes;

  test('the sender stops at 1 MiB buffered and resumes when the link drains', () async {
    final rig = await Rig.create();
    addTearDown(rig.dispose);
    final f = await rig.makeFile('big.bin', 8 * 1024 * 1024, seed: 51);
    await rig.viewer.sendFiles([f.path]);
    await Rig.until(() => rig.host.transfers.isNotEmpty && rig.host.transfers.first.status == TransferStatus.active);

    rig.pair.a.held = true; // congested link: nothing leaves the buffer
    await Rig.until(() => rig.pair.a.bufferedAmount >= kHighWaterBytes);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final stalledAt = rig.pair.a.totalBytesSent;
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(rig.pair.a.totalBytesSent, stalledAt, reason: 'no more data may be queued while above the high-water mark');
    expect(rig.pair.a.bufferedAmount, lessThanOrEqualTo(limit));
    expect(rig.viewer.transfers.single.status, TransferStatus.active);

    rig.pair.a.release();
    await rig.viewer.whenIdle().timeout(const Duration(seconds: 30));
    expect(rig.viewer.transfers.single.isCompleted, isTrue);
    expect(rig.pair.a.maxBufferedSeen, lessThanOrEqualTo(limit));
    expect(await sha256OfFile(File('${rig.hostIncoming.path}/big.bin')), await sha256OfFile(f));
  });

  test('progress reflects the network, not the send buffer', () async {
    final rig = await Rig.create();
    addTearDown(rig.dispose);
    final f = await rig.makeFile('big.bin', 8 * 1024 * 1024, seed: 52);
    await rig.viewer.sendFiles([f.path]);
    await Rig.until(() => rig.host.transfers.isNotEmpty && rig.host.transfers.first.status == TransferStatus.active);
    rig.pair.a.held = true;
    await Rig.until(() => rig.pair.a.bufferedAmount >= kHighWaterBytes);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final t = rig.viewer.transfers.single;
    final onTheWire = rig.pair.a.totalBytesSent - rig.pair.a.bufferedAmount;
    expect(t.transferred, lessThanOrEqualTo(onTheWire + kMaxChunkBytes * 2));
    rig.pair.a.release();
    await rig.viewer.whenIdle();
  });

  test('a flapping link never deadlocks the transfer', () async {
    final rig = await Rig.create();
    addTearDown(rig.dispose);
    final f = await rig.makeFile('big.bin', 6 * 1024 * 1024, seed: 53);
    final rnd = Random(7);
    var flapping = true;
    unawaited(() async {
      while (flapping) {
        rig.pair.a.held = rnd.nextBool();
        if (!rig.pair.a.held) rig.pair.a.release();
        await Future<void>.delayed(Duration(milliseconds: 1 + rnd.nextInt(8)));
      }
      rig.pair.a.release();
    }());
    await rig.viewer.sendFiles([f.path]);
    await rig.viewer.whenIdle().timeout(const Duration(seconds: 60));
    flapping = false;
    expect(rig.viewer.transfers.single.isCompleted, isTrue);
    expect(await sha256OfFile(File('${rig.hostIncoming.path}/big.bin')), await sha256OfFile(f));
    expect(rig.pair.a.maxBufferedSeen, lessThanOrEqualTo(limit));
  });

  test('a smaller high-water mark from the config is honoured', () async {
    final rig = await Rig.create(config: const TransferConfig(highWaterBytes: 128 * 1024));
    addTearDown(rig.dispose);
    final f = await rig.makeFile('b.bin', 2 * 1024 * 1024, seed: 54);
    await rig.viewer.sendFiles([f.path]);
    await Rig.until(() => rig.host.transfers.isNotEmpty && rig.host.transfers.first.status == TransferStatus.active);
    rig.pair.a.held = true;
    await Rig.until(() => rig.pair.a.bufferedAmount >= 128 * 1024);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(rig.pair.a.bufferedAmount, lessThanOrEqualTo(128 * 1024 + kMaxChunkBytes + kFrameHeaderBytes));
    rig.pair.a.release();
    await rig.viewer.whenIdle();
    expect(rig.viewer.transfers.single.isCompleted, isTrue);
  });

  test('closing the channel releases a sender blocked on back-pressure', () async {
    final rig = await Rig.create();
    addTearDown(rig.dispose);
    final f = await rig.makeFile('big.bin', 8 * 1024 * 1024, seed: 55);
    await rig.viewer.sendFiles([f.path]);
    await Rig.until(() => rig.host.transfers.isNotEmpty && rig.host.transfers.first.status == TransferStatus.active);
    rig.pair.a.held = true;
    await Rig.until(() => rig.pair.a.bufferedAmount >= kHighWaterBytes);
    await rig.pair.close();
    await rig.viewer.whenIdle().timeout(const Duration(seconds: 10));
    expect(rig.viewer.transfers.single.error, TransferError.closed);
  });

  test('the in-memory channel rejects messages beyond the SCTP limit', () {
    final pair = FileChannelPair();
    expect(() => pair.a.sendBinary(FileFrame.allocate(1, 0).sublist(0, 4)), returnsNormally);
    expect(() => pair.a.sendText('x' * (256 * 1024 + 1)), throwsStateError);
  });
}
