import 'package:flutter/material.dart';

/// Brand seed: deep violet (ARCHITECTURE.md UX concept).
const Color kBrandSeed = Color(0xFF6C4CF5);

/// Spacing scale used across screens.
abstract final class Gap {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Semantic status colours that stay readable in both themes.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({required this.good, required this.warn, required this.bad});

  final Color good;
  final Color warn;
  final Color bad;

  static const StatusColors dark = StatusColors(
    good: Color(0xFF3DD68C),
    warn: Color(0xFFFFB84D),
    bad: Color(0xFFFF6B6B),
  );
  static const StatusColors light = StatusColors(
    good: Color(0xFF1E9E63),
    warn: Color(0xFFB9770E),
    bad: Color(0xFFD64545),
  );

  @override
  StatusColors copyWith({Color? good, Color? warn, Color? bad}) =>
      StatusColors(good: good ?? this.good, warn: warn ?? this.warn, bad: bad ?? this.bad);

  @override
  StatusColors lerp(ThemeExtension<StatusColors>? other, double t) {
    if (other is! StatusColors) return this;
    return StatusColors(
      good: Color.lerp(good, other.good, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      bad: Color.lerp(bad, other.bad, t)!,
    );
  }
}

extension StatusColorsX on BuildContext {
  StatusColors get status => Theme.of(this).extension<StatusColors>() ?? StatusColors.dark;
}

ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  var scheme = ColorScheme.fromSeed(seedColor: kBrandSeed, brightness: brightness);
  if (isDark) {
    // A deeper, slightly violet-tinted canvas than the default tonal surface.
    scheme = scheme.copyWith(
      surface: const Color(0xFF0F0D17),
      surfaceContainerLowest: const Color(0xFF0B0A12),
      surfaceContainerLow: const Color(0xFF16131F),
      surfaceContainer: const Color(0xFF1B1826),
      surfaceContainerHigh: const Color(0xFF221F2F),
      surfaceContainerHighest: const Color(0xFF2A2638),
    );
  }
  final radius = BorderRadius.circular(14);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    extensions: [isDark ? StatusColors.dark : StatusColors.light],
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: isDark ? 0.35 : 0.6)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: radius),
        padding: const EdgeInsets.symmetric(horizontal: 20),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: radius)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      indicatorColor: scheme.primaryContainer,
      selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
      unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      labelType: NavigationRailLabelType.all,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      indicatorColor: scheme.primaryContainer,
      height: 68,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.4), space: 1),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: radius),
    ),
  );
}
