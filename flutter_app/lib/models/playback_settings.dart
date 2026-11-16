part of 'app_settings.dart';

mixin PlaybackSettings {
  SharedPreferences get _prefs;
  static const seekIntervals = [15, 30, 45, 60];
  int get seekForwardSeconds => _interval('seekForwardSeconds');
  int get seekBackwardSeconds => _interval('seekBackwardSeconds');
  int _interval(String key) {
    final value = _prefs.getInt(key) ?? 15;
    return seekIntervals.contains(value) ? value : 15;
  }

  Future<void> setSeekIntervals({int? forward, int? backward}) async {
    if (forward != null && seekIntervals.contains(forward)) {
      await _prefs.setInt('seekForwardSeconds', forward);
    }
    if (backward != null && seekIntervals.contains(backward)) {
      await _prefs.setInt('seekBackwardSeconds', backward);
    }
  }
}
