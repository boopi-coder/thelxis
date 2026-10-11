import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
      return 'Unknown OS';
  }
}

/// Copies [text] and confirms with a snackbar. [what] names the thing copied.
Future<void> copyToClipboard(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text('$what copied'), duration: const Duration(seconds: 2)));
}

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

enum PillTone { good, warn, bad, neutral }

/// Small rounded status label with a coloured dot.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.tone, this.onTap, this.trailing});

  final String label;
  final PillTone tone;
  final VoidCallback? onTap;
  final Widget? trailing;

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
    final child = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 6), trailing!],
        ],
      ),
    );
    if (onTap == null) return child;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: child,
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
      padding: const EdgeInsets.fromLTRB(4, Gap.l, 4, Gap.s),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: t.textTheme.labelMedium?.copyWith(
                color: t.colorScheme.onSurfaceVariant,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ?trailing,
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

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message});

  final IconData icon;
  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(Gap.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(height: Gap.m),
          Text(title, style: t.textTheme.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: Gap.xs),
            Text(
              message!,
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ],
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
