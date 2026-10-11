import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../file_transfer_endpoint.dart';
import '../../ui/theme.dart';
import 'files_strings.dart';

enum PickKind { files, folder }

/// Opens the system picker and queues what the user chose. Returns how many
/// transfers were queued (0 if cancelled or nothing could be sent).
///
/// [remoteDir] (viewer → host only) is a directory on the host to upload into.
Future<int> pickAndSendFiles(
  BuildContext context,
  FileTransferEndpoint endpoint, {
  PickKind kind = PickKind.files,
  String? remoteDir,
}) async {
  final strings = FilesStrings.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final List<String> paths;
  try {
    if (kind == PickKind.folder) {
      final dir = await getDirectoryPath();
      paths = dir == null ? const [] : [dir];
    } else {
      final files = await openFiles();
      paths = [for (final f in files) f.path];
    }
  } catch (_) {
    messenger?.showSnackBar(SnackBar(content: Text(strings.sendFailed)));
    return 0;
  }
  if (paths.isEmpty) return 0;
  return _queue(messenger, strings, endpoint, paths, remoteDir);
}

/// Queues [paths] (files and / or folders) and reports problems with a
/// snackbar. Use it as the `onFiles` of a `FileDropTarget` so a refused or
/// failed drop is visible to the user.
Future<int> sendPathsWithFeedback(
  BuildContext context,
  FileTransferEndpoint endpoint,
  List<String> paths, {
  String? remoteDir,
}) {
  return _queue(ScaffoldMessenger.maybeOf(context), FilesStrings.of(context), endpoint, paths, remoteDir);
}

Future<int> _queue(
  ScaffoldMessengerState? messenger,
  FilesStrings strings,
  FileTransferEndpoint endpoint,
  List<String> paths,
  String? remoteDir,
) async {
  if (paths.isEmpty) return 0;
  final before = endpoint.transfers.length;
  try {
    await endpoint.sendFiles(paths, remoteDir: remoteDir);
  } on FileTransferException catch (e) {
    final text = switch (e.error) {
      TransferError.denied => strings.notAllowed,
      TransferError.closed => strings.connectionClosed,
      _ => strings.sendFailed,
    };
    messenger?.showSnackBar(SnackBar(content: Text(text)));
    return 0;
  } catch (_) {
    messenger?.showSnackBar(SnackBar(content: Text(strings.sendFailed)));
    return 0;
  }
  return endpoint.transfers.length - before;
}

/// "Send" button with a Files / Folder menu.
class SendFilesMenuButton extends StatelessWidget {
  const SendFilesMenuButton({super.key, required this.endpoint, this.remoteDir, this.onQueued, this.compact = false});

  final FileTransferEndpoint endpoint;
  final String? remoteDir;

  /// Called with the number of queued transfers (> 0).
  final ValueChanged<int>? onQueued;

  /// Icon-only variant for toolbars.
  final bool compact;

  Future<void> _pick(BuildContext context, PickKind kind) async {
    final n = await pickAndSendFiles(context, endpoint, kind: kind, remoteDir: remoteDir);
    if (n > 0) onQueued?.call(n);
  }

  @override
  Widget build(BuildContext context) {
    final s = FilesStrings.of(context);
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.upload_file_rounded),
          onPressed: () => _pick(context, PickKind.files),
          child: Text(s.sendFiles),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.drive_folder_upload_rounded),
          onPressed: () => _pick(context, PickKind.folder),
          child: Text(s.sendFolder),
        ),
      ],
      builder: (context, controller, _) {
        void toggle() => controller.isOpen ? controller.close() : controller.open();
        if (compact) {
          return IconButton(
            tooltip: s.send,
            onPressed: toggle,
            icon: const Icon(Icons.upload_rounded),
          );
        }
        return FilledButton.icon(
          onPressed: toggle,
          style: context.secondaryButton,
          icon: const Icon(Icons.upload_rounded, size: 18),
          label: Text(s.send),
        );
      },
    );
  }
}
