import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_app/design_system/player_adaptive_layout.dart';
import 'package:flutter_app/design_system/adaptive_settings_layout.dart';
import 'package:flutter_app/models/app_settings.dart';

void main() {
  testWidgets(
    'phone and tablet use different player and settings arrangements',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final width in [390.0, 1200.0, 390.0]) {
        await tester.binding.setSurfaceSize(Size(width, 900));
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: PlayerAdaptiveLayout(
                header: Text('Player'),
                artwork: Center(child: Text('Cover')),
                controls: Text('Controls'),
              ),
            ),
          ),
        );
        expect(
          find.byKey(
            ValueKey(
              width >= 700 ? 'tablet-player-columns' : 'phone-player-stack',
            ),
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: AdaptiveSettingsLayout(
                narration: [Text('Voices')],
                preferences: [Text('Reader')],
              ),
            ),
          ),
        );
        expect(find.byType(ListView), findsNWidgets(width >= 960 ? 2 : 1));
        expect(tester.takeException(), isNull);
      }
    },
  );
  test(
    'seek intervals persist independently and reject unsupported values',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = MirrorAppSettings(prefs);
      expect(settings.seekForwardSeconds, 15);
      expect(settings.seekBackwardSeconds, 15);
      await settings.setSeekIntervals(forward: 60, backward: 30);
      await settings.setSeekIntervals(forward: 17);
      final restored = MirrorAppSettings(prefs);
      expect(restored.seekForwardSeconds, 60);
      expect(restored.seekBackwardSeconds, 30);
    },
  );
}
