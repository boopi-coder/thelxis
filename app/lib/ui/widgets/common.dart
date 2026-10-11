import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../theme.dart';
import 'hover_tint.dart';
import 'thelxis_logo.dart';

IconData osIcon(String os) {
  switch (os) {
    case 'windows':
      return Icons.desktop_windows_outlined;
    case 'macos':
    case 'ios':
      return Icons.laptop_mac_outlined;
    case 'linux':
      return Icons.computer_outlined;
    case 'android':
      return Icons.smartphone_outlined;
    default:
      return Icons.devices_other_outlined;
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

/// Copies [text] and confirms with a toast. [what] names the thing copied.
Future<void> copyToClipboard(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  showMessage(context, context.s.t('common.copied', {'what': what}));
}

/// A short toast. Every toast has a close button (the theme turns it on) and
/// goes away by itself.
void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 4)));
}

enum PillTone { good, warn, bad, neutral }

/// The solid colour of a status dot for [tone].
Color toneDot(AppColors c, PillTone tone) => switch (tone) {
      PillTone.good => c.online,
      PillTone.warn => const Color(0xFFFF9F0A),
      PillTone.bad => c.danger,
      PillTone.neutral => c.textMuted,
    };

/// Small rounded status label with a dot. Soft tinted background, coloured
/// text; no animation, so a status change never flashes.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.tone,
    this.onTap,
    this.trailing,
  });

  final String label;
  final PillTone tone;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final (fg, bg) = switch (tone) {
      PillTone.good => (c.success, c.successBg),
      PillTone.warn => (c.warning, c.warningBg),
      PillTone.bad => (c.danger, c.dangerBg),
      PillTone.neutral => (c.textSecondary, c.inset),
    };
    final dot = toneDot(c, tone);
    final pill = DecoratedBox(
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Radii.pill)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 4), trailing!],
          ],
        ),
      ),
    );
    if (onTap == null) return pill;
    return HoverTint(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.pill),
      child: pill,
    );
  }
}

/// Small secondary-coloured heading above a group or list.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, Gap.xl, 0, 6),
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: t.textTheme.labelMedium?.copyWith(
                  color: context.c.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
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
      padding: const EdgeInsets.fromLTRB(4, 0, 0, Gap.s),
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
                      style: t.textTheme.bodyMedium?.copyWith(color: context.c.textSecondary),
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

/// Horizontal page padding: 24 (16 on phones), plus whatever it takes to keep
/// the content at most [maxWidth] wide and centred.
double pageGutter(double viewportWidth, {double maxWidth = kContentMaxWidth}) {
  final base = viewportWidth < kRailMinWidth ? 16.0 : 24.0;
  final extra = (viewportWidth - maxWidth) / 2;
  return extra > 0 ? base + extra : base;
}

/// The scrolling body of a page: a centred column of at most [maxWidth].
class PageScroll extends StatelessWidget {
  const PageScroll({super.key, required this.children, this.maxWidth = kContentMaxWidth});

  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final gutter = pageGutter(box.maxWidth, maxWidth: maxWidth);
        final top = box.maxWidth < kRailMinWidth ? 16.0 : 24.0;
        return ListView(
          padding: EdgeInsets.fromLTRB(gutter, top, gutter, 32),
          children: children,
        );
      },
    );
  }
}

/// Empty list placeholder: a quiet icon, a title and a hint.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.compact = false,
    this.logo = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  /// Less padding, for placeholders inside a card.
  final bool compact;

  /// Show the Thelxis logo instead of [icon] (first-run placeholders).
  final bool logo;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = context.c;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: Gap.xl, vertical: compact ? Gap.xl : Gap.xxl),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (logo) const ThelxisLogo(size: 40) else Icon(icon, size: 28, color: c.textMuted),
            const SizedBox(height: Gap.m),
            Text(
              title,
              style: t.textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: Gap.xs),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Text(
                  message!,
                  style: t.textTheme.bodySmall?.copyWith(color: c.textSecondary),
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
