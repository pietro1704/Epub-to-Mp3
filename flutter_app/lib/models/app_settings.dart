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

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_app/services/offline_cache_eviction.dart';

/// Default backend URL per platform. Android emulator routes host
/// `localhost` to `10.0.2.2`; all other platforms reach the host
/// loopback directly. Visible for testing so it can be exercised
/// without spinning a full Flutter binding.
@visibleForTesting
String defaultBackendUrl({TargetPlatform? platform}) {
  final p = platform ?? defaultTargetPlatform;
  if (!kIsWeb && p == TargetPlatform.android) {
    return 'http://10.0.2.2:8000';
  }
  return 'http://localhost:8000';
}

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

enum ReaderTheme { auto, light, sepia, parchment, paper, dark, black, custom }

extension ReaderThemeX on ReaderTheme {
  String get rawValue => name;
  String get displayName => switch (this) {
        ReaderTheme.auto => 'Auto',
        ReaderTheme.light => 'Light',
        ReaderTheme.sepia => 'Sepia',
        ReaderTheme.parchment => 'Parchment',
        ReaderTheme.paper => 'Paper',
        ReaderTheme.dark => 'Dark',
        ReaderTheme.black => 'Black',
        ReaderTheme.custom => 'Custom',
      };
  static ReaderTheme fromRaw(String? s) => ReaderTheme.values
      .firstWhere((e) => e.rawValue == s, orElse: () => ReaderTheme.auto);
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

/// Horizontal alignment for reader body text. The default `.justified`
/// matches Apple Books and the typographic norm for printed prose;
/// `.left` (ragged-right) suits screens / users who dislike the
/// wide-word-spacing artefacts justification can produce on narrow
/// columns. Mirror of iOS `ReaderTextAlignment`.
enum ReaderTextAlignment { justified, left }

extension ReaderTextAlignmentX on ReaderTextAlignment {
  String get rawValue => name;
  String get displayName => switch (this) {
        ReaderTextAlignment.justified => 'Justified',
        ReaderTextAlignment.left => 'Left',
      };
  static ReaderTextAlignment fromRaw(String? s) =>
      ReaderTextAlignment.values.firstWhere(
        (e) => e.rawValue == s,
        orElse: () => ReaderTextAlignment.justified,
      );
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
///
/// Legacy keys from the old `state/providers.dart` AppSettings
/// (`backendUrl`, `wpm`, `audioRate`, `fontSize`, `darkMode`) are
/// migrated to the new key space on first construction via
/// [migrateLegacyKeysIfNeeded]. Idempotent — sets a sentinel
/// `_settingsMigratedV1` flag so the migration runs at most once.
class MirrorAppSettings {
  MirrorAppSettings(this._prefs) {
    migrateLegacyKeysIfNeeded();
  }

  final SharedPreferences _prefs;

  /// One-shot migration from the legacy `state/providers.dart` AppSettings
  /// key space. Runs only if `_settingsMigratedV1` isn't set yet.
  ///
  /// Mapping:
  ///   backendUrl → backendURL   (camelCase change)
  ///   wpm        → wpm          (kept; new key for player WPM)
  ///   audioRate  → audioRate    (kept; new key for playback speed)
  ///   fontSize   → readerFontSize (was raw point size; bucket into 0..4 step)
  ///   darkMode   → readerTheme   (bool → enum: true ⇒ dark, false ⇒ light)
  ///
  /// Old keys are NOT deleted — keeps a one-shot rollback path. Future
  /// versions can drop the legacy reads + delete the keys.
  void migrateLegacyKeysIfNeeded() {
    if (_prefs.getBool('_settingsMigratedV1') == true) return;

    final legacyBackend = _prefs.getString('backendUrl');
    if (legacyBackend != null && _prefs.getString('backendURL') == null) {
      _prefs.setString('backendURL', legacyBackend);
    }

    final legacyFontSize = _prefs.getDouble('fontSize');
    if (legacyFontSize != null && _prefs.getInt('readerFontSize') == null) {
      // Bucket raw point size into the 0..4 step. The Swift side keys
      // off step, not point size, so we coerce.
      final pt = legacyFontSize;
      final step = pt <= 14 ? 0
          : pt <= 17 ? 1
          : pt <= 20 ? 2
          : pt <= 24 ? 3
          : 4;
      _prefs.setInt('readerFontSize', step);
    }

    final legacyDarkMode = _prefs.getBool('darkMode');
    if (legacyDarkMode != null && _prefs.getString('readerTheme') == null) {
      _prefs.setString(
        'readerTheme',
        legacyDarkMode ? ReaderTheme.dark.rawValue : ReaderTheme.light.rawValue,
      );
    }
    // `wpm` and `audioRate` keep the same key; no rename needed.

    _prefs.setBool('_settingsMigratedV1', true);
  }

  // backendURL ----------------------------------------------------------
  String get backendURL =>
      _prefs.getString('backendURL') ?? defaultBackendUrl();
  Future<void> setBackendURL(String v) => _prefs.setString('backendURL', v);

  // Legacy compatibility — `wpm` and `audioRate` were on the old
  // AppSettings; Swift exposes them on the AudioPlayer/SyncEngine
  // layer instead, but we surface them here so the existing JobsList
  // UI keeps working after the provider swap.
  int get wpm => _prefs.getInt('wpm') ?? 200;
  Future<void> setWpm(int v) => _prefs.setInt('wpm', v);

  double get audioRate => _prefs.getDouble('audioRate') ?? 1.0;
  Future<void> setAudioRate(double v) => _prefs.setDouble('audioRate', v);

  // Legacy double-valued font size in points, used by the existing
  // settings UI's slider. Backed by the same `readerFontSize` step,
  // bidirectionally converted to/from the integer step bucket.
  double get fontSize => readerPointSize;
  Future<void> setFontSize(double pt) async {
    final step = pt <= 14 ? 0
        : pt <= 17 ? 1
        : pt <= 20 ? 2
        : pt <= 24 ? 3
        : 4;
    await setReaderFontSize(step);
  }

  // Legacy boolean dark-mode toggle. Maps to ReaderTheme.dark / .light.
  bool get darkMode => readerTheme == ReaderTheme.dark;
  Future<void> setDarkMode(bool v) =>
      setReaderTheme(v ? ReaderTheme.dark : ReaderTheme.light);

  // Legacy lowercase alias used by call sites that haven't migrated to
  // the camelCase Swift-mirror name yet.
  String get backendUrl => backendURL;

  // Sidecar (macOS only on Swift; on Flutter only the Linux/Windows
  // desktop builds spin up a sidecar — see PythonBridge).
  Uri? sidecarURL;
  bool get useEmbeddedSidecar => _prefs.getBool('useEmbeddedSidecar') ?? true;
  Future<void> setUseEmbeddedSidecar(bool v) =>
      _prefs.setBool('useEmbeddedSidecar', v);

  bool get useEmbeddedRuntime => _prefs.getBool('useEmbeddedRuntime') ?? true;
  Future<void> setUseEmbeddedRuntime(bool v) =>
      _prefs.setBool('useEmbeddedRuntime', v);

  // Reader appearance ---------------------------------------------------
  int get readerFontSize {
    final v = _prefs.getInt('readerFontSize') ?? 3;
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

  /// Whether the "n / total" page indicator renders at the bottom of
  /// each paginated page. Default `true`. When off the indicator is
  /// hidden AND the paginator's body budget reclaims the footer
  /// reserved strip so the chapter uses the freed space.
  bool get readerShowPageNumbers =>
      _prefs.getBool('readerShowPageNumbers') ?? true;
  Future<void> setReaderShowPageNumbers(bool v) =>
      _prefs.setBool('readerShowPageNumbers', v);

  /// Horizontal alignment for reader body text. Default `.justified`
  /// matches Apple Books and printed-book typography. Forced on every
  /// paragraph, overriding the EPUB's own CSS alignment declaration.
  ReaderTextAlignment get readerTextAlignment =>
      ReaderTextAlignmentX.fromRaw(_prefs.getString('readerTextAlignment'));
  Future<void> setReaderTextAlignment(ReaderTextAlignment v) =>
      _prefs.setString('readerTextAlignment', v.rawValue);

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

  // Offline cache budget ------------------------------------------------

  /// Maximum on-device audiobook cache budget (bytes). Default 2 GB.
  int get offlineCacheBudgetBytes =>
      _prefs.getInt('offlineCacheBudgetBytes') ?? kDefaultOfflineCacheBudgetBytes;
  Future<void> setOfflineCacheBudgetBytes(int v) =>
      _prefs.setInt('offlineCacheBudgetBytes', v);

  /// Maximum age (seconds) before a cached audiobook is evicted. Default 24 h.
  int get offlineCacheTTLSeconds =>
      _prefs.getInt('offlineCacheTTLSeconds') ?? kDefaultOfflineCacheTTLSeconds;
  Future<void> setOfflineCacheTTLSeconds(int v) =>
      _prefs.setInt('offlineCacheTTLSeconds', v);

  // Reading position persistence ----------------------------------------
  int savedChapterIndex(String bookId) =>
      _prefs.getInt('readPos_ch_$bookId') ?? 0;
  Future<void> saveChapterIndex(int index, String bookId) =>
      _prefs.setInt('readPos_ch_$bookId', index);

  int savedPageIndex(String bookId) =>
      _prefs.getInt('readPos_pg_$bookId') ?? 0;
  Future<void> savePageIndex(int index, String bookId) =>
      _prefs.setInt('readPos_pg_$bookId', index);

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
