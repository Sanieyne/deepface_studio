import 'package:flutter/material.dart';

/// Lumina AI design tokens, sampled to match the reference mockups:
/// deep obsidian dark theme <-> warm cream frosted light theme.
class LuminaColors {
  static const violet = Color(0xFF8A42D5);
  static const purple = Color(0xFF9C27B0);
  static const cyan = Color(0xFF35B6C4);
  static const amber = Color(0xFFF5B942);
  static const infoBlue = Color(0xFF3368A8);

  // Primary action gradient: deep crimson into vibrant coral red.
  static const primaryStart = Color(0xFFD32F2F);
  static const primaryEnd = Color(0xFFFF5252);
  static const primaryText = Color(0xFF7F1D1D);
  static const primaryGlow = Color(0xFFE53935);
  static const primaryGradient = LinearGradient(
    colors: [primaryStart, primaryEnd],
  );

  // Dark (obsidian)
  static const darkBg = Color(0xFF14181F);
  static const darkSurface = Color(0xFF232B37);
  static const darkCard = Color(0xFF2A3340);
  static const darkBorder = Color(0x1AFFFFFF); // white 10%
  static const darkText = Color(0xFFEEF2F4);
  static const darkMuted = Color(0xFF9AA6AE);

  // Light (cream frosted)
  static const lightBg = Color(0xFFE9E7E1);
  static const lightSurface = Color(0xFFF4F2EC);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightBorder = Color(0x12000000); // black ~7%
  static const lightText = Color(0xFF1B2A2C);
  static const lightMuted = Color(0xFF6B7474);

  static const cardRadius = 14.0;
  static const pillRadius = 999.0;
}

class LuminaTheme {
  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: LuminaColors.violet,
      brightness: Brightness.light,
    ).copyWith(
      surface: LuminaColors.lightSurface,
      surfaceContainerHighest: LuminaColors.lightCard,
    );
    return ThemeData(useMaterial3: true, colorScheme: scheme).copyWith(
      scaffoldBackgroundColor: LuminaColors.lightBg,
      dividerColor: LuminaColors.lightBorder,
    );
  }

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: LuminaColors.violet,
      brightness: Brightness.dark,
    ).copyWith(
      surface: LuminaColors.darkSurface,
      surfaceContainerHighest: LuminaColors.darkCard,
    );
    return ThemeData(useMaterial3: true, colorScheme: scheme).copyWith(
      scaffoldBackgroundColor: LuminaColors.darkBg,
      dividerColor: LuminaColors.darkBorder,
    );
  }

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;
}
