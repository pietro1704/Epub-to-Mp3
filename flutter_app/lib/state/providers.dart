import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/ebook_fulltext.dart';
import '../models/job_snapshot.dart';
import '../models/session_record.dart';
import '../services/api_client.dart';
import '../services/android_speech_fallback.dart';
import '../services/audio_player_service.dart';
import '../services/background_audio_handler.dart';
import '../services/bookmark_store.dart';
import '../services/download_manager.dart';
import '../services/fulltext_store.dart';
import '../services/local_fulltext_cache.dart';
import '../services/resume_store.dart';
import '../services/sync_engine.dart';

class AudioStartupState extends ChangeNotifier {
  BackgroundAudioHandler? handler;

  void attach(BackgroundAudioHandler value) {
    handler = value;
    notifyListeners();
  }
}

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

  Future<void> setBackendUrl(String v) async {
    await state.setBackendURL(v);
    _emit();
  }

  Future<void> setWpm(int v) async {
    await state.setWpm(v);
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

  Future<void> setUseEmbeddedRuntime(bool v) async {
    await state.setUseEmbeddedRuntime(v);
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

final apiClientProvider = Provider<ApiClient>((ref) {
  final settings = ref.watch(settingsProvider);
  return ApiClient(settings.backendURL);
});

final downloadManagerProvider = Provider<DownloadManager>((ref) {
  final dm = DownloadManager();
  ref.onDispose(dm.dispose);
  return dm;
});

final resumeStoreProvider = Provider<ResumeStore>((ref) {
  return ResumeStore(ref.watch(sharedPrefsProvider));
});

final bookmarkStoreProvider = ChangeNotifierProvider<BookmarkStore>((ref) {
  return BookmarkStore(prefs: ref.watch(sharedPrefsProvider));
});

final fulltextStoreProvider = Provider<FulltextStore>((ref) {
  return FulltextStore(ref.watch(apiClientProvider));
});

final sessionsProvider = FutureProvider<List<SessionRecord>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return api.fetchSessions(last: 50);
});

final jobSnapshotProvider = FutureProvider.family<JobSnapshot, String>((
  ref,
  jobId,
) async {
  final api = ref.watch(apiClientProvider);
  return api.fetchJob(jobId);
});

final fulltextProvider = FutureProvider.family<EbookFulltext, String>((
  ref,
  jobId,
) async {
  final store = ref.watch(fulltextStoreProvider);
  return store.fetch(jobId);
});

/// Live SSE stream for a running job. Emits [JobSnapshot] on every backend
/// event. The stream auto-disposes when the last listener goes away.
final jobStreamProvider = StreamProvider.family<JobSnapshot, String>((
  ref,
  jobId,
) {
  final api = ref.watch(apiClientProvider);
  return api.jobStream(jobId);
});

final audioPlayerProvider = Provider.family<AudioPlayerService, String>((
  ref,
  jobId,
) {
  final settings = ref.watch(settingsProvider);
  final p = AudioPlayerService(backendBase: settings.backendURL);
  ref.onDispose(p.dispose);
  return p;
});

final syncEngineProvider = Provider.family<SyncEngine, String>((ref, jobId) {
  final settings = ref.watch(settingsProvider);
  final engine = SyncEngine(wpm: settings.wpm);
  ref.onDispose(engine.dispose);
  return engine;
});

/// Drives `currentSentenceId` from the player position stream.
final currentSentenceProvider = StreamProvider.family<String?, String>((
  ref,
  jobId,
) {
  final engine = ref.watch(syncEngineProvider(jobId));
  return engine.currentSentence;
});

// ---------------------------------------------------------------------------
// Reader / mini-player state
// ---------------------------------------------------------------------------

const _currentlyReadingKey = 'currentlyReadingBookId';

/// The book currently open in the Reader tab. Persisted across launches.
final currentlyReadingBookIdProvider =
    StateNotifierProvider<_ReaderSessionNotifier, String?>((ref) {
      final prefs = ref.watch(sharedPrefsProvider);
      return _ReaderSessionNotifier(prefs, _currentlyReadingKey, ref);
    });

/// The book whose audio is actively playing/paused. Ephemeral (not persisted).
final currentlyPlayingBookIdProvider = StateProvider<String?>((ref) => null);

/// Singleton audio player for on-device playback. Not keyed by jobId — this
/// Flutter app runs everything locally, so one player instance suffices.
/// Typed as the interface so tests can substitute a [FakeAudioPlayerService].
final globalAudioPlayerProvider = Provider<AudioPlayerInterface>((ref) {
  final settings = ref.watch(settingsProvider);
  final p = AudioPlayerService(backendBase: settings.backendURL);
  ref.onDispose(p.dispose);
  return p;
});

/// Android MediaSession adapter. Null on desktop/iOS and in host tests.
final audioStartupStateProvider = ChangeNotifierProvider<AudioStartupState>(
  (ref) => AudioStartupState(),
);

final backgroundAudioHandlerProvider = Provider<BackgroundAudioHandler?>(
  (ref) => ref.watch(audioStartupStateProvider).handler,
);

/// Android offline TTS fallback. The default adapter is a no-op on iOS,
/// desktop, web, and host tests; tests can override this provider.
final androidSpeechFallbackProvider = Provider<SpeechEngine>((ref) {
  return AndroidSpeechFallback();
});

/// Shared fulltext cache singleton.
final localFulltextCacheProvider = Provider<LocalFulltextCache>((ref) {
  return LocalFulltextCache();
});

/// Tab index controller for the root NavigationBar, so library can switch to
/// the reader tab programmatically.
final rootTabIndexProvider = StateProvider<int>((ref) => 0);

/// Reader chrome visibility shared with the root shell so the persistent
/// mini-player and navigation bar follow the reader's immersive mode.
final readerChromeVisibleProvider = StateProvider<bool>((ref) => true);

/// A trivial persisted String? notifier. Reads a SharedPreferences key on
/// construction and writes on every `set`.
class _ReaderSessionNotifier extends StateNotifier<String?> {
  _ReaderSessionNotifier(this._prefs, this._key, this._ref)
    : super(_prefs.getString(_key));

  final SharedPreferences _prefs;
  final String _key;
  final Ref _ref;

  void set(String? value) {
    state = value;
    if (value == null) {
      _prefs.remove(_key);
    } else {
      _prefs.setString(_key, value);
    }

    // Opening a book is also the reader's mini-player context switch. This
    // keeps both surfaces bound to the same book even when navigation is
    // initiated by a deep link, document import, or a restored session.
    _ref.read(currentlyPlayingBookIdProvider.notifier).state = value;
  }
}
