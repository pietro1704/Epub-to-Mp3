import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/models/app_settings.dart';

void main() {
  group('defaultBackendUrl', () {
    test('routes Android emulator to host loopback via 10.0.2.2', () {
      expect(
        defaultBackendUrl(platform: TargetPlatform.android),
        'http://10.0.2.2:8000',
      );
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
}
