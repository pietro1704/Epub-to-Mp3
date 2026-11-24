part of 'providers.dart';

// Persisted preferences and their reactive notifier.

/// `SharedPreferences` is asynchronously initialised once at app start.
final sharedPrefsProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('Override at runApp scope'),
);

/// Re-export of the iOS-mirror settings under the legacy `AppSettings`
/// name so existing call sites compile unchanged after the migration.
/// Behaviour is identical to `MirrorAppSettings` — the rename keeps
/// the file diff tight while collapsing the two parallel classes into
/// one.
typedef AppSettings = MirrorAppSettings;

/// Reactive settings notifier. `MirrorAppSettings` mutates
/// `SharedPreferences` directly (Swift @AppStorage shape), so every
/// setter call refreshes state via `_emit`.
class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier(SharedPreferences prefs)
    : _prefs = prefs,
      super(MirrorAppSettings(prefs));

  final SharedPreferences _prefs;

  /// Re-publishes a fresh `MirrorAppSettings` after a mutation so
  /// Riverpod listeners rebuild. The underlying prefs are the source
  /// of truth — this just nudges the state stream.
  void _emit() {
    state = MirrorAppSettings(_prefs);
  }

  Future<void> setTtsPreferences(TtsPreferences value) async {
    await state.setTtsPreferences(value);
    _emit();
  }

  Future<void> setWpm(int v) async {
    await state.setWpm(v);
    _emit();
  }

  Future<void> resetReaderTypography() async {
    await state.resetReaderTypography();
    _emit();
  }

  Future<void> setSeekIntervals({int? forward, int? backward}) async {
    await state.setSeekIntervals(forward: forward, backward: backward);
    _emit();
  }

  Future<void> setRemoteButtonMode(RemoteButtonMode mode) async {
    await state.setRemoteButtonMode(mode);
    _emit();
  }

  Future<void> setAudioRate(double v) async {
    await state.setAudioRate(v);
    _emit();
  }

  Future<void> setReaderFontSize(int step) async {
    await state.setReaderFontSize(step);
    _emit();
  }

  Future<void> setReaderTheme(ReaderTheme t) async {
    await state.setReaderTheme(t);
    _emit();
  }

  Future<void> setReaderFontFamily(ReaderFontFamily v) async {
    await state.setReaderFontFamily(v);
    _emit();
  }

  Future<void> setReaderLayout(ReaderLayout v) async {
    await state.setReaderLayout(v);
    _emit();
  }

  Future<void> setReaderLineSpacing(double v) async {
    await state.setReaderLineSpacing(v);
    _emit();
  }

  Future<void> setReaderMargin(double v) async {
    await state.setReaderMargin(v);
    _emit();
  }

  Future<void> setReaderAutoScroll(bool v) async {
    await state.setReaderAutoScroll(v);
    _emit();
  }

  Future<void> setReaderShowPageNumbers(bool v) async {
    await state.setReaderShowPageNumbers(v);
    _emit();
  }

  Future<void> setReaderTextAlignment(ReaderTextAlignment v) async {
    await state.setReaderTextAlignment(v);
    _emit();
  }

  /// Legacy slider hooks for the existing settings_screen UI. They
  /// route to the iOS-mirror step/enum settings underneath.
  Future<void> setFontSize(double v) async {
    await state.setFontSize(v);
    _emit();
  }

  Future<void> setDarkMode(bool v) async {
    await state.setDarkMode(v);
    _emit();
  }

  Future<void> setReaderColumnWidth(double v) async {
    await state.setReaderColumnWidth(v);
    _emit();
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, AppSettings>((
  ref,
) {
  final prefs = ref.watch(sharedPrefsProvider);
  return SettingsNotifier(prefs);
});

/// One book's own reading preferences (appearance and speed), persisted per book.
class BookReadingOverridesNotifier extends StateNotifier<ReadingOverrides> {
  BookReadingOverridesNotifier(SharedPreferences prefs, this.bookId)
    : _store = BookReadingStore(prefs),
      super(BookReadingStore(prefs).read(bookId));

  final String bookId;
  final BookReadingStore _store;

  Future<void> update(ReadingOverrides Function(ReadingOverrides) change) async {
    state = change(state);
    await _store.write(bookId, state);
  }

  /// "Use the default": the book follows the default for all books again.
  Future<void> clear() async {
    state = ReadingOverrides.none;
    await _store.write(bookId, state);
  }
}

final bookReadingOverridesProvider =
    StateNotifierProvider.family<BookReadingOverridesNotifier, ReadingOverrides, String>(
      (ref, bookId) => BookReadingOverridesNotifier(ref.watch(sharedPrefsProvider), bookId),
    );

/// The settings the reader of [bookId] uses: the default for all books with the
/// book's own overrides on top (null = the default itself).
final readerSettingsProvider = Provider.family<AppSettings, String?>((ref, bookId) {
  final base = ref.watch(settingsProvider);
  if (bookId == null) return base;
  final overrides = ref.watch(bookReadingOverridesProvider(bookId));
  return overrides.isEmpty ? base : BookScopedAppSettings(ref.watch(sharedPrefsProvider), overrides);
});
