part of 'remote_files_tab.dart';

// Building blocks of the remote file browser: places, path bar, action bar,
// rows and state messages.

IconData _rootIcon(FsRoot r) {
  switch (r.kind) {
    case 'home':
      return Icons.home_rounded;
    case 'desktop':
      return Icons.desktop_windows_rounded;
    case 'documents':
      return Icons.description_rounded;
    case 'downloads':
      return Icons.download_rounded;
    case 'drive':
      return Icons.storage_rounded;
    case 'storage':
      return Icons.phone_android_rounded;
    default:
      return Icons.folder_rounded;
  }
}

/// The root that contains [path]; the deepest one wins, so Home does not
/// light up while browsing Downloads.
FsRoot? _activeRoot(List<FsRoot> roots, String? path) {
  if (path == null) return null;
  final trail = {for (final c in RemotePath.crumbs(path)) c.path};
  FsRoot? best;
  for (final r in roots) {
    if (trail.contains(r.path) && (best == null || r.path.length > best.path.length)) best = r;
  }
  return best;
}

class _RootsBar extends StatelessWidget {
  const _RootsBar({required this.roots, required this.current, required this.onPick});

  final List<FsRoot> roots;
  final String? current;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final s = FilesStrings.of(context);
    final active = _activeRoot(roots, current);
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: roots.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final r = roots[i];
          return ChoiceChip(
            avatar: Icon(_rootIcon(r), size: 18),
            label: Text(s.rootLabel(r.name, r.kind)),
            selected: identical(active, r),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => onPick(r.path),
          );
        },
      ),
    );
  }
}

/// Breadcrumbs relative to the place being browsed: `Home › Projects` rather
/// than the full `/Users/bob/Projects`.
List<RemoteCrumb> _displayCrumbs(String path, FsRoot? root, FilesStrings s) {
  final all = RemotePath.crumbs(path);
  if (root == null) return all;
  final i = all.indexWhere((c) => c.path == root.path);
  if (i < 0) return all;
  return [RemoteCrumb(s.rootLabel(root.name, root.kind), root.path), ...all.sublist(i + 1)];
}

class _PathBar extends StatefulWidget {
  const _PathBar({
    required this.path,
    required this.roots,
    required this.loading,
    required this.showHidden,
    required this.onNavigate,
    required this.onRefresh,
    required this.onToggleHidden,
  });

  final String? path;
  final List<FsRoot> roots;
  final bool loading;
  final bool showHidden;
  final ValueChanged<String> onNavigate;
  final VoidCallback onRefresh;
  final VoidCallback onToggleHidden;

  @override
  State<_PathBar> createState() => _PathBarState();
}

class _PathBarState extends State<_PathBar> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(_PathBar old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = FilesStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    final path = widget.path;
    final parent = path == null ? null : RemotePath.parent(path);
    final crumbs = path == null ? const <RemoteCrumb>[] : _displayCrumbs(path, _activeRoot(widget.roots, path), s);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: s.up,
              visualDensity: VisualDensity.compact,
              onPressed: parent == null ? null : () => widget.onNavigate(parent),
              icon: const Icon(Icons.arrow_upward_rounded, size: 20),
            ),
            Expanded(
              child: ListView.separated(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                itemCount: crumbs.length,
                separatorBuilder: (_, _) => Icon(Icons.chevron_right_rounded, size: 18, color: scheme.onSurfaceVariant),
                itemBuilder: (context, i) {
                  final c = crumbs[i];
                  final last = i == crumbs.length - 1;
                  return Center(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: last ? null : () => widget.onNavigate(c.path),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        child: Text(
                          c.label,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                fontWeight: last ? FontWeight.w700 : FontWeight.w500,
                                color: last ? scheme.onSurface : scheme.onSurfaceVariant,
                              ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (widget.loading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              IconButton(
                tooltip: s.refresh,
                visualDensity: VisualDensity.compact,
                onPressed: widget.onRefresh,
                icon: const Icon(Icons.refresh_rounded, size: 20),
              ),
            IconButton(
              tooltip: widget.showHidden ? s.hideHidden : s.showHidden,
              visualDensity: VisualDensity.compact,
              onPressed: widget.onToggleHidden,
              isSelected: widget.showHidden,
              icon: const Icon(Icons.visibility_off_outlined, size: 20),
              selectedIcon: const Icon(Icons.visibility_rounded, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionsBar extends StatelessWidget {
  const _ActionsBar({
    required this.selectedCount,
    required this.canUpload,
    required this.onDownload,
    required this.onClear,
    required this.onUpload,
  });

  final int selectedCount;
  final bool canUpload;
  final VoidCallback onDownload;
  final VoidCallback onClear;
  final ValueChanged<PickKind> onUpload;

  @override
  Widget build(BuildContext context) {
    final s = FilesStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      // Wrap, not Row: long Russian labels on a narrow panel flow onto a
      // second line instead of overflowing.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 6,
        spacing: 8,
        children: [
          MenuAnchor(
            menuChildren: [
              MenuItemButton(
                leadingIcon: const Icon(Icons.upload_file_rounded),
                onPressed: () => onUpload(PickKind.files),
                child: Text(s.uploadFiles),
              ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.drive_folder_upload_rounded),
                onPressed: () => onUpload(PickKind.folder),
                child: Text(s.uploadFolder),
              ),
            ],
            builder: (context, controller, _) => OutlinedButton.icon(
              onPressed: canUpload ? () => controller.isOpen ? controller.close() : controller.open() : null,
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 14)),
              icon: const Icon(Icons.upload_rounded, size: 18),
              label: Text(s.uploadHere),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerRight,
            child: selectedCount == 0
                ? const SizedBox(height: 38)
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: s.clearSelection,
                        visualDensity: VisualDensity.compact,
                        onPressed: onClear,
                        icon: Icon(Icons.deselect_rounded, size: 20, color: scheme.onSurfaceVariant),
                      ),
                      FilledButton.icon(
                        onPressed: onDownload,
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 14)),
                        icon: const Icon(Icons.download_rounded, size: 18),
                        label: Text(s.download(selectedCount)),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({super.key, required this.entry, required this.selected, required this.onToggle, this.onOpen});

  final RemoteEntry entry;
  final bool selected;
  final VoidCallback onToggle;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final s = FilesStrings.of(context);
    final scheme = Theme.of(context).colorScheme;
    final e = entry;
    final modified = e.modified;
    final subtitle = [
      if (!e.isDir) formatBytes(e.size, s),
      if (modified != null) formatModified(modified, s),
    ].join('  ·  ');

    // Touch devices open folders on tap; with a mouse a click selects and a
    // double-click opens, like a file manager.
    final tapOpens = _touchFirst && e.isDir;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? scheme.primaryContainer.withValues(alpha: 0.5) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: tapOpens ? onOpen : onToggle,
          onDoubleTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Opacity(
                  opacity: e.hidden ? 0.55 : 1,
                  child: FileIconTile(name: e.name, isDir: e.isDir, size: 36),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: e.isDir ? FontWeight.w600 : FontWeight.w500,
                              color: e.hidden ? scheme.onSurfaceVariant : scheme.onSurface,
                            ),
                      ),
                      if (subtitle.isNotEmpty) Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11)),
                    ],
                  ),
                ),
                if (e.isDir)
                  IconButton(
                    tooltip: s.openFolder,
                    visualDensity: VisualDensity.compact,
                    onPressed: onOpen,
                    icon: Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
                  ),
                Checkbox(
                  value: selected,
                  visualDensity: VisualDensity.compact,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  onChanged: (_) => onToggle(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading({super.key});

  @override
  Widget build(BuildContext context) {
    final s = FilesStrings.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 14),
          Text(s.loadingFolder, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _StateMessage extends StatelessWidget {
  const _StateMessage({super.key, required this.icon, required this.title, this.action});

  final IconData icon;
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(22)),
              child: Icon(icon, size: 32, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
