import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../protocol/control_messages.dart';
import '../../session/viewer_session.dart';
import '../theme.dart';

/// Persistent, non-blocking notice at the bottom of the remote picture when
/// the host cannot act on our input (PROTOCOL.md 6.2 `input_state`). Touches
/// pass through it to the input layer.
class InputStateBanner extends StatelessWidget {
  const InputStateBanner({super.key, required this.session});

  final ViewerSession session;

  /// Localization key for what the viewer should be told, or null.
  static String? messageKey(ViewerSession session) => switch (session.inputIssue) {
        InputIssue.permission => 'session.input.permission',
        InputIssue.blocked => 'session.input.blocked',
        null => null,
      };

  @override
  Widget build(BuildContext context) {
    final key = messageKey(session);
    if (key == null) return const SizedBox.shrink();
    final c = context.c;
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: DecoratedBox(
                key: const ValueKey('input-state-banner'),
                decoration: BoxDecoration(
                  color: c.warningBg,
                  borderRadius: BorderRadius.circular(Radii.card),
                  border: Border.all(color: c.warning.withValues(alpha: 0.5)),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s + 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 20, color: c.warning),
                      const SizedBox(width: Gap.s),
                      Flexible(
                        child: Text(
                          context.s.t(key),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: c.warning),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
