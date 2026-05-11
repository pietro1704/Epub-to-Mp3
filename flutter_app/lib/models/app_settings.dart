// Mirror of ios/EpubToMp3/EpubToMp3/Models/AppSettings.swift @ b7c962a
//
// Persisted user preferences for the reader / player. The Swift side
// uses `@AppStorage`; here we wrap `SharedPreferences` behind a tiny
// API that exposes the same keys + clamping rules. Pure-Dart so it can
// be unit-tested without a Flutter binding.
//
// NOTE: a separate `AppSettings` already lives in `state/providers.dart`
// for the existing JobsList UI. Keeping this file as the iOS-parity
// mirror — once we wire the new reader/player views, switch the
// providers over to consume `MirrorAppSettings`.

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

enum ReaderFontFamily { serif, sans, mono }

extension ReaderFontFamilyX on ReaderFontFamily {
  String get rawValue => name;
  String get displayName => switch (this) {
        ReaderFontFamily.serif => 'Serif',
        ReaderFontFamily.sans => 'Sans',
        ReaderFontFamily.mono => 'Mono',
      };
  static ReaderFontFamily fromRaw(String? s) => ReaderFontFamily.values
      .firstWhere((e) => e.rawValue == s, orElse: () => ReaderFontFamily.serif);
}

enum ReaderTheme { light, sepia, parchment, paper, dark, black, custom }

extension ReaderThemeX on ReaderTheme {
  String get rawValue => name;
  String get displayName => switch (this) {
        ReaderTheme.light => 'Light',
        ReaderTheme.sepia => 'Sepia',
        ReaderTheme.parchment => 'Parchment',
        ReaderTheme.paper => 'Paper',
        ReaderTheme.dark => 'Dark',
        ReaderTheme.black => 'Black',
        ReaderTheme.custom => 'Custom',
      };
  static ReaderTheme fromRaw(String? s) => ReaderTheme.values
      .firstWhere((e) => e.rawValue == s, orElse: () => ReaderTheme.light);
}

enum ReaderLayout { scrolling, paginated }

extension ReaderLayoutX on ReaderLayout {
  String get rawValue => name;
  String get displayName => switch (this) {
        ReaderLayout.scrolling => 'Scrolling',
        ReaderLayout.paginated => 'Paginated',
      };
  static ReaderLayout fromRaw(String? s) => ReaderLayout.values
      .firstWhere((e) => e.rawValue == s, orElse: () => ReaderLayout.scrolling);
}

/// RGB triple in 0..1 range.
class RgbColor {
  final double r;
  final double g;
  final double b;
  const RgbColor(this.r, this.g, this.b);

  @override
  bool operator ==(Object other) =>
      other is RgbColor && other.r == r && other.g == g && other.b == b;
  @override
  int get hashCode => Object.hash(r, g, b);
}

class CustomReaderColors {
  final RgbColor background;
  final RgbColor foreground;
  const CustomReaderColors(this.background, this.foreground);

  static const fallback = CustomReaderColors(
    RgbColor(1, 1, 1),
    RgbColor(0, 0, 0),
  );
}

/// Reader / backend settings. Same key names as the Swift @AppStorage
/// wrappers so the iOS and Flutter clients could share a settings file
/// if a Codable bridge is ever needed (today they do not).
class MirrorAppSettings {
  MirrorAppSettings(this._prefs);

  final SharedPreferences _prefs;

  // backendURL ----------------------------------------------------------
  String get backendURL =>
      _prefs.getString('backendURL') ?? 'http://localhost:8000';
  Future<void> setBackendURL(String v) => _prefs.setString('backendURL', v);

  // Sidecar (macOS only on Swift; on Flutter only the Linux/Windows
  // desktop builds spin up a sidecar — see PythonBridge).
  Uri? sidecarURL;
  bool get useEmbeddedSidecar => _prefs.getBool('useEmbeddedSidecar') ?? true;
  Future<void> setUseEmbeddedSidecar(bool v) =>
      _prefs.setBool('useEmbeddedSidecar', v);

  // Reader appearance ---------------------------------------------------
  int get readerFontSize {
    final v = _prefs.getInt('readerFontSize') ?? 2;
    return v.clamp(0, 4);
  }

  Future<void> setReaderFontSize(int v) =>
      _prefs.setInt('readerFontSize', v.clamp(0, 4));

  ReaderFontFamily get readerFontFamily =>
      ReaderFontFamilyX.fromRaw(_prefs.getString('readerFontFamily'));
  Future<void> setReaderFontFamily(ReaderFontFamily v) =>
      _prefs.setString('readerFontFamily', v.rawValue);

  ReaderTheme get readerTheme =>
      ReaderThemeX.fromRaw(_prefs.getString('readerTheme'));
  Future<void> setReaderTheme(ReaderTheme v) =>
      _prefs.setString('readerTheme', v.rawValue);

  bool get readerAutoScroll => _prefs.getBool('readerAutoScroll') ?? true;
  Future<void> setReaderAutoScroll(bool v) =>
      _prefs.setBool('readerAutoScroll', v);

  ReaderLayout get readerLayout =>
      ReaderLayoutX.fromRaw(_prefs.getString('readerLayout'));
  Future<void> setReaderLayout(ReaderLayout v) =>
      _prefs.setString('readerLayout', v.rawValue);

  double get readerLineSpacing {
    final v = _prefs.getDouble('readerLineSpacing') ?? 6;
    return v.clamp(0, 16);
  }

  Future<void> setReaderLineSpacing(double v) =>
      _prefs.setDouble('readerLineSpacing', v.clamp(0, 16));

  double get readerMargin {
    final v = _prefs.getDouble('readerMargin') ?? 24;
    return v.clamp(8, 80);
  }

  Future<void> setReaderMargin(double v) =>
      _prefs.setDouble('readerMargin', v.clamp(8, 80));

  double get readerColumnWidth {
    final v = _prefs.getDouble('readerColumnWidth') ?? 720;
    return v.clamp(420, 960);
  }

  Future<void> setReaderColumnWidth(double v) =>
      _prefs.setDouble('readerColumnWidth', v.clamp(420, 960));

  CustomReaderColors get readerCustomColors {
    final raw = _prefs.getString('readerCustomColors') ?? '1,1,1,0,0,0';
    final parts =
        raw.split(',').map((s) => double.tryParse(s.trim())).toList();
    if (parts.length != 6 || parts.any((e) => e == null)) {
      return CustomReaderColors.fallback;
    }
    final p = parts.cast<double>();
    return CustomReaderColors(
      RgbColor(p[0], p[1], p[2]),
      RgbColor(p[3], p[4], p[5]),
    );
  }

  Future<void> setReaderCustomColors(CustomReaderColors c) {
    String f(double d) => d.toStringAsFixed(4);
    final s = [
      c.background.r,
      c.background.g,
      c.background.b,
      c.foreground.r,
      c.foreground.g,
      c.foreground.b,
    ].map(f).join(',');
    return _prefs.setString('readerCustomColors', s);
  }

  /// Best-effort base URL; nil if the user typed garbage.
  Uri? get resolvedBaseURL {
    if (useEmbeddedSidecar && sidecarURL != null) return sidecarURL;
    final trimmed = backendURL.trim();
    if (trimmed.isEmpty) return null;
    final cleaned = trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
    return Uri.tryParse(cleaned);
  }

  /// Resolved point size for the current 0..4 step.
  double get readerPointSize {
    switch (readerFontSize) {
      case 0:
        return 14;
      case 1:
        return 17;
      case 3:
        return 24;
      case 4:
        return 28;
      case 2:
      default:
        return 20;
    }
  }
}
