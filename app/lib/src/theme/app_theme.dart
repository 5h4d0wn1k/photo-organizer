import 'package:flutter/material.dart';

class AppColors {
  const AppColors._();

  static const ink = Color(0xFF111827);
  static const slate = Color(0xFF334155);
  static const muted = Color(0xFF64748B);
  static const canvas = Color(0xFFFCF8FA);
  static const panel = Color(0xFFFFFFFF);
  static const panelMuted = Color(0xFFF6F3F5);
  static const border = Color(0xFFC6C6CD);
  static const navy = Color(0xFF0F172A);
  static const active = Color(0xFF0F766E);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFBA1A1A);
}

ThemeData buildAppTheme() {
  final seed = ColorScheme.fromSeed(
    seedColor: AppColors.navy,
    brightness: Brightness.light,
  ).copyWith(
    primary: AppColors.navy,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFDAE2FD),
    onPrimaryContainer: AppColors.navy,
    secondary: AppColors.slate,
    onSecondary: Colors.white,
    secondaryContainer: const Color(0xFFD5E3FD),
    onSecondaryContainer: const Color(0xFF0D1C2F),
    tertiary: AppColors.active,
    onTertiary: Colors.white,
    error: AppColors.danger,
    surface: AppColors.canvas,
    surfaceContainerLowest: AppColors.panel,
    surfaceContainerLow: AppColors.panelMuted,
    surfaceContainer: const Color(0xFFF0EDEF),
    surfaceContainerHigh: const Color(0xFFEAE7E9),
    surfaceContainerHighest: const Color(0xFFE4E2E4),
    onSurface: AppColors.ink,
    onSurfaceVariant: const Color(0xFF45464D),
    outline: const Color(0xFF76777D),
    outlineVariant: AppColors.border,
  );

  return ThemeData(
    colorScheme: seed,
    scaffoldBackgroundColor: AppColors.canvas,
    fontFamily: 'Inter',
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: AppColors.canvas,
      foregroundColor: AppColors.ink,
      titleTextStyle: TextStyle(
        color: AppColors.ink,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      selectedIconTheme: IconThemeData(color: seed.primary),
      indicatorColor: seed.primaryContainer,
      backgroundColor: AppColors.panel,
      labelType: NavigationRailLabelType.none,
      minExtendedWidth: 220,
      unselectedLabelTextStyle: const TextStyle(color: AppColors.muted),
      selectedLabelTextStyle: const TextStyle(
        color: AppColors.ink,
        fontWeight: FontWeight.w700,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.panel,
      indicatorColor: seed.primaryContainer,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? AppColors.ink : AppColors.muted,
        );
      }),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.panel,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.navy, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        minimumSize: const Size(48, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.navy,
        minimumSize: const Size(48, 44),
        side: const BorderSide(color: AppColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.navy,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: AppColors.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.border),
      ),
      margin: EdgeInsets.zero,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.panel,
      selectedColor: seed.primaryContainer,
      side: const BorderSide(color: AppColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        height: 1.2,
        color: AppColors.ink,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        height: 1.2,
        color: AppColors.ink,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        height: 1.3,
        color: AppColors.ink,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        height: 1.35,
        color: AppColors.ink,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        height: 1.35,
        color: AppColors.ink,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.55,
        color: AppColors.ink,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.5,
        color: AppColors.ink,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.4,
        color: AppColors.muted,
      ),
      labelLarge: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        height: 1.2,
        color: AppColors.ink,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        height: 1.2,
        color: AppColors.muted,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        height: 1.2,
        color: AppColors.muted,
      ),
    ),
  );
}
