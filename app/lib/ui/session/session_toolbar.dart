import 'package:flutter/material.dart';

import '../../files/files.dart';
import '../../l10n/strings.dart';
import '../../protocol/models.dart';
import '../../session/touch_gestures.dart';
import '../../session/viewer_session.dart';
import 'connection_indicator.dart';
import 'special_keys.dart';
import 'view_controller.dart';

/// Floating pill with the session controls (display, quality, keys, clipboard,
/// view-only, fit / 1:1 / fullscreen, stats, End).
class SessionToolbar extends StatelessWidget {
  const SessionToolbar({
    super.key,
    required this.session,
    required this.view,
    required this.isDesktop,
    required this.fullScreen,
    required this.showStats,
    required this.touchMode,
    required this.keyboardOpen,
    required this.onToggleStats,
    required this.onToggleFullScreen,
    required this.onToggleKeyboard,
    required this.filesOpen,
    required this.onToggleFiles,
    required this.onTouchMode,
    required this.onActualSize,
    required this.onEnd,
    this.onBack,
    this.onMenuOpened,
  });

  final ViewerSession session;
  final ViewController view;
  final bool isDesktop;
  final bool fullScreen;
  final bool showStats;
  final TouchMode touchMode;
  final bool keyboardOpen;
  final VoidCallback onToggleStats;
  final VoidCallback onToggleFullScreen;
  final VoidCallback onToggleKeyboard;
  final bool filesOpen;
  final VoidCallback onToggleFiles;
  final ValueChanged<TouchMode> onTouchMode;
  final VoidCallback onActualSize;
  final VoidCallback onEnd;

  /// Android: leave the session view without ending it.
  final VoidCallback? onBack;
  final VoidCallback? onMenuOpened;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Phones cannot fit every control in one row: the rest moves into a menu
    // so End and the keyboard button are always on screen.
    if (MediaQuery.sizeOf(context).width < 620) return _buildCompact(context, scheme);
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.94),
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(28),
      child: ListenableBuilder(
        listenable: Listenable.merge([session, view]),
        builder: (context, _) {
          final l = context.s;
          final perms = session.permissions;
          final canControl = perms?.control ?? false;
          final canClipboard = perms?.clipboard ?? false;
          final canFiles = perms?.files ?? false;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onBack != null)
                  IconButton(
                    tooltip: l.t('toolbar.back'),
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: onBack,
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: ConnectionIndicator(session: session),
                ),
                const _Divider(),
                if (session.displays.length > 1) _displayMenu(context),
                _qualityMenu(context),
                _keysMenu(context),
                if (!isDesktop)
                  IconButton(
                    tooltip: keyboardOpen ? l.t('toolbar.keyboard.hide') : l.t('toolbar.keyboard'),
                    isSelected: keyboardOpen,
                    icon: const Icon(Icons.keyboard_outlined),
                    selectedIcon: const Icon(Icons.keyboard_hide_outlined),
                    onPressed: onToggleKeyboard,
                  ),
                if (!isDesktop && canControl) _touchModeMenu(context),
                if (canClipboard)
                  IconButton(
                    tooltip: session.clipboardSyncOn ? l.t('toolbar.clipboard.on') : l.t('toolbar.clipboard.off'),
                    isSelected: session.clipboardSyncOn,
                    icon: const Icon(Icons.content_paste_off_outlined),
                    selectedIcon: const Icon(Icons.content_paste_go_rounded),
                    onPressed: () => session.setClipboardSync(!session.clipboardSyncOn),
                  ),
                if (canFiles)
                  IconButton(
                    tooltip: l.t('toolbar.files'),
                    isSelected: filesOpen,
                    icon: const Icon(Icons.folder_open_outlined),
                    selectedIcon: const Icon(Icons.folder_open_rounded),
                    onPressed: onToggleFiles,
                  ),
                if (canFiles && session.files != null)
                  SendFilesMenuButton(endpoint: session.files!, compact: true),
                if (canControl)
                  IconButton(
                    tooltip: session.userViewOnly ? l.t('toolbar.viewOnly.on') : l.t('toolbar.viewOnly.off'),
                    isSelected: session.userViewOnly,
                    icon: const Icon(Icons.mouse_outlined),
                    selectedIcon: const Icon(Icons.visibility_outlined),
                    onPressed: () => session.setViewOnly(!session.userViewOnly),
                  ),
                _fitMenu(context),
                if (isDesktop)
                  IconButton(
                    tooltip: fullScreen ? l.t('toolbar.fullscreen.exit') : l.t('toolbar.fullscreen'),
                    icon: Icon(fullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
                    onPressed: onToggleFullScreen,
                  ),
                IconButton(
                  tooltip: l.t('toolbar.stats'),
                  isSelected: showStats,
                  icon: const Icon(Icons.query_stats_rounded),
                  selectedIcon: const Icon(Icons.query_stats_rounded),
                  onPressed: onToggleStats,
                ),
                const _Divider(),
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                      minimumSize: const Size(0, 40),
                    ),
                    onPressed: onEnd,
                    icon: const Icon(Icons.call_end_rounded, size: 18),
                    label: Text(l.t('toolbar.end')),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCompact(BuildContext context, ColorScheme scheme) {
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.94),
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(28),
      child: ListenableBuilder(
        listenable: Listenable.merge([session, view]),
        builder: (context, _) {
          final l = context.s;
          final perms = session.permissions;
          final canControl = perms?.control ?? false;
          final canClipboard = perms?.clipboard ?? false;
          final canFiles = perms?.files ?? false;
          final keys = specialKeysFor(session.peer.os);

          PopupMenuEntry<VoidCallback> header(String text) => PopupMenuItem<VoidCallback>(
                enabled: false,
                height: 32,
                child: Text(
                  text.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        letterSpacing: 1,
                      ),
                ),
              );

          PopupMenuEntry<VoidCallback> item(String text, VoidCallback run,
                  {IconData? icon, bool checked = false}) =>
              PopupMenuItem<VoidCallback>(
                value: run,
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      child: checked
                          ? Icon(Icons.check_rounded, size: 18, color: scheme.primary)
                          : (icon == null ? null : Icon(icon, size: 18)),
                    ),
                    const SizedBox(width: 12),
                    Flexible(child: Text(text)),
                  ],
                ),
              );

          final qualityLabels = {
            QualityPreset.auto: l.t('quality.auto'),
            QualityPreset.speed: l.t('quality.speed'),
            QualityPreset.balanced: l.t('quality.balanced'),
            QualityPreset.quality: l.t('quality.quality'),
          };

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              children: [
                if (onBack != null)
                  IconButton(
                    tooltip: l.t('toolbar.back'),
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: onBack,
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: ConnectionIndicator(session: session),
                    ),
                  ),
                ),
                if (!isDesktop)
                  IconButton(
                    tooltip: keyboardOpen ? l.t('toolbar.keyboard.hide') : l.t('toolbar.keyboard'),
                    isSelected: keyboardOpen,
                    icon: const Icon(Icons.keyboard_outlined),
                    selectedIcon: const Icon(Icons.keyboard_hide_outlined),
                    onPressed: onToggleKeyboard,
                  ),
                if (canFiles)
                  IconButton(
                    tooltip: l.t('toolbar.files'),
                    isSelected: filesOpen,
                    icon: const Icon(Icons.folder_open_outlined),
                    selectedIcon: const Icon(Icons.folder_open_rounded),
                    onPressed: onToggleFiles,
                  ),
                PopupMenuButton<VoidCallback>(
                  tooltip: l.t('common.more'),
                  icon: const Icon(Icons.more_vert_rounded),
                  onOpened: onMenuOpened,
                  onSelected: (run) => run(),
                  itemBuilder: (_) => [
                    if (session.displays.length > 1) ...[
                      header(l.t('toolbar.display')),
                      for (final d in session.displays)
                        item(
                          '${d.name}  ${d.width}×${d.height}',
                          () => session.selectDisplay(d.id),
                          checked: d.id == session.activeDisplayId,
                        ),
                    ],
                    header(l.t('toolbar.quality')),
                    for (final e in qualityLabels.entries)
                      item(e.value, () => session.setQuality(e.key), checked: e.key == session.quality),
                    if (!session.viewOnly) ...[
                      header(l.t('toolbar.keys')),
                      for (final k in keys) item(k.label, () => k.run(session.encoder), icon: k.icon),
                    ],
                    if (!isDesktop && canControl) ...[
                      header(l.t('toolbar.touchMode')),
                      item(l.t('toolbar.touchpad'), () => onTouchMode(TouchMode.touchpad),
                          checked: touchMode == TouchMode.touchpad),
                      item(l.t('toolbar.direct'), () => onTouchMode(TouchMode.direct),
                          checked: touchMode == TouchMode.direct),
                    ],
                    const PopupMenuDivider(),
                    if (canFiles && session.files != null) ...[
                      item(
                        FilesStrings.of(context).sendFiles,
                        () => pickAndSendFiles(context, session.files!),
                        icon: Icons.upload_file_rounded,
                      ),
                      item(
                        FilesStrings.of(context).sendFolder,
                        () => pickAndSendFiles(context, session.files!, kind: PickKind.folder),
                        icon: Icons.drive_folder_upload_rounded,
                      ),
                    ],
                    if (canClipboard)
                      item(
                        session.clipboardSyncOn ? l.t('toolbar.clipboard.on') : l.t('toolbar.clipboard.off'),
                        () => session.setClipboardSync(!session.clipboardSyncOn),
                        icon: Icons.content_paste_go_rounded,
                        checked: session.clipboardSyncOn,
                      ),
                    if (canControl)
                      item(
                        session.userViewOnly ? l.t('toolbar.viewOnly.on') : l.t('toolbar.viewOnly.off'),
                        () => session.setViewOnly(!session.userViewOnly),
                        icon: session.userViewOnly ? Icons.visibility_outlined : Icons.mouse_outlined,
                      ),
                    item(l.t('toolbar.fit'), view.reset,
                        icon: Icons.fit_screen_rounded,
                        checked: view.mode == FitMode.fit && view.explicit.isIdentity),
                    item(l.t('toolbar.actual'), onActualSize,
                        icon: Icons.zoom_in_map_rounded, checked: view.mode == FitMode.actual),
                    item(l.t('toolbar.stats'), onToggleStats, icon: Icons.query_stats_rounded, checked: showStats),
                  ],
                ),
                IconButton.filled(
                  tooltip: l.t('toolbar.end'),
                  style: IconButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                  ),
                  icon: const Icon(Icons.call_end_rounded),
                  onPressed: onEnd,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _displayMenu(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: context.s.t('toolbar.display'),
      icon: const Icon(Icons.desktop_windows_outlined),
      onOpened: onMenuOpened,
      onSelected: session.selectDisplay,
      itemBuilder: (_) => [
        for (final d in session.displays)
          CheckedPopupMenuItem<String>(
            value: d.id,
            checked: d.id == session.activeDisplayId,
            child: Text('${d.name}  ${d.width}×${d.height}${d.primary ? '  ${context.s.t('toolbar.display.main')}' : ''}'),
          ),
      ],
    );
  }

  Widget _qualityMenu(BuildContext context) {
    final l = context.s;
    final labels = {
      QualityPreset.auto: l.t('quality.auto'),
      QualityPreset.speed: l.t('quality.speed'),
      QualityPreset.balanced: l.t('quality.balanced'),
      QualityPreset.quality: l.t('quality.quality'),
    };
    return PopupMenuButton<QualityPreset>(
      tooltip: l.t('toolbar.quality'),
      icon: const Icon(Icons.speed_rounded),
      onOpened: onMenuOpened,
      onSelected: session.setQuality,
      itemBuilder: (_) => [
        for (final e in labels.entries)
          CheckedPopupMenuItem<QualityPreset>(
            value: e.key,
            checked: e.key == session.quality,
            child: Text(e.value),
          ),
      ],
    );
  }

  Widget _keysMenu(BuildContext context) {
    final keys = specialKeysFor(session.peer.os);
    return PopupMenuButton<SpecialKey>(
      tooltip: context.s.t('toolbar.keys'),
      enabled: !session.viewOnly,
      icon: const Icon(Icons.keyboard_command_key_rounded),
      onOpened: onMenuOpened,
      onSelected: (k) => k.run(session.encoder),
      itemBuilder: (_) => [
        for (final k in keys)
          PopupMenuItem<SpecialKey>(
            value: k,
            child: Row(children: [Icon(k.icon, size: 18), const SizedBox(width: 12), Text(k.label)]),
          ),
      ],
    );
  }

  Widget _touchModeMenu(BuildContext context) {
    final l = context.s;
    return PopupMenuButton<TouchMode>(
      tooltip: l.t('toolbar.touchMode'),
      icon: Icon(touchMode == TouchMode.touchpad ? Icons.touch_app_outlined : Icons.pan_tool_alt_outlined),
      onOpened: onMenuOpened,
      onSelected: onTouchMode,
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: TouchMode.touchpad,
          checked: touchMode == TouchMode.touchpad,
          child: Text(l.t('toolbar.touchpad')),
        ),
        CheckedPopupMenuItem(
          value: TouchMode.direct,
          checked: touchMode == TouchMode.direct,
          child: Text(l.t('toolbar.direct')),
        ),
      ],
    );
  }

  Widget _fitMenu(BuildContext context) {
    final l = context.s;
    return PopupMenuButton<FitMode>(
      tooltip: l.t('toolbar.zoom'),
      icon: const Icon(Icons.zoom_in_map_rounded),
      onOpened: onMenuOpened,
      onSelected: (m) => m == FitMode.fit ? view.reset() : onActualSize(),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: FitMode.fit,
          checked: view.mode == FitMode.fit && view.explicit.isIdentity,
          child: Text(l.t('toolbar.fit')),
        ),
        CheckedPopupMenuItem(
          value: FitMode.actual,
          checked: view.mode == FitMode.actual,
          child: Text(l.t('toolbar.actual')),
        ),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        color: Theme.of(context).colorScheme.outlineVariant,
      );
}

/// Used by the session view when the pill is hidden: tap to bring it back.
class ToolbarGrabber extends StatelessWidget {
  const ToolbarGrabber({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
        ),
        child: const Icon(Icons.expand_more_rounded, size: 20, color: Colors.white70),
      ),
    );
  }
}

/// Small helper used by [SessionToolbar] consumers for OS-specific labels.
String winKeyLabel(String remoteOs) => remoteOs == 'macos' ? 'Cmd' : (remoteOs == 'linux' ? 'Super' : 'Win');
