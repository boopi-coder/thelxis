import 'package:flutter/material.dart';

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
  final ValueChanged<TouchMode> onTouchMode;
  final VoidCallback onActualSize;
  final VoidCallback onEnd;

  /// Android: leave the session view without ending it.
  final VoidCallback? onBack;
  final VoidCallback? onMenuOpened;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.94),
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(28),
      child: ListenableBuilder(
        listenable: Listenable.merge([session, view]),
        builder: (context, _) {
          final perms = session.permissions;
          final canControl = perms?.control ?? false;
          final canClipboard = perms?.clipboard ?? false;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onBack != null)
                  IconButton(
                    tooltip: 'Back to Thelxis',
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
                    tooltip: keyboardOpen ? 'Hide keyboard' : 'Keyboard',
                    isSelected: keyboardOpen,
                    icon: const Icon(Icons.keyboard_outlined),
                    selectedIcon: const Icon(Icons.keyboard_hide_outlined),
                    onPressed: onToggleKeyboard,
                  ),
                if (!isDesktop && canControl) _touchModeMenu(context),
                if (canClipboard)
                  IconButton(
                    tooltip: session.clipboardSyncOn ? 'Clipboard sync on' : 'Clipboard sync off',
                    isSelected: session.clipboardSyncOn,
                    icon: const Icon(Icons.content_paste_off_outlined),
                    selectedIcon: const Icon(Icons.content_paste_go_rounded),
                    onPressed: () => session.setClipboardSync(!session.clipboardSyncOn),
                  ),
                if (canControl)
                  IconButton(
                    tooltip: session.userViewOnly ? 'View only (tap to control)' : 'Controlling (tap for view only)',
                    isSelected: session.userViewOnly,
                    icon: const Icon(Icons.mouse_outlined),
                    selectedIcon: const Icon(Icons.visibility_outlined),
                    onPressed: () => session.setViewOnly(!session.userViewOnly),
                  ),
                _fitMenu(context),
                if (isDesktop)
                  IconButton(
                    tooltip: fullScreen ? 'Exit full screen' : 'Full screen',
                    icon: Icon(fullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
                    onPressed: onToggleFullScreen,
                  ),
                IconButton(
                  tooltip: 'Statistics',
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
                    label: const Text('End'),
                  ),
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
      tooltip: 'Display',
      icon: const Icon(Icons.desktop_windows_outlined),
      onOpened: onMenuOpened,
      onSelected: session.selectDisplay,
      itemBuilder: (_) => [
        for (final d in session.displays)
          CheckedPopupMenuItem<String>(
            value: d.id,
            checked: d.id == session.activeDisplayId,
            child: Text('${d.name}  ${d.width}×${d.height}${d.primary ? '  (main)' : ''}'),
          ),
      ],
    );
  }

  Widget _qualityMenu(BuildContext context) {
    const labels = {
      QualityPreset.auto: 'Auto',
      QualityPreset.speed: 'Speed (30 fps, low bandwidth)',
      QualityPreset.balanced: 'Balanced',
      QualityPreset.quality: 'Quality (60 fps)',
    };
    return PopupMenuButton<QualityPreset>(
      tooltip: 'Quality',
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
      tooltip: 'Special keys',
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
    return PopupMenuButton<TouchMode>(
      tooltip: 'Touch mode',
      icon: Icon(touchMode == TouchMode.touchpad ? Icons.touch_app_outlined : Icons.pan_tool_alt_outlined),
      onOpened: onMenuOpened,
      onSelected: onTouchMode,
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: TouchMode.touchpad,
          checked: touchMode == TouchMode.touchpad,
          child: const Text('Touchpad (relative cursor)'),
        ),
        CheckedPopupMenuItem(
          value: TouchMode.direct,
          checked: touchMode == TouchMode.direct,
          child: const Text('Direct touch'),
        ),
      ],
    );
  }

  Widget _fitMenu(BuildContext context) {
    return PopupMenuButton<FitMode>(
      tooltip: 'Zoom',
      icon: const Icon(Icons.zoom_in_map_rounded),
      onOpened: onMenuOpened,
      onSelected: (m) => m == FitMode.fit ? view.reset() : onActualSize(),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: FitMode.fit,
          checked: view.mode == FitMode.fit && view.explicit.isIdentity,
          child: const Text('Fit to window'),
        ),
        CheckedPopupMenuItem(
          value: FitMode.actual,
          checked: view.mode == FitMode.actual,
          child: const Text('Actual size (1:1)'),
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
