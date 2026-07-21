import 'package:flutter/material.dart';

/// Centralized dark sci-fi theme for the RIDEN Power Supply UI.
class AppTheme {
  AppTheme._();

  /// Global navigator key for showing dialogs from widget callbacks.
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  // ── Core palette ──────────────────────────────────────────────
  static const Color bgDarkest = Color(0xFF070915);
  static const Color bgPanel = Color(0xFF0C0F1A);
  static const Color bgCard = Color(0xFF171C21);
  static const Color bgInput = Color(0xFF0E1218);
  static const Color borderSubtle = Color(0xFF2A2F3E);

  // ── Semantic colours ──────────────────────────────────────────
  static const Color voltGreen = Color(0xFF00E676);
  static const Color currentBlue = Color(0xFF40C4FF);
  static const Color powerPurple = Color(0xFFB388FF);
  static const Color setpointYellow = Color(0xFFFFD740);
  static const Color protectCyan = Color(0xFF00E5FF);
  static const Color warningOrange = Color(0xFFFFAB40);
  static const Color errorRed = Color(0xFFFF5252);
  static const Color textPrimary = Color(0xFFE0E0E0);
  static const Color textSecondary = Color(0xFF90A4AE);
  static const Color textDim = Color(0xFF546E7A);

  // ── Text styles ───────────────────────────────────────────────
  static const String _fontMono = 'JetBrainsMono Nerd Font Mono';
  static const String _fontSans = 'Noto Sans CJK SC';

  /// Large digital readouts (V / A / W / energy / setpoint values).
  static TextStyle get digitalValue => const TextStyle(
        fontFamily: _fontMono,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
      );

  /// Section labels, headers, chip text.
  static TextStyle get digitalLabel => const TextStyle(
        fontFamily: _fontSans,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
        color: textSecondary,
      );

  /// Small info / axis / status text.
  static TextStyle get bodyMono => const TextStyle(
        fontFamily: _fontSans,
        fontSize: 13,
        color: textSecondary,
      );

  // ── ThemeData ─────────────────────────────────────────────────
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDarkest,
      colorScheme: const ColorScheme.dark(
        surface: bgPanel,
        primary: voltGreen,
        secondary: currentBlue,
        tertiary: powerPurple,
      ),
      cardTheme: CardThemeData(
        color: bgCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: bgInput,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: setpointYellow, width: 1.5),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: borderSubtle,
        thickness: 0.5,
        space: 1,
      ),
    );
  }
}
