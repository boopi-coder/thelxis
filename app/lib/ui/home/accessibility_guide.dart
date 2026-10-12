import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../theme.dart';

/// Step-by-step help for Android 13+, where the accessibility switch of an app
/// installed outside a store is greyed out ("Restricted setting") until the
/// user picks "Allow restricted settings" in App info. The OS offers no way to
/// do this for the user, so the card walks through it and opens each screen.
class AccessibilityGuide extends StatelessWidget {
  const AccessibilityGuide({
    super.key,
    required this.onOpenAccessibility,
    required this.onOpenAppInfo,
    required this.onRecheck,
  });

  final VoidCallback onOpenAccessibility;
  final VoidCallback onOpenAppInfo;

  /// Reads the service state again (it is also re-read on every app resume).
  final VoidCallback onRecheck;

  @override
  Widget build(BuildContext context) {
    final s = context.s;
    final t = Theme.of(context).textTheme;
    final c = context.c;
    return Column(
      key: const ValueKey('accessibility-guide'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.t('perm.guide.intro'), style: t.bodySmall?.copyWith(color: c.textSecondary)),
        const SizedBox(height: Gap.s),
        _GuideStep(
          number: 1,
          text: s.t('perm.guide.step1'),
          buttonKey: const ValueKey('guide-step1'),
          buttonLabel: s.t('perm.guide.step1.btn'),
          onPressed: onOpenAccessibility,
        ),
        _GuideStep(
          number: 2,
          text: s.t('perm.guide.step2'),
          buttonKey: const ValueKey('guide-step2'),
          buttonLabel: s.t('perm.guide.step2.btn'),
          onPressed: onOpenAppInfo,
        ),
        _GuideStep(
          number: 3,
          text: s.t('perm.guide.step3'),
          buttonKey: const ValueKey('guide-step3'),
          buttonLabel: s.t('perm.guide.step3.btn'),
          onPressed: onOpenAccessibility,
        ),
        Text(s.t('perm.guide.oem'), style: t.bodySmall?.copyWith(color: c.textMuted)),
        const SizedBox(height: Gap.xs),
        TextButton.icon(
          key: const ValueKey('guide-recheck'),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: Gap.s),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: onRecheck,
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: Text(s.t('perm.guide.recheck')),
        ),
      ],
    );
  }
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({
    required this.number,
    required this.text,
    required this.buttonKey,
    required this.buttonLabel,
    required this.onPressed,
  });

  final int number;
  final String text;
  final Key buttonKey;
  final String buttonLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.inset, shape: BoxShape.circle),
            child: Text('$number', style: t.labelSmall?.copyWith(color: c.textSecondary)),
          ),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(text, style: t.bodySmall?.copyWith(color: c.text)),
                ),
                const SizedBox(height: Gap.xs),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: buttonKey,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: onPressed,
                    child: Text(buttonLabel),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
