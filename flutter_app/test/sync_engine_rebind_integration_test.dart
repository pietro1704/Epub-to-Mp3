import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/state/providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('syncEngineProvider rebinds on settings change', () {
    test(
        'changing wpm disposes the previous SyncEngine and hands out a fresh '
        'instance — the slice 30 precondition', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
      ]);
      addTearDown(container.dispose);

      final engineA = container.read(syncEngineProvider('job-1'));
      // Engine carries the initial WPM setting.
      final initialWpm = engineA.wpm;

      // Mutate the watched setting. SettingsNotifier's wpm setter triggers
      // a settingsProvider notification which invalidates syncEngineProvider.
      container.read(settingsProvider.notifier).setWpm(initialWpm + 50);

      // After the listener fires, reading the family entry must return a
      // new SyncEngine instance configured with the new WPM.
      await Future<void>.delayed(Duration.zero);
      final engineB = container.read(syncEngineProvider('job-1'));

      expect(identical(engineA, engineB), isFalse,
          reason:
              'syncEngineProvider must hand out a new instance when its '
              'watched dependency (settings.wpm) changes');
      expect(engineB.wpm, initialWpm + 50);
    });

    test('different jobIds always get distinct engine instances', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
      ]);
      addTearDown(container.dispose);

      final engineForJobA = container.read(syncEngineProvider('job-a'));
      final engineForJobB = container.read(syncEngineProvider('job-b'));
      expect(identical(engineForJobA, engineForJobB), isFalse,
          reason: 'family providers are keyed by jobId');
    });

    test(
        'unrelated setting change still rebuilds the engine '
        '(documents the over-invalidation we accept for simplicity)', () async {
      // syncEngineProvider watches the whole settingsProvider, not just
      // settings.wpm. So any settings mutation rebuilds it. This is the
      // exact scenario slice 30 had to handle — pinning the behaviour
      // here means a future optimisation that narrows the watch must
      // keep slice 30's invariant working.
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
      ]);
      addTearDown(container.dispose);

      final engineA = container.read(syncEngineProvider('job-1'));
      final settings = container.read(settingsProvider.notifier);

      // Toggle reader auto-scroll — unrelated to wpm.
      final originalAutoScroll =
          container.read(settingsProvider).readerAutoScroll;
      await settings.setReaderAutoScroll(!originalAutoScroll);
      await Future<void>.delayed(Duration.zero);

      final engineB = container.read(syncEngineProvider('job-1'));
      expect(identical(engineA, engineB), isFalse,
          reason: 'broad settings watch causes engine rebuild on any change');
    });
  });
}

