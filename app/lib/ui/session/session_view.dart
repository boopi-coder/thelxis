import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../desktop/desktop_integration.dart';
import '../../l10n/strings.dart';
import '../../session/session_base.dart';
import '../../session/session_manager.dart';
import '../../session/touch_gestures.dart';
import '../../session/viewer_session.dart';
import '../shell_controller.dart';
import 'connection_indicator.dart';
import 'extra_keys_bar.dart';
import 'files_slot.dart';
import 'remote_surface.dart';
import 'session_overlays.dart';
import 'session_toolbar.dart';
import 'soft_keyboard.dart';
import 'view_controller.dart';

bool get _isDesktop {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    default:
      return false;
  }
}

/// Full-window view of one outgoing session: remote picture, input capture,
/// floating auto-hiding toolbar, connection state and stats overlays.
class SessionView extends StatefulWidget {
  const SessionView({super.key, required this.session});

  final ViewerSession session;

  @override
  State<SessionView> createState() => _SessionViewState();
}

class _SessionViewState extends State<SessionView> {
  late final ViewController _view = ViewController(followPointer: _isDesktop);
  Timer? _hideTimer;
  bool _toolbarVisible = true;
  bool _showStats = false;
  bool _keyboardOpen = false;
  bool _filesOpen = false;
  late TouchMode _touchMode;
  Size _viewport = Size.zero;
  Size _video = Size.zero;

  @override
  void initState() {
    super.initState();
    _touchMode = context.read<AppSettings>().touchMode == 'direct'
        ? TouchMode.direct
        : TouchMode.touchpad;
    _scheduleHide(const Duration(seconds: 5));
    // Phones: the remote screen gets the whole display.
    if (!_isDesktop) SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    if (!_isDesktop) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _hideTimer?.cancel();
    _view.dispose();
    super.dispose();
  }

  void _showToolbar([Duration hideAfter = const Duration(seconds: 4)]) {
    if (!_toolbarVisible) setState(() => _toolbarVisible = true);
    _scheduleHide(hideAfter);
  }

  void _scheduleHide(Duration after) {
    _hideTimer?.cancel();
    _hideTimer = Timer(after, () {
      if (mounted && !_keyboardOpen) setState(() => _toolbarVisible = false);
    });
  }

  void _onMetrics(Size viewport, Size video) {
    _viewport = viewport;
    _video = video;
  }

  void _onPointerActivity(Offset p) {
    // Desktop: moving into the top strip reveals the toolbar.
    if (p.dy < 72) _showToolbar();
  }

  Future<void> _end() async {
    final shell = context.read<ShellController>();
    final manager = context.read<SessionManager>();
    final session = widget.session;
    await session.end('user');
    shell.sessionClosed(session);
    WidgetsBinding.instance.addPostFrameCallback((_) => manager.dismiss(session));
  }

  void _close() {
    final shell = context.read<ShellController>();
    final manager = context.read<SessionManager>();
    final session = widget.session;
    shell.sessionClosed(session);
    WidgetsBinding.instance.addPostFrameCallback((_) => manager.dismiss(session));
  }

  Future<void> _toggleFullScreen(DesktopIntegration desktop) async {
    await desktop.setFullScreen(!desktop.fullScreen.value);
    if (mounted) setState(() {});
  }

  void _toggleFiles() {
    if (_isDesktop) {
      setState(() => _filesOpen = !_filesOpen);
    } else {
      showSessionFilesSheet(context, widget.session);
    }
  }

  void _setTouchMode(TouchMode mode) {
    setState(() => _touchMode = mode);
    unawaited(context.read<AppSettings>().setTouchMode(mode.name));
  }

  void _actualSize() {
    if (_isDesktop) {
      _view.setMode(FitMode.actual);
    } else {
      _view.setActualSize(_viewport, _video, MediaQuery.devicePixelRatioOf(context));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final desktop = context.read<DesktopIntegration>();
    final shell = context.read<ShellController>();
    final isDesktop = _isDesktop;

    return ColoredBox(
      color: Colors.black,
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final ended = session.isEnded;
          final showSurface = !ended &&
              (session.phase == SessionPhase.active || session.phase == SessionPhase.reconnecting);
          return Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (showSurface)
                      SessionFilesSlot.dropWrapper(
                        context,
                        session,
                        RemoteSurface(
                          session: session,
                          view: _view,
                          isDesktop: isDesktop,
                          touchMode: _touchMode,
                          onMetrics: _onMetrics,
                          onPointerActivity: _onPointerActivity,
                        ),
                      ),
                    if (!ended && session.authPrompt == null && !_hasPicture(session))
                      BusyOverlay(
                        title: phaseTitle(session),
                        subtitle: session.notice,
                        dim: 0.0,
                      ),
                    if (session.phase == SessionPhase.reconnecting && !ended)
                      BusyOverlay(
                        title: context.s.t('session.reconnecting'),
                        subtitle: context.s.t('session.reconnecting.hint'),
                      ),
                    if (session.authPrompt != null && !ended) PasswordPrompt(session: session),
                    if (ended) EndedOverlay(session: session, onClose: _close),
                    if (_showStats && !ended)
                      Positioned(
                        left: 12,
                        top: 64,
                        child: StatsOverlay(stats: session.stats),
                      ),
                    if (_filesOpen && isDesktop && !ended)
                      Positioned(
                        top: 0,
                        right: 0,
                        bottom: 0,
                        child: SessionFilesPanelHost(
                          session: session,
                          onClose: () => setState(() => _filesOpen = false),
                        ),
                      ),
                    if (!ended) _toolbarLayer(context, session, desktop, shell, isDesktop),
                    if (_keyboardOpen && !isDesktop && !ended)
                      Positioned(
                        left: 0,
                        bottom: 0,
                        child: SoftKeyboardField(
                          encoder: session.encoder,
                          onClosed: () {
                            if (mounted) setState(() => _keyboardOpen = false);
                          },
                        ),
                      ),
                  ],
                ),
              ),
              if (_keyboardOpen && !isDesktop && !ended)
                ExtraKeysBar(
                  encoder: session.encoder,
                  winLabel: winKeyLabel(session.peer.os),
                ),
            ],
          );
        },
      ),
    );
  }

  bool _hasPicture(ViewerSession s) =>
      s.hasFirstFrame && (s.phase == SessionPhase.active || s.phase == SessionPhase.reconnecting);

  Widget _toolbarLayer(
    BuildContext context,
    ViewerSession session,
    DesktopIntegration desktop,
    ShellController shell,
    bool isDesktop,
  ) {
    final width = MediaQuery.sizeOf(context).width;
    return Positioned(
      top: 8,
      left: 0,
      // Centre the pill over the picture, not over the side panel.
      right: _filesOpen && isDesktop ? 380.0 : 0.0,
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _toolbarVisible
                ? ConstrainedBox(
                    key: const ValueKey('toolbar'),
                    constraints: BoxConstraints(maxWidth: width - 16),
                    child: Listener(
                      onPointerDown: (_) => _showToolbar(const Duration(seconds: 6)),
                      child: SessionToolbar(
                        session: session,
                        view: _view,
                        isDesktop: isDesktop,
                        fullScreen: desktop.fullScreen.value,
                        showStats: _showStats,
                        touchMode: _touchMode,
                        keyboardOpen: _keyboardOpen,
                        onToggleStats: () => setState(() => _showStats = !_showStats),
                        onToggleFullScreen: () => _toggleFullScreen(desktop),
                        onToggleKeyboard: () => setState(() => _keyboardOpen = !_keyboardOpen),
                        filesOpen: _filesOpen,
                        onToggleFiles: _toggleFiles,
                        onTouchMode: _setTouchMode,
                        onActualSize: _actualSize,
                        onEnd: _end,
                        onBack: isDesktop ? null : shell.showPages,
                        onMenuOpened: () => _showToolbar(const Duration(seconds: 12)),
                      ),
                    ),
                  )
                : ToolbarGrabber(
                    key: const ValueKey('grabber'),
                    onTap: () => _showToolbar(const Duration(seconds: 6)),
                  ),
          ),
        ),
      ),
    );
  }
}
