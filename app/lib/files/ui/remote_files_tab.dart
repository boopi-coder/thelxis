import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../file_transfer_endpoint.dart';
import '../remote_path.dart';
import 'file_icons.dart';
import 'files_format.dart';
import 'files_strings.dart';
import 'pick_and_send.dart';

part 'remote_files_parts.dart';

bool get _touchFirst => defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

/// Browser for the other device's files (viewer only): places, breadcrumb,
/// multi-select download, and upload into the folder being shown.
class RemoteFilesTab extends StatefulWidget {
  const RemoteFilesTab({super.key, required this.endpoint, this.onQueued});

  final FileTransferEndpoint endpoint;

  /// Called after downloads / uploads were queued, so the panel can switch to
  /// the Transfers tab.
  final VoidCallback? onQueued;

  @override
  State<RemoteFilesTab> createState() => _RemoteFilesTabState();
}

class _RemoteFilesTabState extends State<RemoteFilesTab> with AutomaticKeepAliveClientMixin {
  List<FsRoot> _roots = const [];
  String? _path;
  List<RemoteEntry> _entries = const [];
  RemoteFsErrorKind? _error;
  String? _failedPath;
  bool _loading = true;
  bool _showHidden = false;
  final Set<String> _selected = {};
  int _token = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final token = ++_token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final roots = await widget.endpoint.remote.roots();
      if (!mounted || token != _token) return;
      _roots = roots;
      if (roots.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      final home = roots.firstWhere((r) => r.kind == 'home', orElse: () => roots.first);
      await _open(home.path);
    } on RemoteFsException catch (e) {
      if (!mounted || token != _token) return;
      setState(() {
        _loading = false;
        _error = e.kind;
        _failedPath = null;
      });
    }
  }

  Future<void> _open(String path) async {
    final token = ++_token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.endpoint.remote.list(path);
      if (!mounted || token != _token) return;
      setState(() {
        _path = path;
        _entries = entries;
        _selected.clear();
        _loading = false;
      });
    } on RemoteFsException catch (e) {
      if (!mounted || token != _token) return;
      setState(() {
        _path = path;
        _entries = const [];
        _selected.clear();
        _loading = false;
        _error = e.kind;
        _failedPath = path;
      });
    }
  }

  List<RemoteEntry> get _visible =>
      _showHidden ? _entries : [for (final e in _entries) if (!e.hidden) e];

  void _toggle(RemoteEntry e) {
    setState(() {
      if (!_selected.add(e.name)) _selected.remove(e.name);
    });
  }

  Future<void> _downloadSelected() async {
    final path = _path;
    if (path == null || _selected.isEmpty) return;
    final s = FilesStrings.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final chosen = [for (final e in _entries) if (_selected.contains(e.name)) e];
    setState(() => _selected.clear());
    final before = widget.endpoint.transfers.length;
    try {
      for (final e in chosen) {
        await widget.endpoint.download(RemotePath.join(path, e.name), isDirectory: e.isDir);
      }
    } on RemoteFsException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(s.remoteError(e.kind))));
    } on FileTransferException {
      messenger?.showSnackBar(SnackBar(content: Text(s.connectionClosed)));
    }
    final queued = widget.endpoint.transfers.length - before;
    if (queued > 0) {
      messenger?.showSnackBar(SnackBar(content: Text(s.queuedDownloads(queued))));
      widget.onQueued?.call();
    }
  }

  Future<void> _upload(PickKind kind) async {
    final path = _path;
    if (path == null) return;
    final n = await pickAndSendFiles(context, widget.endpoint, kind: kind, remoteDir: path);
    if (n > 0) widget.onQueued?.call();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = FilesStrings.of(context);
    final visible = _visible;

    Widget body;
    if (_loading && _entries.isEmpty) {
      body = const _Loading(key: ValueKey('loading'));
    } else if (_error != null) {
      body = _StateMessage(
        key: const ValueKey('error'),
        icon: _error == RemoteFsErrorKind.denied ? Icons.lock_rounded : Icons.error_outline_rounded,
        title: s.remoteError(_error!),
        action: _error == RemoteFsErrorKind.denied
            ? null
            : FilledButton.tonal(
                onPressed: () => _failedPath == null ? _start() : _open(_failedPath!),
                child: Text(s.tryAgain),
              ),
      );
    } else if (_path == null) {
      body = _StateMessage(key: const ValueKey('noroots'), icon: Icons.folder_off_rounded, title: s.emptyFolder);
    } else if (visible.isEmpty) {
      body = _StateMessage(
        key: ValueKey('empty$_path$_showHidden'),
        icon: Icons.folder_open_rounded,
        title: _entries.isEmpty ? s.emptyFolder : s.emptyFolderHidden,
      );
    } else {
      body = ListView.builder(
        key: ValueKey('list$_path$_showHidden'),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        itemExtent: 60,
        itemCount: visible.length,
        itemBuilder: (context, i) {
          final e = visible[i];
          return _EntryRow(
            key: ValueKey(e.name),
            entry: e,
            selected: _selected.contains(e.name),
            onToggle: () => _toggle(e),
            onOpen: e.isDir ? () => _open(RemotePath.join(_path!, e.name)) : null,
          );
        },
      );
    }

    return Column(
      children: [
        if (_roots.isNotEmpty) _RootsBar(roots: _roots, current: _path, onPick: _open),
        _PathBar(
          path: _path,
          roots: _roots,
          loading: _loading,
          showHidden: _showHidden,
          onNavigate: _open,
          onRefresh: _path == null ? _start : () => _open(_path!),
          onToggleHidden: () => setState(() => _showHidden = !_showHidden),
        ),
        _ActionsBar(
          selectedCount: _selected.length,
          canUpload: _path != null && _error == null,
          onDownload: _downloadSelected,
          onClear: () => setState(_selected.clear),
          onUpload: _upload,
        ),
        Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4)),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: body,
          ),
        ),
      ],
    );
  }
}
