import 'package:flutter/material.dart';

abstract final class AppColors {
  static const navy = Color(0xFF12243A);
  static const navySoft = Color(0xFF1D3855);
  static const blue = Color(0xFF2D6CDF);
  static const blueSoft = Color(0xFFE8F0FF);
  static const mint = Color(0xFF1BB394);
  static const mintSoft = Color(0xFFE4F8F2);
  static const amber = Color(0xFFE69B27);
  static const amberSoft = Color(0xFFFFF4DD);
  static const red = Color(0xFFD9535F);
  static const purple = Color(0xFF805AD5);
  static const redSoft = Color(0xFFFFE9EB);
  static const ink = Color(0xFF172033);
  static const slate = Color(0xFF64748B);
  static const line = Color(0xFFE5EAF1);
  static const canvas = Color(0xFFF6F8FB);
}

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.blue,
      brightness: brightness,
      primary: AppColors.blue,
      surface: isDark ? const Color(0xFF152133) : Colors.white,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor:
          isDark ? const Color(0xFF0F1928) : AppColors.canvas,
      fontFamily: 'Segoe UI',
    );
    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? const Color(0xFF0F1928) : AppColors.canvas,
        foregroundColor: isDark ? Colors.white : AppColors.ink,
        elevation: 0,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? const Color(0xFF2A3A50) : AppColors.line,
        space: 1,
        thickness: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF1C2B3F) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: isDark ? const Color(0xFF34465E) : AppColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: isDark ? const Color(0xFF34465E) : AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.blue, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.blue,
          foregroundColor: Colors.white,
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: isDark ? Colors.white : AppColors.ink,
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          side: BorderSide(color: isDark ? const Color(0xFF40536D) : AppColors.line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.blue,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: isDark ? const Color(0xFF111D2C) : Colors.white,
        selectedIconTheme: const IconThemeData(color: AppColors.blue),
        selectedLabelTextStyle: const TextStyle(
          color: AppColors.blue,
          fontWeight: FontWeight.w700,
        ),
        unselectedIconTheme: IconThemeData(
          color: isDark ? const Color(0xFF9EACC0) : AppColors.slate,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: isDark ? const Color(0xFF9EACC0) : AppColors.slate,
          fontWeight: FontWeight.w600,
        ),
        indicatorColor: isDark ? const Color(0xFF203A62) : AppColors.blueSoft,
        labelType: NavigationRailLabelType.none,
      ),
    );
  }
}
