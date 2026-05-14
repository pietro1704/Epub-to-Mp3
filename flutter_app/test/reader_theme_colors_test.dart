import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/views/reader_theme_colors.dart';

void main() {
  group('ReaderThemeColors', () {
    test('light theme has white background and black foreground', () {
      final bg = ReaderThemeColors.background(ReaderTheme.light);
      final fg = ReaderThemeColors.foreground(ReaderTheme.light);
      expect(bg, Colors.white);
      expect(fg, Colors.black);
    });

    test('dark theme has dark background and light foreground', () {
      final bg = ReaderThemeColors.background(ReaderTheme.dark);
      final fg = ReaderThemeColors.foreground(ReaderTheme.dark);
      expect(bg.value, const Color.fromRGBO(0x1C, 0x1C, 0x1E, 1).value);
      expect(fg.value, const Color.fromRGBO(0xE8, 0xE8, 0xE8, 1).value);
    });

    test('black theme uses true OLED black', () {
      final bg = ReaderThemeColors.background(ReaderTheme.black);
      expect(bg, Colors.black);
    });

    test('sepia theme has warm tones', () {
      final bg = ReaderThemeColors.background(ReaderTheme.sepia);
      // Color.red returns 0-255 int
      expect(bg.red, greaterThan(230));
      expect(bg.green, greaterThan(220));
    });

    test('custom theme uses provided colors', () {
      final custom = CustomReaderColors(
        const RgbColor(0.5, 0.3, 0.1),
        const RgbColor(0.9, 0.8, 0.7),
      );
      final bg = ReaderThemeColors.background(ReaderTheme.custom, custom: custom);
      final fg = ReaderThemeColors.foreground(ReaderTheme.custom, custom: custom);
      expect(bg.red, closeTo(128, 2));
      expect(fg.red, closeTo(230, 2));
    });

    test('brightness returns light for warm themes, dark for dark themes', () {
      expect(ReaderThemeColors.brightness(ReaderTheme.light), Brightness.light);
      expect(ReaderThemeColors.brightness(ReaderTheme.sepia), Brightness.light);
      expect(ReaderThemeColors.brightness(ReaderTheme.parchment), Brightness.light);
      expect(ReaderThemeColors.brightness(ReaderTheme.paper), Brightness.light);
      expect(ReaderThemeColors.brightness(ReaderTheme.dark), Brightness.dark);
      expect(ReaderThemeColors.brightness(ReaderTheme.black), Brightness.dark);
    });

    test('all non-custom themes produce valid previewColor', () {
      for (final theme in ReaderTheme.values) {
        final color = ReaderThemeColors.previewColor(theme);
        expect(color, isA<Color>());
      }
    });
  });
}
