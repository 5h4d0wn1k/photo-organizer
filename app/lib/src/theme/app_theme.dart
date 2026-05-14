import 'package:flutter/material.dart';

ThemeData buildAppTheme() {
  final seed = ColorScheme.fromSeed(
    seedColor: const Color(0xFF0F766E),
    brightness: Brightness.light,
  );

  return ThemeData(
    colorScheme: seed,
    scaffoldBackgroundColor: const Color(0xFFF6F8F7),
    useMaterial3: true,
    appBarTheme: const AppBarTheme(centerTitle: false),
    navigationRailTheme: NavigationRailThemeData(
      selectedIconTheme: IconThemeData(color: seed.primary),
      indicatorColor: seed.primaryContainer,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      margin: EdgeInsets.zero,
    ),
  );
}
