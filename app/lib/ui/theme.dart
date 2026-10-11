import 'package:flutter/foundation.dart';
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

/// Brand surfaces: the violet hero gradient and the frosted-glass tones used
/// on top of it.
@immutable
class BrandSurfaces extends ThemeExtension<BrandSurfaces> {
  const BrandSurfaces({
    required this.hero,
    required this.onHero,
    required this.onHeroMuted,
    required this.glass,
    required this.glassBorder,
  });

  /// Background of the Home ID card.
  final LinearGradient hero;
  final Color onHero;
  final Color onHeroMuted;

  /// Translucent fill for panels sitting on [hero].
  final Color glass;
  final Color glassBorder;

  static const BrandSurfaces dark = BrandSurfaces(
    hero: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF3B2A99), Color(0xFF6C4CF5), Color(0xFF8E6BFF)],
    ),
    onHero: Colors.white,
    onHeroMuted: Color(0xCCFFFFFF),
    glass: Color(0x24FFFFFF),
    glassBorder: Color(0x33FFFFFF),
  );

  static const BrandSurfaces light = BrandSurfaces(
    hero: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF5B3FE0), Color(0xFF7B5CFF), Color(0xFFA48BFF)],
    ),
    onHero: Colors.white,
    onHeroMuted: Color(0xD9FFFFFF),
    glass: Color(0x2EFFFFFF),
    glassBorder: Color(0x40FFFFFF),
  );

  @override
  BrandSurfaces copyWith({
    LinearGradient? hero,
    Color? onHero,
    Color? onHeroMuted,
    Color? glass,
    Color? glassBorder,
  }) =>
      BrandSurfaces(
        hero: hero ?? this.hero,
        onHero: onHero ?? this.onHero,
        onHeroMuted: onHeroMuted ?? this.onHeroMuted,
        glass: glass ?? this.glass,
        glassBorder: glassBorder ?? this.glassBorder,
      );

  @override
  BrandSurfaces lerp(ThemeExtension<BrandSurfaces>? other, double t) => other is BrandSurfaces
      ? (t < 0.5 ? this : other)
      : this;
}

extension BrandSurfacesX on BuildContext {
  BrandSurfaces get brand => Theme.of(this).extension<BrandSurfaces>() ?? BrandSurfaces.dark;
}

extension StatusColorsX on BuildContext {
  StatusColors get status => Theme.of(this).extension<StatusColors>() ?? StatusColors.dark;
}

ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  var scheme = ColorScheme.fromSeed(seedColor: kBrandSeed, brightness: brightness);
  if (!isDark) {
    // The tonal palette of the seed comes out greyish in light mode; pin the
    // brand violet so buttons and the rail indicator stay vivid.
    scheme = scheme.copyWith(
      primary: const Color(0xFF5B3FE0),
      onPrimary: Colors.white,
      primaryContainer: const Color(0xFFE7E0FF),
      onPrimaryContainer: const Color(0xFF1F0E6B),
      surface: const Color(0xFFFBF9FF),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFF5F2FD),
      surfaceContainer: const Color(0xFFF0ECFA),
      surfaceContainerHigh: const Color(0xFFEAE6F6),
      surfaceContainerHighest: const Color(0xFFE4E0F1),
    );
  }
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
    extensions: [
      isDark ? StatusColors.dark : StatusColors.light,
      isDark ? BrandSurfaces.dark : BrandSurfaces.light,
    ],
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
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
      waitDuration: const Duration(milliseconds: 500),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: radius),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbIcon: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? const Icon(Icons.check_rounded) : null,
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      radius: const Radius.circular(8),
      thumbColor: WidgetStatePropertyAll(scheme.outline.withValues(alpha: 0.45)),
    ),
    textTheme: _textTheme(brightness),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}

TextTheme _textTheme(Brightness brightness) {
  final base = Typography.material2021(platform: defaultTargetPlatform).black;
  final t = brightness == Brightness.dark
      ? Typography.material2021(platform: defaultTargetPlatform).white
      : base;
  TextStyle? w(TextStyle? s, FontWeight weight, {double? spacing}) =>
      s?.copyWith(fontWeight: weight, letterSpacing: spacing);
  return t.copyWith(
    headlineMedium: w(t.headlineMedium, FontWeight.w600, spacing: -0.2),
    headlineSmall: w(t.headlineSmall, FontWeight.w600),
    titleLarge: w(t.titleLarge, FontWeight.w600),
    titleMedium: w(t.titleMedium, FontWeight.w600),
    titleSmall: w(t.titleSmall, FontWeight.w600),
    labelLarge: w(t.labelLarge, FontWeight.w600),
  );
}
