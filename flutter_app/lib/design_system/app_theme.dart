import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Semantic Apple-style presentation shared by phone and tablet.
abstract final class AppTheme {
  static const expandedWidth = 720.0;
  static const panelWidth = 640.0;
  static const readingWidth = 840.0;

  /// WCAG 2.2 AA (and HIG) contrast: text 4.5:1, large text and UI glyphs 3:1, measured on the
  /// real pixels by `test/contrast_audit_test.dart`. The accent is darker than iOS's system blue in
  /// the light theme (system blue is 3.6:1 on the grouped background) and its label is black in the
  /// dark theme (white on system blue is 3.65:1). `highContrast` is the Increase Contrast variant.
  static ThemeData forBrightness(
    Brightness brightness, {
    bool highContrast = false,
  }) {
    final dark = brightness == Brightness.dark;
    final background = dark ? const Color(0xff000000) : const Color(0xfff2f2f7);
    final surface = dark ? const Color(0xff1c1c1e) : const Color(0xffffffff);
    final primary = highContrast
        ? (dark ? const Color(0xff6cb4ff) : const Color(0xff0040a0))
        : (dark ? const Color(0xff0a84ff) : const Color(0xff0062cc));
    final colors =
        ColorScheme.fromSeed(
          seedColor: const Color(0xff007aff),
          brightness: brightness,
          surface: surface,
          primary: primary,
        ).copyWith(
          onPrimary: dark ? const Color(0xff000000) : const Color(0xffffffff),
          // `outline` is used for secondary text as well as borders: keep it legible.
          outline: highContrast
              ? (dark ? const Color(0xffd1d1d6) : const Color(0xff3a3a3c))
              : (dark ? null : const Color(0xff6c6c70)),
          onSurface: highContrast
              ? (dark ? const Color(0xffffffff) : const Color(0xff000000))
              : null,
          onSurfaceVariant: highContrast
              ? (dark ? const Color(0xffe5e5ea) : const Color(0xff1c1c1e))
              : null,
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
      // The accent as a button label must keep 4.5:1: the default dark dialog surface is lighter
      // than the app surface (3.97:1 for the accent), so dialogs use the app surface.
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        constraints: const BoxConstraints(maxWidth: panelWidth),
      ),
    );
  }
}
