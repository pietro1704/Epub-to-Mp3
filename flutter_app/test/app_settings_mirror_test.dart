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
    test('default backend URL is localhost:8000', () async {
      final s = await make();
      expect(s.backendURL, 'http://localhost:8000');
    });

    test('font size clamps to 0..4', () async {
      final s = await make();
      await s.setReaderFontSize(99);
      expect(s.readerFontSize, 4);
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
    });

    test('resolvedBaseURL drops trailing slash', () async {
      final s = await make();
      await s.setBackendURL('http://example.com/');
      expect(s.resolvedBaseURL.toString(), 'http://example.com');
    });

    test('readerCustomColors falls back when stored string is bad',
        () async {
      final s = await make({'readerCustomColors': 'garbage'});
      final c = s.readerCustomColors;
      expect(c.background, const RgbColor(1, 1, 1));
      expect(c.foreground, const RgbColor(0, 0, 0));
    });

    test('readerCustomColors roundtrips', () async {
      final s = await make();
      await s.setReaderCustomColors(
        const CustomReaderColors(RgbColor(0.1, 0.2, 0.3), RgbColor(0.4, 0.5, 0.6)),
      );
      final c = s.readerCustomColors;
      expect(c.background.r, closeTo(0.1, 1e-3));
      expect(c.foreground.b, closeTo(0.6, 1e-3));
    });

    test('sidecarURL preempts backendURL when useEmbeddedSidecar=true',
        () async {
      final s = await make();
      s.sidecarURL = Uri.parse('http://127.0.0.1:12345');
      await s.setUseEmbeddedSidecar(true);
      expect(s.resolvedBaseURL.toString(), 'http://127.0.0.1:12345');
    });
  });
}
