import 'package:flutter/material.dart';

class AppTheme {
  // --- Exact Color Palette ---
  static const Color bgColor = Color(0xFFF8F9FB);
  static const Color surfaceColor = Colors.white;
  static const Color primaryText = Color(0xFF1A1C1E);
  static const Color secondaryText = Color(0xFF4B5563);
  static const Color sectionLabel = Color(0xFF9CA3AF);
  static const Color strokeBorder = Color(0xFFE5E7EB);
  static const Color dividerColor = Color(0xFFE5E7EB);

  // Accent Colors
  static const Color brandRed = Color(0xFFCC0007);
  static const Color successGreen = Color(0xFF1A7A4A);

  // Warning/Notes Card Colors
  static const Color notesBg = Color(0xFFFFFBF0);
  static const Color notesStroke = Color(0xFFF5DFA0);
  static const Color notesHeader = Color(0xFFB07D10);
  static const Color notesText = Color(0xFF7A5A10);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: bgColor,
      colorScheme: ColorScheme.fromSeed(
        seedColor: brandRed,
        background: bgColor,
        surface: surfaceColor,
      ),

      // --- Cards ---
      cardTheme: const CardThemeData(
  color: Colors.white,
  elevation: 0,
  margin: EdgeInsets.zero,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(14)),
    side: BorderSide(color: Color(0xFFE5E7EB), width: 1),
  ),
),

      // --- Dividers ---
      dividerTheme: const DividerThemeData(
        color: dividerColor,
        thickness: 1,
        space: 28,
      ),

      // --- Text Styling ---
      textTheme: const TextTheme(
        headlineMedium: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: primaryText,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: primaryText,
        ),
        bodyLarge: TextStyle(
          fontSize: 15,
          color: secondaryText,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          color: secondaryText,
          height: 1.4,
        ),
        labelSmall: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: sectionLabel,
          letterSpacing: 0.8,
        ),
      ),

      // --- Input Decorations (Text Fields) ---
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF9FAFB),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        hintStyle: const TextStyle(color: sectionLabel, fontSize: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: strokeBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: strokeBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: brandRed, width: 1.5),
        ),
      ),

      // --- Primary Buttons ---
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: brandRed,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
      ),

      // --- Outlined Buttons ---
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: surfaceColor,
          foregroundColor: secondaryText,
          elevation: 0,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: strokeBorder, width: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }
}