import 'package:shared_preferences/shared_preferences.dart';

/// Per-job per-chapter playback resume position (seconds), persisted via
/// `shared_preferences`. Mirrors iOS `ResumeStore.swift`.
class ResumeStore {
  ResumeStore(this._prefs);
  final SharedPreferences _prefs;

  static String _key(String jobId, int chapterIndex) =>
      'resume:$jobId:$chapterIndex';

  Future<void> save(String jobId, int chapterIndex, double seconds) async {
    await _prefs.setDouble(_key(jobId, chapterIndex), seconds);
  }

  double? load(String jobId, int chapterIndex) =>
      _prefs.getDouble(_key(jobId, chapterIndex));

  Future<void> clear(String jobId, int chapterIndex) async {
    await _prefs.remove(_key(jobId, chapterIndex));
  }
}
