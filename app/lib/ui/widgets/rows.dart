import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';

import '../theme.dart';
import 'hover_tint.dart';
import 'surface.dart';

/// A titled group of rows in one card, like a System Settings pane. Rows are
/// separated by hairlines.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    this.footer,
    this.trailing,
    required this.children,
  });

  final String? title;
  final String? footer;

  /// Shown at the right end of the title line (for example "Scan").
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null || trailing != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 0, 6),
            child: SizedBox(
              height: 28,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title ?? '',
                      style: t.labelMedium?.copyWith(
                        color: c.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        AppCard(
          clip: true,
          child: Column(
            children: [
              for (final (i, child) in children.indexed) ...[
                if (i > 0) const Hairline(indent: 16),
                child,
              ],
            ],
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Text(
              footer!,
              style: t.bodySmall?.copyWith(color: c.textMuted),
            ),
          ),
      ],
    );
  }
}

/// One row of a [SettingsGroup]: icon, title + subtitle on the left, a
/// control on the right. With [onTap] the whole row is a hover-tinted button.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onTap,
    this.titleColor,
    this.enabled = true,
    this.stackTrailingBelow,
  });

  /// Below this row width a wide [trailing] control (a segmented control)
  /// moves under the text instead of squeezing it.
  final double? stackTrailingBelow;

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.c;
    Widget textBlock() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: t.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
            color: enabled ? (titleColor ?? c.text) : c.textMuted,
          ),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              subtitle!,
              style: t.bodySmall?.copyWith(color: c.textSecondary),
            ),
          ),
      ],
    );
    Widget iconWidget() => Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Icon(
        icon,
        size: 18,
        color: enabled ? c.textSecondary : c.textMuted,
      ),
    );
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: LayoutBuilder(
        builder: (context, box) {
          final stack =
              trailing != null &&
              stackTrailingBelow != null &&
              box.maxWidth < stackTrailingBelow!;
          if (stack) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (icon != null) iconWidget(),
                    Expanded(child: textBlock()),
                  ],
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: EdgeInsets.only(left: icon != null ? 30 : 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: trailing,
                  ),
                ),
              ],
            );
          }
          return ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 24),
            child: Row(
              children: [
                if (icon != null) iconWidget(),
                Expanded(child: textBlock()),
                if (trailing != null) ...[const SizedBox(width: 12), trailing!],
              ],
            ),
          );
        },
      ),
    );
    if (onTap == null) return row;
    return HoverTint(onTap: enabled ? onTap : null, child: row);
  }
}

/// A [SettingsRow] with a switch. Disabled (and greyed) when [onChanged] is
/// null.
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      enabled: enabled,
      onTap: enabled ? () => onChanged!(!value) : null,
      trailing: AppSwitch(value: value, onChanged: onChanged),
    );
  }
}

/// The platform-neutral switch: a compact rounded track, white thumb, accent
/// when on.
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      width: 40,
      height: 24,
      child: FittedBox(
        child: CupertinoSwitch(
          value: value,
          onChanged: onChanged,
          activeTrackColor: c.accent,
          inactiveTrackColor: c.insetStrong,
          thumbColor: Colors.white,
        ),
      ),
    );
  }
}

/// A segmented control: an inset track with the selected option raised.
class AppSegmented<T> extends StatelessWidget {
  const AppSegmented({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<(T value, String label, IconData? icon)> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final t = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.inset,
        borderRadius: BorderRadius.circular(Radii.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (value, label, icon) in options)
            Flexible(
              child: HoverTint(
                onTap: () => onChanged(value),
                borderRadius: BorderRadius.circular(6),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: value == selected
                        ? (dark ? c.insetStrong : c.surface)
                        : null,
                    borderRadius: BorderRadius.circular(6),
                    border: value == selected
                        ? Border.all(
                            color: c.border,
                            width: hairlineOf(context),
                          )
                        : null,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(
                            icon,
                            size: 15,
                            color: value == selected ? c.text : c.textSecondary,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.labelMedium?.copyWith(
                              color: value == selected
                                  ? c.text
                                  : c.textSecondary,
                              fontWeight: value == selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
