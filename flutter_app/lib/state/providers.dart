import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class AppSettings {
  const AppSettings({
    required this.backendUrl,
    required this.wpm,
    required this.audioRate,
    required this.fontSize,
    required this.darkMode,
  });

  final String backendUrl;
  final int wpm;
  final double audioRate;
  final double fontSize;
  final bool darkMode;

  AppSettings copyWith({
    String? backendUrl,
    int? wpm,
    double? audioRate,
    double? fontSize,
    bool? darkMode,
  }) =>
      AppSettings(
        backendUrl: backendUrl ?? this.backendUrl,
        wpm: wpm ?? this.wpm,
        audioRate: audioRate ?? this.audioRate,
        fontSize: fontSize ?? this.fontSize,
        darkMode: darkMode ?? this.darkMode,
      );
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier(this._prefs)
      : super(AppSettings(
          backendUrl: _prefs.getString('backendUrl') ?? 'http://localhost:8000',
          wpm: _prefs.getInt('wpm') ?? 200,
          audioRate: _prefs.getDouble('audioRate') ?? 1.0,
          fontSize: _prefs.getDouble('fontSize') ?? 16.0,
          darkMode: _prefs.getBool('darkMode') ?? false,
        ));

  final SharedPreferences _prefs;

  Future<void> setBackendUrl(String v) async {
    await _prefs.setString('backendUrl', v);
    state = state.copyWith(backendUrl: v);
  }

  Future<void> setWpm(int v) async {
    await _prefs.setInt('wpm', v);
    state = state.copyWith(wpm: v);
  }

  Future<void> setAudioRate(double v) async {
    await _prefs.setDouble('audioRate', v);
    state = state.copyWith(audioRate: v);
  }

  Future<void> setFontSize(double v) async {
    await _prefs.setDouble('fontSize', v);
    state = state.copyWith(fontSize: v);
  }

  Future<void> setDarkMode(bool v) async {
    await _prefs.setBool('darkMode', v);
    state = state.copyWith(darkMode: v);
  }
}

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  return SettingsNotifier(prefs);
});

final apiClientProvider = Provider<ApiClient>((ref) {
  final settings = ref.watch(settingsProvider);
  return ApiClient(settings.backendUrl);
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
  final p = AudioPlayerService(backendBase: settings.backendUrl);
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
