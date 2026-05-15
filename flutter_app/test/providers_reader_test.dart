import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('currentlyReadingBookIdProvider', () {
    test('defaults to null', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      expect(container.read(currentlyReadingBookIdProvider), isNull);
      container.dispose();
    });

    test('reads persisted value', () async {
      SharedPreferences.setMockInitialValues({
        'currentlyReadingBookId': 'book-42',
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      expect(container.read(currentlyReadingBookIdProvider), 'book-42');
      container.dispose();
    });

    test('set persists and notifies', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      final notifier =
          container.read(currentlyReadingBookIdProvider.notifier);
      notifier.set('new-book');

      expect(container.read(currentlyReadingBookIdProvider), 'new-book');
      expect(prefs.getString('currentlyReadingBookId'), 'new-book');
      container.dispose();
    });

    test('set null clears the value', () async {
      SharedPreferences.setMockInitialValues({
        'currentlyReadingBookId': 'old-book',
      });
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      container.read(currentlyReadingBookIdProvider.notifier).set(null);

      expect(container.read(currentlyReadingBookIdProvider), isNull);
      expect(prefs.getString('currentlyReadingBookId'), isNull);
      container.dispose();
    });
  });

  group('currentlyPlayingBookIdProvider', () {
    test('defaults to null', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      expect(container.read(currentlyPlayingBookIdProvider), isNull);
      container.dispose();
    });
  });

  group('rootTabIndexProvider', () {
    test('defaults to 0', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      expect(container.read(rootTabIndexProvider), 0);
      container.dispose();
    });

    test('can be changed', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      container.read(rootTabIndexProvider.notifier).state = 2;
      expect(container.read(rootTabIndexProvider), 2);
      container.dispose();
    });
  });
}
