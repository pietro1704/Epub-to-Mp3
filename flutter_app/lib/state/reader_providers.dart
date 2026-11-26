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

/// A request to open the reader on the chapter that is playing, raised by the
/// expanded player's cover and consumed by the reader showing that book.
final readerPlaybackJumpProvider =
    StateProvider<({String bookId, int chapterIndex})?>((ref) => null);

/// Whether the open reader shows the sentence being spoken (null: nothing is
/// being narrated for it). Published by the reader, read by the expanded player.
final readerNarrationPairedProvider = StateProvider<bool?>((ref) => null);

/// Bumped to ask the reader to go back to the narrated page and follow it again.
final readerPairRequestProvider = StateProvider<int>((ref) => 0);

/// Reader tools that can sit beside the overflow menu (Apple `ReaderTool`).
enum ReaderTool { appearance, contents, search, bookmarks, footnotes, listen, voiceModels }

const _recentToolKey = 'reader.recentTool.v1';

/// The tool shown beside the overflow menu: the one used last, initially the
/// text appearance. Persisted across launches.
final readerRecentToolProvider =
    StateNotifierProvider<_RecentToolNotifier, ReaderTool>((ref) {
      return _RecentToolNotifier(ref.watch(sharedPrefsProvider));
    });

class _RecentToolNotifier extends StateNotifier<ReaderTool> {
  _RecentToolNotifier(this._prefs)
    : super(
        ReaderTool.values.asNameMap()[_prefs.getString(_recentToolKey)] ??
            ReaderTool.appearance,
      );

  final SharedPreferences _prefs;

  void set(ReaderTool tool) {
    state = tool;
    _prefs.setString(_recentToolKey, tool.name);
  }
}

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
