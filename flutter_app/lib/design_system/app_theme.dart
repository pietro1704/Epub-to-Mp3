import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Semantic Apple-style presentation shared by phone and tablet.
abstract final class AppTheme {
  static const expandedWidth = 720.0;
  static const panelWidth = 640.0;
  static const readingWidth = 840.0;

  static ThemeData forBrightness(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final background = dark ? const Color(0xff000000) : const Color(0xfff2f2f7);
    final surface = dark ? const Color(0xff1c1c1e) : const Color(0xffffffff);
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xff007aff),
      brightness: brightness,
      surface: surface,
      primary: dark ? const Color(0xff0a84ff) : const Color(0xff007aff),
    );
    return ThemeData(
      platform: TargetPlatform.iOS,
      brightness: brightness,
      colorScheme: colors,
      scaffoldBackgroundColor: background,
      cupertinoOverrideTheme: CupertinoThemeData(brightness: brightness),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: colors.onSurface,
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant,
        thickness: 0.5,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        constraints: const BoxConstraints(maxWidth: panelWidth),
        showDragHandle: true,
      ),
      dialogTheme: const DialogThemeData(
        constraints: BoxConstraints(maxWidth: panelWidth),
      ),
    );
  }
}
