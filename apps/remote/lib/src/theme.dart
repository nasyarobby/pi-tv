import 'package:flutter/material.dart';

/// Pi TV colors: cool charcoal with a teal accent (approved 2026-11-12,
/// spec v0.11 §8). Used by the Android app and both web layouts.
abstract final class PiTvColors {
  /// App background.
  static const background = Color(0xFF121416);

  /// Cards, fields, bars.
  static const surface = Color(0xFF1C2024);

  /// Raised controls on a surface (secondary round buttons).
  static const surfaceHigh = Color(0xFF262B30);
  static const surfaceHighest = Color(0xFF2E343A);

  /// Light titles / body text, and muted secondary text.
  static const text = Color(0xFFE7EAED);
  static const textMuted = Color(0xFF9AA3AB);

  /// Teal accent: bright for highlights, deep for filled controls.
  static const accent = Color(0xFF2DD4BF);
  static const accentDeep = Color(0xFF14B8A6);

  /// Dark teal for tonal pills (Add to queue, selected nav pill).
  static const accentContainer = Color(0xFF0F3B37);
  static const onAccentContainer = Color(0xFFCCFBF1);

  static const outline = Color(0xFF3A4249);
  static const outlineVariant = Color(0xFF2A3036);
}

ThemeData buildPiTvTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: PiTvColors.accentDeep,
    onPrimary: Colors.white,
    primaryContainer: PiTvColors.accentContainer,
    onPrimaryContainer: PiTvColors.onAccentContainer,
    secondary: PiTvColors.accent,
    onSecondary: Color(0xFF042F2B),
    secondaryContainer: PiTvColors.accentContainer,
    onSecondaryContainer: PiTvColors.onAccentContainer,
    tertiary: PiTvColors.accent,
    onTertiary: Color(0xFF042F2B),
    error: Color(0xFFFF8A80),
    onError: Color(0xFF3B0A06),
    errorContainer: Color(0xFF5C1A14),
    onErrorContainer: Color(0xFFFFDAD5),
    surface: PiTvColors.background,
    onSurface: PiTvColors.text,
    onSurfaceVariant: PiTvColors.textMuted,
    surfaceContainerLowest: Color(0xFF0E1012),
    surfaceContainerLow: Color(0xFF181B1E),
    surfaceContainer: PiTvColors.surface,
    surfaceContainerHigh: PiTvColors.surfaceHigh,
    surfaceContainerHighest: PiTvColors.surfaceHighest,
    outline: PiTvColors.outline,
    outlineVariant: PiTvColors.outlineVariant,
    inverseSurface: PiTvColors.text,
    onInverseSurface: PiTvColors.background,
    inversePrimary: Color(0xFF0D7A6E),
    shadow: Colors.black,
    scrim: Colors.black,
    surfaceTint: Colors.transparent,
  );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    scaffoldBackgroundColor: PiTvColors.background,
  );
  final pill = WidgetStatePropertyAll<OutlinedBorder>(const StadiumBorder());
  return base.copyWith(
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    appBarTheme: const AppBarTheme(
      backgroundColor: PiTvColors.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: PiTvColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    cardTheme: const CardThemeData(
      color: PiTvColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: PiTvColors.surface,
      hintStyle: TextStyle(color: PiTvColors.textMuted),
      labelStyle: TextStyle(color: PiTvColors.textMuted),
      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)), borderSide: BorderSide(color: PiTvColors.outline)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          borderSide: BorderSide(color: PiTvColors.accent, width: 2)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: ButtonStyle(shape: pill)),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        shape: pill,
        side: const WidgetStatePropertyAll(BorderSide(color: PiTvColors.outline)),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? PiTvColors.textMuted.withValues(alpha: 0.5) : PiTvColors.text),
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: PiTvColors.accentDeep,
      thumbColor: PiTvColors.accentDeep,
      inactiveTrackColor: PiTvColors.accentContainer,
      overlayColor: PiTvColors.accent.withValues(alpha: 0.12),
      valueIndicatorColor: PiTvColors.accentDeep,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: PiTvColors.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: PiTvColors.accentContainer,
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? PiTvColors.accent : PiTvColors.textMuted)),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
          fontSize: 12,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? PiTvColors.text : PiTvColors.textMuted)),
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: PiTvColors.background,
      indicatorColor: PiTvColors.accentContainer,
      selectedIconTheme: IconThemeData(color: PiTvColors.accent),
      unselectedIconTheme: IconThemeData(color: PiTvColors.textMuted),
      selectedLabelTextStyle: TextStyle(color: PiTvColors.text, fontWeight: FontWeight.w600),
      unselectedLabelTextStyle: TextStyle(color: PiTvColors.textMuted, fontWeight: FontWeight.w500),
    ),
    dividerTheme: const DividerThemeData(color: PiTvColors.outlineVariant, space: 1, thickness: 1),
    listTileTheme: const ListTileThemeData(iconColor: PiTvColors.textMuted),
    bottomSheetTheme:
        const BottomSheetThemeData(backgroundColor: PiTvColors.surface, surfaceTintColor: Colors.transparent),
    dialogTheme: const DialogThemeData(backgroundColor: PiTvColors.surface, surfaceTintColor: Colors.transparent),
    popupMenuTheme: const PopupMenuThemeData(color: PiTvColors.surfaceHigh, surfaceTintColor: Colors.transparent),
  );
}

/// Secondary round control (skip, ±10 s, mute): dark charcoal, not teal.
ButtonStyle secondaryRoundStyle() => IconButton.styleFrom(
      backgroundColor: PiTvColors.surfaceHigh,
      foregroundColor: PiTvColors.text,
      disabledBackgroundColor: PiTvColors.surfaceHigh.withValues(alpha: 0.5),
      disabledForegroundColor: PiTvColors.textMuted.withValues(alpha: 0.5),
    );

/// Small rounded label, e.g. a resolution (`4K`, `1080p`) or `Playlist`.
class InfoBadge extends StatelessWidget {
  const InfoBadge(this.label, {super.key, this.accent = true, this.icon});
  final String label;
  final bool accent;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final fg = accent ? PiTvColors.accent : PiTvColors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: accent ? PiTvColors.accentContainer : PiTvColors.surfaceHigh,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 13, color: fg), const SizedBox(width: 3)],
        Text(label,
            style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 0.3, height: 1.25)),
      ]),
    );
  }
}

/// A resolution badge for a local file, or nothing when unknown.
class ResolutionBadge extends StatelessWidget {
  const ResolutionBadge(this.resolution, {super.key});
  final String? resolution;
  @override
  Widget build(BuildContext context) {
    final r = resolution;
    if (r == null) return const SizedBox.shrink();
    return Semantics(label: 'Resolution $r', child: InfoBadge(r, key: ValueKey('res-$r')));
  }
}
