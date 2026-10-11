import 'package:flutter/material.dart';

import '../file_transfer_endpoint.dart';
import 'files_strings.dart';
import 'pick_and_send.dart';
import 'remote_files_tab.dart';
import 'transfers_tab.dart';

/// Side panel for one session: the transfer queue and, for a viewer, a browser
/// for the host's files. Give it a bounded width (≈ 360–440 px) and height.
class FileTransferPanel extends StatefulWidget {
  const FileTransferPanel(this.endpoint, {super.key, this.onClose});

  final FileTransferEndpoint endpoint;

  /// Shows a close button in the header when set.
  final VoidCallback? onClose;

  @override
  State<FileTransferPanel> createState() => _FileTransferPanelState();
}

class _FileTransferPanelState extends State<FileTransferPanel> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: widget.endpoint.isHost ? 1 : 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _showTransfers() {
    if (_tabs.index != 0) _tabs.animateTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final s = FilesStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    final endpoint = widget.endpoint;
    final showRemote = !endpoint.isHost;

    return Material(
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
            child: Row(
              children: [
                Icon(Icons.folder_copy_rounded, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    s.panelTitle,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                SendFilesMenuButton(endpoint: endpoint, onQueued: (_) => _showTransfers()),
                if (widget.onClose != null)
                  IconButton(
                    tooltip: s.close,
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
          ),
          if (showRemote)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
                child: TabBar(
                  controller: _tabs,
                  dividerColor: Colors.transparent,
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicator: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(11)),
                  labelColor: scheme.onPrimaryContainer,
                  unselectedLabelColor: scheme.onSurfaceVariant,
                  labelStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                  splashBorderRadius: BorderRadius.circular(11),
                  tabs: [
                    Tab(height: 38, child: _TransfersTabLabel(endpoint: endpoint, label: s.tabTransfers)),
                    Tab(height: 38, text: s.tabRemote),
                  ],
                ),
              ),
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                TransfersTab(endpoint: endpoint),
                if (showRemote) RemoteFilesTab(endpoint: endpoint, onQueued: _showTransfers),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Transfers" with a live count of running ones.
class _TransfersTabLabel extends StatelessWidget {
  const _TransfersTabLabel({required this.endpoint, required this.label});

  final FileTransferEndpoint endpoint;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: endpoint,
      builder: (context, _) {
        final running = endpoint.transfers.where((t) => t.isRunning).length;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: running == 0
                  ? const SizedBox.shrink()
                  : Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                      decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(99)),
                      child: Text(
                        '$running',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: scheme.onPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}
