import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/app_settings.dart';

class ReaderThemeColors {
  /// Resolve `.auto` to `.light` or `.dark` based on platform brightness.
  /// Accepts an optional [platformBrightness]; when null, queries the
  /// scheduler binding (works outside of widget tree).
  static ReaderTheme resolveAuto(
    ReaderTheme theme, {
    Brightness? platformBrightness,
  }) {
    if (theme != ReaderTheme.auto) return theme;
    final brightness =
        platformBrightness ??
        SchedulerBinding.instance.platformDispatcher.platformBrightness;
    return brightness == Brightness.dark ? ReaderTheme.dark : ReaderTheme.light;
  }

  static Color background(
    ReaderTheme theme, {
    CustomReaderColors? custom,
    Brightness? platformBrightness,
  }) {
    final resolved = resolveAuto(theme, platformBrightness: platformBrightness);
    switch (resolved) {
      case ReaderTheme.auto:
        // Already resolved above; fallback to light.
        return Colors.white;
      case ReaderTheme.light:
        return Colors.white;
      case ReaderTheme.sepia:
        return const Color.fromRGBO(0xF8, 0xF0, 0xE0, 1);
      case ReaderTheme.parchment:
        return const Color.fromRGBO(0xF4, 0xEC, 0xD8, 1);
      case ReaderTheme.paper:
        return const Color.fromRGBO(0xE8, 0xE2, 0xD5, 1);
      case ReaderTheme.dark:
        return const Color.fromRGBO(0x1C, 0x1C, 0x1E, 1);
      case ReaderTheme.black:
        return Colors.black;
      case ReaderTheme.custom:
        final c = custom ?? CustomReaderColors.fallback;
        return Color.fromRGBO(
          (c.background.r * 255).round(),
          (c.background.g * 255).round(),
          (c.background.b * 255).round(),
          1,
        );
    }
  }

  static Color foreground(
    ReaderTheme theme, {
    CustomReaderColors? custom,
    Brightness? platformBrightness,
  }) {
    final resolved = resolveAuto(theme, platformBrightness: platformBrightness);
    switch (resolved) {
      case ReaderTheme.auto:
        return Colors.black;
      case ReaderTheme.light:
        return Colors.black;
      case ReaderTheme.sepia:
        return const Color.fromRGBO(0x5B, 0x46, 0x36, 1);
      case ReaderTheme.parchment:
        return const Color.fromRGBO(0x3D, 0x2F, 0x1F, 1);
      case ReaderTheme.paper:
        return const Color.fromRGBO(0x2A, 0x25, 0x20, 1);
      case ReaderTheme.dark:
        return const Color.fromRGBO(0xE8, 0xE8, 0xE8, 1);
      case ReaderTheme.black:
        return const Color.fromRGBO(0xE0, 0xE0, 0xE0, 1);
      case ReaderTheme.custom:
        final c = custom ?? CustomReaderColors.fallback;
        return Color.fromRGBO(
          (c.foreground.r * 255).round(),
          (c.foreground.g * 255).round(),
          (c.foreground.b * 255).round(),
          1,
        );
    }
  }

  static Color previewColor(
    ReaderTheme theme, {
    Brightness? platformBrightness,
  }) {
    final resolved = resolveAuto(theme, platformBrightness: platformBrightness);
    switch (resolved) {
      case ReaderTheme.auto:
        return Colors.white;
      case ReaderTheme.light:
        return Colors.white;
      case ReaderTheme.sepia:
        return const Color.fromRGBO(247, 240, 224, 1);
      case ReaderTheme.parchment:
        return const Color.fromRGBO(245, 237, 217, 1);
      case ReaderTheme.paper:
        return const Color.fromRGBO(232, 227, 214, 1);
      case ReaderTheme.dark:
        return const Color.fromRGBO(28, 28, 31, 1);
      case ReaderTheme.black:
        return Colors.black;
      case ReaderTheme.custom:
        return Colors.grey;
    }
  }

  static Brightness brightness(
    ReaderTheme theme, {
    Brightness? platformBrightness,
  }) {
    final resolved = resolveAuto(theme, platformBrightness: platformBrightness);
    switch (resolved) {
      case ReaderTheme.auto:
      case ReaderTheme.light:
      case ReaderTheme.sepia:
      case ReaderTheme.parchment:
      case ReaderTheme.paper:
        return Brightness.light;
      case ReaderTheme.dark:
      case ReaderTheme.black:
      case ReaderTheme.custom:
        return Brightness.dark;
    }
  }
}
