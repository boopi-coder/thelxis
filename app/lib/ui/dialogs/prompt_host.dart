import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../session/prompts.dart';
import '../../session/session_manager.dart';
import 'prompt_dialogs.dart';

/// Shows the head of the prompt queue as a modal dialog on top of whatever is
/// on screen, one prompt at a time.
class PromptHost extends StatefulWidget {
  const PromptHost({super.key, required this.navigatorKey, required this.child});

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<PromptHost> createState() => _PromptHostState();
}

class _PromptHostState extends State<PromptHost> {
  PromptQueue? _queue;
  Prompt<Object?>? _showing;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final q = context.read<SessionManager>().prompts;
    if (!identical(q, _queue)) {
      _queue?.removeListener(_onChange);
      _queue = q..addListener(_onChange);
      WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
    }
  }

  @override
  void dispose() {
    _queue?.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    final next = _queue?.current;
    if (next == null || identical(next, _showing)) return;
    final nav = widget.navigatorKey.currentState;
    final overlayContext = widget.navigatorKey.currentContext;
    if (nav == null || overlayContext == null) {
      // The navigator is not built yet (first frame); try again shortly.
      WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
      return;
    }
    _showing = next;
    BuildContext? dialogContext;
    unawaited(next.result.then<void>((_) {
      final c = dialogContext;
      if (c != null && c.mounted) Navigator.of(c).pop();
    }));
    showDialog<void>(
      context: overlayContext,
      barrierDismissible: false,
      builder: (c) {
        dialogContext = c;
        if (next.isResolved) {
          // Answered before the route was even built (e.g. a timeout).
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (c.mounted) Navigator.of(c).pop();
          });
        }
        return promptDialog(next);
      },
    ).whenComplete(() {
      // A dialog dismissed without an answer must still resolve its prompt.
      if (!next.isResolved) _dismiss(next);
      _showing = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
    });
  }

  void _dismiss(Prompt<Object?> p) {
    switch (p) {
      case AcceptRequestPrompt():
        p.resolve(ApprovalResult.denied);
      case ReverseOfferPrompt():
        p.resolve(false);
      case FirstContactPrompt():
        p.resolve(false);
      case WarningPrompt():
        p.resolve(null);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
