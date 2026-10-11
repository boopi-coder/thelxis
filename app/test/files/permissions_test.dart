import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/files/file_transfer_endpoint.dart';
import 'package:thelxis/files/protocol.dart';

import 'support/rig.dart';

void main() {
  group('permissions.files = false', () {
    test('uploads are rejected with denied and nothing is written', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      rig.hostAllowed = false;
      final f = await rig.makeFile('a.bin', 1000);
      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();
      expect(rig.hostSent.whereType<Reject>().single.reason, RejectReason.denied);
      expect(rig.viewer.transfers.single.status, TransferStatus.failed);
      expect(rig.viewer.transfers.single.error, TransferError.denied);
      expect(await rig.hostIncoming.list().toList(), isEmpty);
    });

    test('browsing is denied with a typed error', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      rig.hostAllowed = false;
      await expectLater(
        rig.viewer.remote.roots(),
        throwsA(isA<RemoteFsException>().having((e) => e.kind, 'kind', RemoteFsErrorKind.denied)),
      );
      await expectLater(
        rig.viewer.remote.list(rig.source.path),
        throwsA(isA<RemoteFsException>().having((e) => e.kind, 'kind', RemoteFsErrorKind.denied)),
      );
    });

    test('downloads are denied', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('secret.bin', 1000);
      rig.hostAllowed = false;
      await rig.viewer.download(f.path, isDirectory: false);
      await rig.viewer.whenIdle();
      expect(rig.viewer.transfers.single.status, TransferStatus.failed);
      expect(rig.viewer.transfers.single.error, TransferError.denied);
      expect(await rig.viewerIncoming.list().toList(), isEmpty);
    });

    test('the host cannot start its own transfers either', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      rig.hostAllowed = false;
      final f = await rig.makeFile('a.bin', 10);
      await expectLater(
        rig.host.sendFiles([f.path]),
        throwsA(isA<FileTransferException>().having((e) => e.error, 'error', TransferError.denied)),
      );
    });

    test('granting the permission later makes everything work without a reconnect', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      rig.hostAllowed = false;
      final f = await rig.makeFile('a.bin', 5000);
      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();
      rig.viewer.clearFinished();
      rig.hostAllowed = true;
      await rig.viewer.sendFiles([f.path]);
      await rig.viewer.whenIdle();
      expect(rig.viewer.transfers.single.status, TransferStatus.completed);
      expect(await rig.viewer.remote.roots(), isNotNull);
    });
  });

  group('revoked while running', () {
    test('an upload in progress is aborted and cleaned up', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('big.bin', 40 * 1024 * 1024, seed: 3);
      await rig.viewer.sendFiles([f.path]);
      await Rig.until(() => rig.host.transfers.isNotEmpty && rig.host.transfers.first.transferred > 200000);

      rig.hostAllowed = false;
      await rig.viewer.whenIdle();
      await rig.host.whenIdle();

      expect(rig.host.transfers.first.status, TransferStatus.failed);
      expect(rig.host.transfers.first.error, TransferError.denied);
      expect(rig.viewer.transfers.first.isFinished, isTrue);
      expect(rig.viewer.transfers.first.isCompleted, isFalse);
      expect(await rig.hostIncoming.list().toList(), isEmpty);
      expect(rig.pair.a.totalBytesSent, lessThan(40 * 1024 * 1024));
    });

    test('a download in progress is aborted by the host', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final f = await rig.makeFile('big.bin', 40 * 1024 * 1024, seed: 4);
      await rig.viewer.download(f.path, isDirectory: false);
      await Rig.until(() => rig.viewer.transfers.isNotEmpty && rig.viewer.transfers.first.transferred > 200000);

      rig.hostAllowed = false;
      await rig.viewer.whenIdle();
      await rig.host.whenIdle();

      expect(rig.host.transfers.first.status, TransferStatus.failed);
      expect(rig.host.transfers.first.error, TransferError.denied);
      expect(rig.viewer.transfers.first.isCompleted, isFalse);
      expect(await rig.viewerIncoming.list().toList(), isEmpty);
    });

    test('queued downloads behind a revoked one are denied, not served', () async {
      final rig = await Rig.create();
      addTearDown(rig.dispose);
      final a = await rig.makeFile('a.bin', 30 * 1024 * 1024, seed: 5);
      final b = await rig.makeFile('b.bin', 1000, seed: 6);
      await rig.viewer.download(a.path, isDirectory: false);
      await rig.viewer.download(b.path, isDirectory: false);
      await Rig.until(() => rig.viewer.transfers.first.transferred > 100000);
      rig.hostAllowed = false;
      await rig.viewer.whenIdle();
      expect(rig.viewer.transfers.every((t) => !t.isCompleted), isTrue);
      expect(await File('${rig.viewerIncoming.path}/b.bin').exists(), isFalse);
    });
  });
}
