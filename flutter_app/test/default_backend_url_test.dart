import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/models/app_settings.dart';

void main() {
  group('defaultBackendUrl', () {
    test('uses localhost for Android until a physical-device URL is configured', () {
      expect(
        defaultBackendUrl(platform: TargetPlatform.android),
        'http://localhost:8000',
      );
    });

    test('recognizes the emulator-only host explicitly', () {
      expect(androidEmulatorBackendUrl, 'http://10.0.2.2:8000');
    });

    test('uses localhost on desktop/iOS', () {
      for (final p in const [
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ]) {
        expect(defaultBackendUrl(platform: p), 'http://localhost:8000');
      }
    });
  });

  group('isValidBackendUrl', () {
    test('accepts HTTP(S) LAN and deployed origins', () {
      expect(isValidBackendUrl('http://192.168.0.120:8000'), isTrue);
      expect(isValidBackendUrl('https://example.com/api'), isTrue);
    });

    test('rejects empty, malformed, and non-HTTP URLs', () {
      expect(isValidBackendUrl(''), isFalse);
      expect(isValidBackendUrl('10.0.2.2:8000'), isFalse);
      expect(isValidBackendUrl('file:///tmp/backend'), isFalse);
    });
  });
}
