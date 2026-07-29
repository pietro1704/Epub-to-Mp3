import 'package:flutter_app/state/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('opening another book rebinds the mini-player context', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    container.read(currentlyReadingBookIdProvider.notifier).set('book-a');
    expect(container.read(currentlyPlayingBookIdProvider), 'book-a');

    container.read(currentlyReadingBookIdProvider.notifier).set('book-b');
    expect(container.read(currentlyReadingBookIdProvider), 'book-b');
    expect(container.read(currentlyPlayingBookIdProvider), 'book-b');
  });

  test('closing the reader clears the mini-player context', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    container.read(currentlyReadingBookIdProvider.notifier).set('book-a');
    container.read(currentlyReadingBookIdProvider.notifier).set(null);

    expect(container.read(currentlyPlayingBookIdProvider), isNull);
  });
}
