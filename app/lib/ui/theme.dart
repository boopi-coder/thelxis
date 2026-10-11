import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Spacing scale used across screens.
abstract final class Gap {
  static const double xs = 4;
  static const double s = 8;
  static const double m = 12;
  static const double l = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Corner radii: cards 12, controls and fields 8, pills 20.
abstract final class Radii {
  static const double card = 12;
  static const double control = 8;
  static const double pill = 20;
  static const double dialog = 14;
}

/// Widest the page content grows; beyond it the content is centred.
const double kContentMaxWidth = 1280;

/// Window widths where the shell changes layout.
const double kSidebarMinWidth = 1000;
const double kRailMinWidth = 600;

/// Tabular figures keep the digits of the ID and passwords from jittering.
const List<FontFeature> kTabularFigures = [FontFeature.tabularFigures()];

/// The colour tokens of the light / dark UI (flat surfaces, hairlines, one
/// blue accent). Everything visual in the app reads from here (or from the
/// [ColorScheme] mapped from it).
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.page,
    required this.sidebar,
    required this.surface,
    required this.inset,
    required this.insetStrong,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentHover,
    required this.accentSoft,
    required this.success,
    required this.successBg,
    required this.warning,
    required this.warningBg,
    required this.danger,
    required this.dangerBg,
    required this.online,
    required this.hover,
    required this.tooltip,
  });

  /// Window background.
  final Color page;
  final Color sidebar;

  /// Cards, dialogs, popovers.
  final Color surface;

  /// Fields and secondary buttons sitting on a [surface].
  final Color inset;
  final Color insetStrong;

  /// 1px hairline between and around surfaces.
  final Color border;
  final Color borderStrong;

  final Color text;
  final Color textSecondary;
  final Color textMuted;

  final Color accent;
  final Color accentHover;

  /// Selection fill: a faint tint of the accent.
  final Color accentSoft;

  final Color success;
  final Color successBg;
  final Color warning;
  final Color warningBg;
  final Color danger;
  final Color dangerBg;

  /// Status dot of an online device.
  final Color online;

  /// Row hover overlay (4-6% of the text colour).
  final Color hover;
  final Color tooltip;

  static const AppColors light = AppColors(
    page: Color(0xFFF5F5F7),
    sidebar: Color(0xFFECECEF),
    surface: Color(0xFFFFFFFF),
    inset: Color(0xFFF2F2F5),
    insetStrong: Color(0xFFE8E8EC),
    border: Color(0xFFE2E2E6),
    borderStrong: Color(0xFFCFCFD4),
    text: Color(0xFF1D1D1F),
    textSecondary: Color(0xFF6E6E73),
    textMuted: Color(0xFF8A8A90),
    accent: Color(0xFF0A84FF),
    accentHover: Color(0xFF0071E3),
    accentSoft: Color(0x1F0A84FF),
    success: Color(0xFF1E7B3A),
    successBg: Color(0xFFE7F7EC),
    warning: Color(0xFF8A5A00),
    warningBg: Color(0xFFFFF4D6),
    danger: Color(0xFFD70015),
    dangerBg: Color(0xFFFDE8EA),
    online: Color(0xFF30B158),
    hover: Color(0x0D000000),
    tooltip: Color(0xFF2C2C2E),
  );

  static const AppColors dark = AppColors(
    page: Color(0xFF1C1C1E),
    sidebar: Color(0xFF161618),
    surface: Color(0xFF242426),
    inset: Color(0xFF2C2C2E),
    insetStrong: Color(0xFF38383A),
    border: Color(0xFF38383A),
    borderStrong: Color(0xFF48484A),
    text: Color(0xFFF5F5F7),
    textSecondary: Color(0xFFA1A1A6),
    textMuted: Color(0xFF8E8E93),
    accent: Color(0xFF0A84FF),
    accentHover: Color(0xFF3B9BFF),
    accentSoft: Color(0x290A84FF),
    success: Color(0xFF32D74B),
    successBg: Color(0xFF173A20),
    warning: Color(0xFFFFD60A),
    warningBg: Color(0xFF3A3214),
    danger: Color(0xFFFF453A),
    dangerBg: Color(0xFF3D1A18),
    online: Color(0xFF32D74B),
    hover: Color(0x0DFFFFFF),
    tooltip: Color(0xFF48484A),
  );

  @override
  AppColors copyWith() => this;

  // Themes switch instantly; there is nothing to interpolate.
  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) =>
      other is AppColors && t >= 0.5 ? other : this;
}

extension AppColorsX on BuildContext {
  AppColors get c => Theme.of(this).extension<AppColors>() ?? AppColors.light;
}

/// Semantic status colours that stay readable in both themes (text colours;
/// the soft backgrounds live in [AppColors]).
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({required this.good, required this.warn, required this.bad});

  final Color good;
  final Color warn;
  final Color bad;

  static const StatusColors dark = StatusColors(
    good: Color(0xFF32D74B),
    warn: Color(0xFFFFD60A),
    bad: Color(0xFFFF453A),
  );
  static const StatusColors light = StatusColors(
    good: Color(0xFF1E7B3A),
    warn: Color(0xFF8A5A00),
    bad: Color(0xFFD70015),
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
  StatusColors get status => Theme.of(this).extension<StatusColors>() ?? StatusColors.light;
}

bool get _desktopTarget {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    default:
      return false;
  }
}

/// Hover/press/focus overlays are a faint wash of [base]; no ink splashes.
WidgetStateProperty<Color?> _wash(Color base) => WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) return base.withValues(alpha: 0.10);
      if (states.contains(WidgetState.hovered)) return base.withValues(alpha: 0.05);
      if (states.contains(WidgetState.focused)) return base.withValues(alpha: 0.08);
      return null;
    });

ButtonStyle _buttonStyle(
  AppColors c, {
  required TextStyle? label,
  required Color background,
  required Color foreground,
  Color? hoverBackground,
  BorderSide? side,
  Color? disabledBackground,
}) {
  return ButtonStyle(
    elevation: const WidgetStatePropertyAll(0),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    splashFactory: NoSplash.splashFactory,
    minimumSize: WidgetStatePropertyAll(Size(0, _desktopTarget ? 34 : 44)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
    ),
    textStyle: WidgetStatePropertyAll(label?.copyWith(inherit: false)),
    side: side == null ? null : WidgetStatePropertyAll(side),
    backgroundColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return disabledBackground ?? c.inset;
      if (states.contains(WidgetState.hovered) || states.contains(WidgetState.pressed)) {
        return hoverBackground ?? background;
      }
      return background;
    }),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled) ? c.textMuted : foreground,
    ),
    overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    iconSize: const WidgetStatePropertyAll(18),
  );
}

/// Style for [FilledButton] used as the quiet secondary action (the theme's
/// filled style is the blue primary one). One filled primary per view.
extension ButtonStyles on BuildContext {
  ButtonStyle get secondaryButton => _buttonStyle(
        c,
        label: Theme.of(this).textTheme.labelLarge,
        background: c.inset,
        foreground: c.text,
        hoverBackground: c.insetStrong,
      );

  /// The one red button: ending a session, removing a device.
  ButtonStyle get dangerButton => _buttonStyle(
        c,
        label: Theme.of(this).textTheme.labelLarge,
        background: c.danger,
        foreground: Colors.white,
        hoverBackground: Color.alphaBlend(const Color(0x1F000000), c.danger),
      );
}

ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final c = isDark ? AppColors.dark : AppColors.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: Colors.white,
    primaryContainer: Color.alphaBlend(c.accentSoft, c.surface),
    onPrimaryContainer: c.accent,
    secondary: c.textSecondary,
    onSecondary: c.surface,
    secondaryContainer: c.inset,
    onSecondaryContainer: c.text,
    tertiary: c.accent,
    onTertiary: Colors.white,
    tertiaryContainer: Color.alphaBlend(c.accentSoft, c.surface),
    onTertiaryContainer: c.accent,
    error: c.danger,
    onError: isDark ? const Color(0xFF1C1C1E) : Colors.white,
    errorContainer: c.dangerBg,
    onErrorContainer: c.danger,
    surface: c.surface,
    onSurface: c.text,
    onSurfaceVariant: c.textSecondary,
    surfaceDim: c.page,
    surfaceBright: c.surface,
    surfaceContainerLowest: c.surface,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.inset,
    surfaceContainerHighest: c.insetStrong,
    outline: c.borderStrong,
    outlineVariant: c.border,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: c.tooltip,
    onInverseSurface: Colors.white,
    inversePrimary: c.accent,
    surfaceTint: Colors.transparent,
  );

  final textTheme = _textTheme(brightness, c);
  final controlShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control));
  final desktop = _desktopTarget;
  final labelStyle = textTheme.labelLarge;

  ButtonStyle button({
    required Color background,
    required Color foreground,
    Color? hoverBackground,
    BorderSide? side,
    Color? disabledBackground,
  }) =>
      _buttonStyle(
        c,
        label: labelStyle,
        background: background,
        foreground: foreground,
        hoverBackground: hoverBackground,
        side: side,
        disabledBackground: disabledBackground,
      );

  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(Radii.control),
    borderSide: BorderSide.none,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    scaffoldBackgroundColor: c.page,
    canvasColor: c.surface,
    visualDensity: VisualDensity.standard,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: c.hover,
    focusColor: c.hover,
    dividerColor: c.border,
    extensions: [c, isDark ? StatusColors.dark : StatusColors.light],
    textTheme: textTheme,
    iconTheme: IconThemeData(color: c.textSecondary, size: 20),
    primaryIconTheme: IconThemeData(color: c.textSecondary, size: 20),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(color: c.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.inset,
      isDense: true,
      border: inputBorder,
      enabledBorder: inputBorder,
      disabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(borderSide: BorderSide(color: c.accent, width: 1.5)),
      errorBorder: inputBorder.copyWith(borderSide: BorderSide(color: c.danger)),
      focusedErrorBorder: inputBorder.copyWith(borderSide: BorderSide(color: c.danger, width: 1.5)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      hintStyle: textTheme.bodyMedium?.copyWith(color: c.textMuted),
      labelStyle: textTheme.bodyMedium?.copyWith(color: c.textSecondary),
      helperStyle: textTheme.bodySmall?.copyWith(color: c.textMuted),
      errorStyle: textTheme.bodySmall?.copyWith(color: c.danger),
      prefixIconColor: c.textMuted,
      suffixIconColor: c.textMuted,
      prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 36),
      suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 36),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: button(
        background: c.accent,
        foreground: Colors.white,
        hoverBackground: c.accentHover,
        disabledBackground: c.insetStrong,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: button(
        background: Colors.transparent,
        foreground: c.text,
        hoverBackground: c.hover,
        side: BorderSide(color: c.borderStrong),
        disabledBackground: Colors.transparent,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: button(
        background: Colors.transparent,
        foreground: c.accent,
        hoverBackground: c.accent.withValues(alpha: 0.08),
        disabledBackground: Colors.transparent,
      ).copyWith(
        minimumSize: const WidgetStatePropertyAll(Size(0, 32)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        splashFactory: NoSplash.splashFactory,
        iconSize: const WidgetStatePropertyAll(20),
        minimumSize: WidgetStatePropertyAll(Size.square(desktop ? 32 : 40)),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        shape: WidgetStatePropertyAll(controlShape),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? c.textMuted.withValues(alpha: 0.5)
              : states.contains(WidgetState.selected)
                  ? c.accent
                  : c.textSecondary,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? c.accentSoft : null,
        ),
        overlayColor: _wash(c.text),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: const Color(0x33000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.dialog),
        side: BorderSide(color: c.border),
      ),
      titleTextStyle: textTheme.titleLarge,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: c.textSecondary),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: c.surface,
      elevation: 0,
      showDragHandle: true,
      dragHandleColor: c.borderStrong,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.inset,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control)),
      labelStyle: textTheme.labelMedium,
      iconTheme: IconThemeData(color: c.textSecondary, size: 16),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.sidebar,
      surfaceTintColor: Colors.transparent,
      indicatorColor: c.accentSoft,
      elevation: 0,
      height: 60,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => textTheme.labelSmall?.copyWith(
          color: states.contains(WidgetState.selected) ? c.accent : c.textSecondary,
          fontWeight: FontWeight.w500,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected) ? c.accent : c.textSecondary,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.surface,
      elevation: 6,
      // Every toast can be closed: with an action Flutter would otherwise
      // keep it on screen until swiped away.
      showCloseIcon: true,
      closeIconColor: c.textSecondary,
      actionTextColor: c.accent,
      contentTextStyle: textTheme.bodyMedium,
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(color: c.border),
      ),
    ),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(
      shape: controlShape,
      iconColor: c.textSecondary,
      textColor: c.text,
      selectedColor: c.accent,
      selectedTileColor: c.accentSoft,
      titleTextStyle: textTheme.bodyLarge?.copyWith(fontSize: 13, fontWeight: FontWeight.w500),
      subtitleTextStyle: textTheme.bodySmall?.copyWith(color: c.textSecondary),
      minVerticalPadding: 8,
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
      tilePadding: EdgeInsets.symmetric(horizontal: 16),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shadowColor: const Color(0x33000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: c.border),
      ),
      textStyle: textTheme.bodyMedium,
      menuPadding: const EdgeInsets.symmetric(vertical: 4),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.tooltip, borderRadius: BorderRadius.circular(6)),
      textStyle: textTheme.bodySmall?.copyWith(color: Colors.white),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      waitDuration: const Duration(milliseconds: 600),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(shape: controlShape, side: BorderSide(color: c.borderStrong)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? c.accent : c.insetStrong,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? c.accent : Colors.transparent,
      ),
      side: BorderSide(color: c.borderStrong, width: 1.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? c.accent : c.borderStrong,
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.insetStrong,
      circularTrackColor: Colors.transparent,
      linearMinHeight: 4,
    ),
    tabBarTheme: TabBarThemeData(
      dividerColor: Colors.transparent,
      labelColor: c.text,
      unselectedLabelColor: c.textSecondary,
      labelStyle: textTheme.labelLarge,
      unselectedLabelStyle: textTheme.labelLarge,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      splashFactory: NoSplash.splashFactory,
    ),
    scrollbarTheme: ScrollbarThemeData(
      radius: const Radius.circular(4),
      thickness: const WidgetStatePropertyAll(6),
      thumbColor: WidgetStatePropertyAll(c.text.withValues(alpha: 0.28)),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: 0.28),
      selectionHandleColor: c.accent,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
    }),
  );
}

/// The type scale: 11 / 12 / 13 / 15 / 17 / 22 / 28, weights 400 / 500 / 600.
/// The platform's own system font is used; none is bundled.
TextTheme _textTheme(Brightness brightness, AppColors c) {
  final platform = Typography.material2021(platform: defaultTargetPlatform);
  final base = (brightness == Brightness.dark ? platform.white : platform.black)
      .apply(bodyColor: c.text, displayColor: c.text);
  TextStyle? t(TextStyle? s, double size, FontWeight weight, {double height = 1.35, double spacing = 0}) =>
      s?.copyWith(fontSize: size, fontWeight: weight, height: height, letterSpacing: spacing);
  return base.copyWith(
    displayLarge: t(base.displayLarge, 28, FontWeight.w600, spacing: -0.2),
    displayMedium: t(base.displayMedium, 28, FontWeight.w600, spacing: -0.2),
    displaySmall: t(base.displaySmall, 22, FontWeight.w600, spacing: -0.1),
    headlineLarge: t(base.headlineLarge, 28, FontWeight.w600, spacing: -0.2),
    headlineMedium: t(base.headlineMedium, 28, FontWeight.w600, spacing: -0.2),
    headlineSmall: t(base.headlineSmall, 22, FontWeight.w600, height: 1.25, spacing: -0.1),
    titleLarge: t(base.titleLarge, 17, FontWeight.w600, height: 1.3),
    titleMedium: t(base.titleMedium, 15, FontWeight.w600, height: 1.3),
    titleSmall: t(base.titleSmall, 13, FontWeight.w600),
    bodyLarge: t(base.bodyLarge, 15, FontWeight.w400),
    bodyMedium: t(base.bodyMedium, 13, FontWeight.w400),
    bodySmall: t(base.bodySmall, 12, FontWeight.w400),
    labelLarge: t(base.labelLarge, 13, FontWeight.w500),
    labelMedium: t(base.labelMedium, 12, FontWeight.w500),
    labelSmall: t(base.labelSmall, 11, FontWeight.w500),
  );
}

extension AppTextStyles on BuildContext {
  /// The Thelxis ID: 28 px, semibold, tabular digits, slightly tracked.
  TextStyle get idStyle => Theme.of(this).textTheme.headlineMedium!.copyWith(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        letterSpacing: 1,
        fontFeatures: kTabularFigures,
        color: c.text,
      );
}
