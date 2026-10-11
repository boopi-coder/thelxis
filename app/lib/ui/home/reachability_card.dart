import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'reachability_advice.dart';

/// The top card of the diagnostics: status pill, a plain-language title and
/// sentence, a few steps, and buttons for the actions that can be done right
/// here.
class ReachabilityAdviceCard extends StatelessWidget {
  const ReachabilityAdviceCard({super.key, required this.advice, required this.onAction});

  final ReachAdvice advice;
  final void Function(AdviceAction action) onAction;

  String _actionLabel(S s, AdviceAction a) => switch (a) {
        AdviceAction.enableIncoming => s.t('reach.action.enableIncoming'),
        AdviceAction.enableMapping => s.t('reach.action.enableMapping'),
        AdviceAction.manualForwarding => s.t('reach.action.manualForwarding'),
        AdviceAction.reverseConnection => s.t('connect.reverse'),
        AdviceAction.connectByCode => s.t('code.title'),
        AdviceAction.rescan => s.t('diag.rescan'),
      };

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context);
    final steps = advice.steps(s);
    return Card(
      key: const ValueKey('reach-advice'),
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusPill(label: advice.label(s), tone: advice.tone),
            const SizedBox(height: Gap.m),
            Text(advice.title(s), style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Gap.xs),
            Text(advice.body(s)),
            if (steps.isNotEmpty) ...[
              const SizedBox(height: Gap.m),
              if (!advice.reachable)
                Text(
                  s.t('reach.steps.title'),
                  style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
              for (final step in steps)
                Padding(
                  padding: const EdgeInsets.only(top: Gap.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 2, right: Gap.s),
                        child: Icon(Icons.chevron_right_rounded, size: 18),
                      ),
                      Expanded(child: Text(step)),
                    ],
                  ),
                ),
            ],
            if (advice.actions.isNotEmpty) ...[
              const SizedBox(height: Gap.m),
              Wrap(
                spacing: Gap.s,
                runSpacing: Gap.s,
                children: [
                  for (final (i, a) in advice.actions.indexed)
                    i == 0
                        ? FilledButton.tonal(
                            key: ValueKey('reach-action-${a.name}'),
                            onPressed: () => onAction(a),
                            child: Text(_actionLabel(s, a)),
                          )
                        : OutlinedButton(
                            key: ValueKey('reach-action-${a.name}'),
                            onPressed: () => onAction(a),
                            child: Text(_actionLabel(s, a)),
                          ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
