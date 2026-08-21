import 'package:flutter/material.dart';

/// Tandav Studio design system: near-black, gold and yellow.
class TandavColors {
  static const background = Color(0xFF0B0B0E);
  static const surface = Color(0xFF15151B);
  static const surfaceLight = Color(0xFF1E1E26);
  static const surfaceBorder = Color(0xFF2A2A33);

  static const gold = Color(0xFFD4AF37);
  static const goldLight = Color(0xFFE8C95C);
  static const yellow = Color(0xFFFFC933);
  static const goldGradientStart = Color(0xFFF2D264);
  static const goldGradientEnd = Color(0xFFB8860B);

  static const textPrimary = Color(0xFFF7F3E8);
  static const textSecondary = Color(0xFFB3AD9E);
  static const textMuted = Color(0xFF7C7769);

  static const success = Color(0xFF7CB342);
  static const danger = Color(0xFFE57373);
  static const info = Color(0xFF4FC3F7);
}

class TandavTheme {
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: TandavColors.background,
      colorScheme: const ColorScheme.dark(
        primary: TandavColors.gold,
        onPrimary: Color(0xFF141414),
        secondary: TandavColors.yellow,
        onSecondary: Color(0xFF141414),
        surface: TandavColors.surface,
        onSurface: TandavColors.textPrimary,
        error: TandavColors.danger,
        onError: Colors.black,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: TandavColors.background,
        foregroundColor: TandavColors.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: TandavColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
      cardTheme: CardThemeData(
        color: TandavColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: TandavColors.surfaceBorder),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: TandavColors.surfaceLight,
        hintStyle: const TextStyle(color: TandavColors.textMuted),
        labelStyle: const TextStyle(color: TandavColors.textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: TandavColors.surfaceBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: TandavColors.surfaceBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: TandavColors.gold, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: TandavColors.danger),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: TandavColors.gold,
          foregroundColor: const Color(0xFF141414),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: TandavColors.gold,
          side: const BorderSide(color: TandavColors.gold),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: TandavColors.yellow),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: TandavColors.surfaceLight,
        selectedColor: TandavColors.gold.withValues(alpha: 0.25),
        side: const BorderSide(color: TandavColors.surfaceBorder),
        labelStyle: const TextStyle(
          color: TandavColors.textPrimary,
          fontSize: 12.5,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerTheme: const DividerThemeData(color: TandavColors.surfaceBorder),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: TandavColors.surface,
        selectedItemColor: TandavColors.gold,
        unselectedItemColor: TandavColors.textMuted,
        type: BottomNavigationBarType.fixed,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: TandavColors.surfaceLight,
        contentTextStyle: const TextStyle(color: TandavColors.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: TandavColors.surface,
        headerBackgroundColor: TandavColors.surfaceLight,
        headerForegroundColor: TandavColors.gold,
        surfaceTintColor: TandavColors.surface,
        dayForegroundColor: const WidgetStatePropertyAll(
          TandavColors.textPrimary,
        ),
        dayBackgroundColor: const WidgetStatePropertyAll(Colors.transparent),
        todayForegroundColor: const WidgetStatePropertyAll(TandavColors.gold),
        todayBackgroundColor: const WidgetStatePropertyAll(Color(0x33D4AF37)),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: TandavColors.gold,
        linearTrackColor: TandavColors.surfaceBorder,
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: TandavColors.gold,
        selectionColor: Color(0x44D4AF37),
      ),
    );
  }
}

class GoldGradient {
  static const colors = [
    TandavColors.goldGradientStart,
    TandavColors.goldGradientEnd,
  ];

  static LinearGradient get linear => const LinearGradient(
    colors: colors,
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
