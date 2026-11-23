part of 'providers.dart';

// Reader session, navigation and per-book reading stores.

const _currentlyReadingKey = 'currentlyReadingBookId';

/// The book currently open in the Reader tab. Persisted across launches.
final currentlyReadingBookIdProvider =
    StateNotifierProvider<_ReaderSessionNotifier, String?>((ref) {
      final prefs = ref.watch(sharedPrefsProvider);
      return _ReaderSessionNotifier(prefs, _currentlyReadingKey);
    });

final resumeStoreProvider = Provider<ResumeStore>((ref) {
  return ResumeStore(ref.watch(sharedPrefsProvider));
});

final bookmarkStoreProvider = ChangeNotifierProvider<BookmarkStore>((ref) {
  return BookmarkStore(prefs: ref.watch(sharedPrefsProvider));
});

/// Shared fulltext cache singleton.
final localFulltextCacheProvider = Provider<LocalFulltextCache>((ref) {
  return LocalFulltextCache();
});

/// Deletes what the app derived from a book when it is removed from the library.
final bookDerivedDataRemoverProvider = Provider<BookDerivedDataRemover>((ref) {
  return BookDerivedDataRemover(
    prefs: ref.watch(sharedPrefsProvider),
    fulltextCache: ref.watch(localFulltextCacheProvider),
    documents: getApplicationDocumentsDirectory,
  );
});

/// Tab index controller for the root NavigationBar, so library can switch to
/// the reader tab programmatically.
final appDestinationProvider = StateProvider<AppDestination>(
  (ref) => ref.read(currentlyReadingBookIdProvider) == null
      ? AppDestination.library
      : AppDestination.reader,
);

/// Reader chrome visibility shared with the root shell so the persistent
/// mini-player and navigation bar follow the reader's immersive mode.
final readerChromeVisibleProvider = StateProvider<bool>((ref) => true);

/// A trivial persisted String? notifier. Reads a SharedPreferences key on
/// construction and writes on every `set`.
class _ReaderSessionNotifier extends StateNotifier<String?> {
  _ReaderSessionNotifier(this._prefs, this._key)
    : super(_prefs.getString(_key));

  final SharedPreferences _prefs;
  final String _key;

  void set(String? value) {
    state = value;
    if (value == null) {
      _prefs.remove(_key);
    } else {
      _prefs.setString(_key, value);
    }
  }
}
