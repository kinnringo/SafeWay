import 'package:flutter/material.dart';

class AppColors {
  static const Color primaryNavy = Color(0xFF1E3A8A);
  static const Color emeraldGreen = Color(0xFF10B981);
  static const Color blueAccent = Color(0xFF2563EB);
  static const Color blueAccentLight = Color(0xFF3B82F6);
  static const Color white = Colors.white;
}

class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.primaryNavy,
        primary: AppColors.primaryNavy,
        secondary: AppColors.emeraldGreen,
      ),
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.primaryNavy,
        foregroundColor: AppColors.white,
        elevation: 4,
      ),
    );
  }
}
