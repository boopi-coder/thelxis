import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../theme.dart';

IconData osIcon(String os) {
  switch (os) {
    case 'windows':
      return Icons.window_rounded;
    case 'macos':
    case 'ios':
      return Icons.laptop_mac_rounded;
    case 'linux':
      return Icons.computer_rounded;
    case 'android':
      return Icons.phone_android_rounded;
    default:
      return Icons.devices_other_rounded;
  }
}

String osLabel(String os) {
  switch (os) {
    case 'windows':
      return 'Windows';
    case 'macos':
      return 'macOS';
    case 'linux':
      return 'Linux';
    case 'android':
      return 'Android';
    case 'ios':
      return 'iOS';
    default:
      return S.current.t('common.unknownOs');
  }
}

/// Copies [text] and confirms with a snackbar. [what] names the thing copied.
Future<void> copyToClipboard(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  showMessage(context, context.s.t('common.copied', {'what': what}));
}

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
}

enum PillTone { good, warn, bad, neutral }

/// Small rounded status label with a coloured dot; colour changes animate.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.tone,
    this.onTap,
    this.trailing,
    this.onGradient = false,
  });

  final String label;
  final PillTone tone;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// Draw for use on the violet hero gradient: white text, glass fill.
  final bool onGradient;

  @override
  Widget build(BuildContext context) {
    final s = context.status;
    final scheme = Theme.of(context).colorScheme;
    final color = switch (tone) {
      PillTone.good => s.good,
      PillTone.warn => s.warn,
      PillTone.bad => s.bad,
      PillTone.neutral => scheme.onSurfaceVariant,
    };
    final text = onGradient ? context.brand.onHero : color;
    final child = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: onGradient ? context.brand.glass : color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: onGradient ? context.brand.glassBorder : color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: Theme.of(context).textTheme.labelLarge!.copyWith(color: text),
              child: Text(label, overflow: TextOverflow.ellipsis),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 6), trailing!],
        ],
      ),
    );
    if (onTap == null) return child;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: child,
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, Gap.xl, 4, Gap.s),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: t.textTheme.labelMedium?.copyWith(
                color: t.colorScheme.onSurfaceVariant,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Page title block shown at the top of each main page.
class PageTitle extends StatelessWidget {
  const PageTitle(this.title, {super.key, this.subtitle, this.actions = const []});

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, Gap.l, 4, Gap.s),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.textTheme.headlineSmall),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// Centered content column with a max width, scrolling when needed.
class PageScroll extends StatelessWidget {
  const PageScroll({super.key, required this.children, this.maxWidth = 920});

  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xxl),
          children: children,
        ),
      ),
    );
  }
}

/// Empty list placeholder: a tonal icon badge, a title and a hint.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xl, vertical: Gap.xxl),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    t.colorScheme.primaryContainer,
                    t.colorScheme.primaryContainer.withValues(alpha: 0.45),
                  ],
                ),
              ),
              child: Icon(icon, size: 28, color: t.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(height: Gap.l),
            Text(title, style: t.textTheme.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: Gap.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  message!,
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: Gap.l), action!],
          ],
        ),
      ),
    );
  }
}

/// Frosted-glass panel: blurred backdrop, translucent fill, hairline border.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Gap.l),
    this.radius = 18,
    this.blur = 14,
    this.fill,
    this.border,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;
  final Color? fill;
  final Color? border;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: fill ?? brand.glass,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: border ?? brand.glassBorder),
          ),
          child: child,
        ),
      ),
    );
  }
}

bool isDesktopPlatform(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    default:
      return false;
  }
}
