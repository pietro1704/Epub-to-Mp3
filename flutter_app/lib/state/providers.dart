import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/ebook_fulltext.dart';
import '../models/job_snapshot.dart';
import '../models/session_record.dart';
import '../services/api_client.dart';
import '../services/audio_player_service.dart';
import '../services/download_manager.dart';
import '../services/fulltext_store.dart';
import '../services/resume_store.dart';
import '../services/sync_engine.dart';

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
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
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

final fulltextStoreProvider = Provider<FulltextStore>((ref) {
  return FulltextStore(ref.watch(apiClientProvider));
});

final sessionsProvider = FutureProvider<List<SessionRecord>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return api.fetchSessions(last: 50);
});

final jobSnapshotProvider =
    FutureProvider.family<JobSnapshot, String>((ref, jobId) async {
  final api = ref.watch(apiClientProvider);
  return api.fetchJob(jobId);
});

final fulltextProvider =
    FutureProvider.family<EbookFulltext, String>((ref, jobId) async {
  final store = ref.watch(fulltextStoreProvider);
  return store.fetch(jobId);
});

final audioPlayerProvider =
    Provider.family<AudioPlayerService, String>((ref, jobId) {
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
final currentSentenceProvider =
    StreamProvider.family<String?, String>((ref, jobId) {
  final engine = ref.watch(syncEngineProvider(jobId));
  return engine.currentSentence;
});
