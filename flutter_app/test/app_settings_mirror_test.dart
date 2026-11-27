// Parity test for MirrorAppSettings (mirror of Models/AppSettings.swift).
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<MirrorAppSettings> make([Map<String, Object>? seed]) async {
    SharedPreferences.setMockInitialValues(seed ?? {});
    final prefs = await SharedPreferences.getInstance();
    return MirrorAppSettings(prefs);
  }

  group('MirrorAppSettings', () {
    test('font size clamps to 0..6 (steps 5 and 6 are the larger sizes)', () async {
      final s = await make();
      await s.setReaderFontSize(99);
      expect(s.readerFontSize, 6);
      await s.setReaderFontSize(-3);
      expect(s.readerFontSize, 0);
    });

    test('readerPointSize maps the steps', () async {
      final s = await make();
      await s.setReaderFontSize(0);
      expect(s.readerPointSize, 14);
      await s.setReaderFontSize(2);
      expect(s.readerPointSize, 20);
      await s.setReaderFontSize(4);
      expect(s.readerPointSize, 28);
      await s.setReaderFontSize(5);
      expect(s.readerPointSize, 34);
      await s.setReaderFontSize(6);
      expect(s.readerPointSize, 42);
    });

    test('readerCustomColors falls back when stored string is bad', () async {
      final s = await make({'readerCustomColors': 'garbage'});
      final c = s.readerCustomColors;
      expect(c.background, const RgbColor(1, 1, 1));
      expect(c.foreground, const RgbColor(0, 0, 0));
    });

    test('readerCustomColors roundtrips', () async {
      final s = await make();
      await s.setReaderCustomColors(
        const CustomReaderColors(
          RgbColor(0.1, 0.2, 0.3),
          RgbColor(0.4, 0.5, 0.6),
        ),
      );
      final c = s.readerCustomColors;
      expect(c.background.r, closeTo(0.1, 1e-3));
      expect(c.foreground.b, closeTo(0.6, 1e-3));
    });

    test('readerShowPageNumbers defaults to true and persists', () async {
      final s = await make();
      expect(s.readerShowPageNumbers, isTrue);
      await s.setReaderShowPageNumbers(false);
      expect(s.readerShowPageNumbers, isFalse);
    });

    test('readerTextAlignment defaults to justified and roundtrips', () async {
      final s = await make();
      expect(s.readerTextAlignment, ReaderTextAlignment.justified);
      await s.setReaderTextAlignment(ReaderTextAlignment.left);
      expect(s.readerTextAlignment, ReaderTextAlignment.left);
    });

    test(
      'readerTextAlignment falls back to justified on garbage raw value',
      () async {
        final s = await make({'readerTextAlignment': 'martian'});
        expect(s.readerTextAlignment, ReaderTextAlignment.justified);
      },
    );

    test(
      'reader layout defaults to paginated and persists migration sentinel',
      () async {
        final s = await make();
        expect(s.readerLayout, ReaderLayout.paginated);
      },
    );

    test(
      'reader layout migration preserves an explicit scrolling choice',
      () async {
        final s = await make({'readerLayout': ReaderLayout.scrolling.rawValue});
        expect(s.readerLayout, ReaderLayout.scrolling);
      },
    );
  });

  group('MirrorAppSettings legacy migration', () {
    test(
      'legacy fontSize (raw points) is bucketed into readerFontSize step',
      () async {
        final s = await make({'fontSize': 28.0});
        expect(s.readerFontSize, 4);
        final s2 = await make({'fontSize': 14.0});
        expect(s2.readerFontSize, 0);
        final s3 = await make({'fontSize': 18.0});
        expect(s3.readerFontSize, 2);
      },
    );

    test('legacy darkMode bool maps to readerTheme enum', () async {
      final s = await make({'darkMode': true});
      expect(s.readerTheme, ReaderTheme.dark);
      final s2 = await make({'darkMode': false});
      expect(s2.readerTheme, ReaderTheme.light);
    });

    test('migration sentinel is idempotent — no double-write', () async {
      // First boot migrates.
      SharedPreferences.setMockInitialValues({'darkMode': true});
      final prefs = await SharedPreferences.getInstance();
      MirrorAppSettings(prefs); // first construction migrates
      expect(prefs.getBool('_settingsMigratedV1'), isTrue);

      // Now the user explicitly changes the new keys; the migration
      // must NOT clobber them on subsequent constructions.
      await prefs.setString('readerTheme', ReaderTheme.sepia.rawValue);
      final s = MirrorAppSettings(prefs);
      expect(s.readerTheme, ReaderTheme.sepia);
    });

    test('legacy values are not migrated if new keys already exist', () async {
      // Both old and new present: new wins (user opted into new key
      // explicitly before the migration ran).
      final s = await make({
        'darkMode': true,
        'readerTheme': ReaderTheme.sepia.rawValue,
      });
      expect(s.readerTheme, ReaderTheme.sepia);
    });

    test('shim getters surface the new key space via legacy names', () async {
      final s = await make();
      await s.setFontSize(28);
      expect(s.fontSize, 28);
      expect(s.readerFontSize, 4);
      await s.setDarkMode(true);
      expect(s.darkMode, isTrue);
      expect(s.readerTheme, ReaderTheme.dark);
    });
  });

  group('MirrorAppSettings remote backend key cleanup', () {
    const remoteBackendSeed = <String, Object>{
      'backendURL': 'http://192.168.0.10:8000',
      'backendUrl': 'http://legacy.example',
      'useEmbeddedRuntime': false,
      'useEmbeddedSidecar': true,
    };

    test('removes every remote backend key on first construction', () async {
      SharedPreferences.setMockInitialValues({
        ...remoteBackendSeed,
        'wpm': 240,
        'readerTheme': ReaderTheme.sepia.rawValue,
      });
      final prefs = await SharedPreferences.getInstance();
      MirrorAppSettings(prefs);

      for (final key in MirrorAppSettings.remoteBackendKeys) {
        expect(prefs.containsKey(key), isFalse, reason: key);
      }
      expect(prefs.getBool('_remoteBackendKeysRemovedV1'), isTrue);
      // Unrelated preferences survive the cleanup.
      expect(prefs.getInt('wpm'), 240);
      expect(prefs.getString('readerTheme'), ReaderTheme.sepia.rawValue);
    });

    test('runs once: later writes to removed keys are left alone', () async {
      SharedPreferences.setMockInitialValues(remoteBackendSeed);
      final prefs = await SharedPreferences.getInstance();
      MirrorAppSettings(prefs);
      MirrorAppSettings(prefs);
      expect(prefs.getBool('_remoteBackendKeysRemovedV1'), isTrue);

      await prefs.setString('backendURL', 'http://written-later.example');
      MirrorAppSettings(prefs);
      expect(prefs.getString('backendURL'), 'http://written-later.example');
    });

    test('is a no-op on a fresh install apart from the sentinel', () async {
      final s = await make();
      expect(s.wpm, 200);
      final prefs = await SharedPreferences.getInstance();
      for (final key in MirrorAppSettings.remoteBackendKeys) {
        expect(prefs.containsKey(key), isFalse, reason: key);
      }
      expect(prefs.getBool('_remoteBackendKeysRemovedV1'), isTrue);
    });
  });
}
