part of 'app_settings.dart';

/// What the EXTERNAL next/previous buttons (car head unit, headphones, lock screen, notification)
/// do (card REMOTE-BUTTON-MODE): go to the next/previous chapter (the default and the behaviour
/// before the setting existed), or skip the configured back/forward seconds.
enum RemoteButtonMode {
  chapter,
  seconds;

  static RemoteButtonMode parse(String? value) =>
      RemoteButtonMode.values.firstWhere(
        (mode) => mode.name == value,
        orElse: () => RemoteButtonMode.chapter,
      );
}

mixin PlaybackSettings {
  SharedPreferences get _prefs;
  static const seekIntervals = [15, 30, 45, 60];
  int get seekForwardSeconds => _interval('seekForwardSeconds');
  int get seekBackwardSeconds => _interval('seekBackwardSeconds');
  int _interval(String key) {
    final value = _prefs.getInt(key) ?? 15;
    return seekIntervals.contains(value) ? value : 15;
  }

  RemoteButtonMode get remoteButtonMode =>
      RemoteButtonMode.parse(_prefs.getString('remoteButtonMode'));

  Future<void> setRemoteButtonMode(RemoteButtonMode mode) =>
      _prefs.setString('remoteButtonMode', mode.name);

  Future<void> setSeekIntervals({int? forward, int? backward}) async {
    if (forward != null && seekIntervals.contains(forward)) {
      await _prefs.setInt('seekForwardSeconds', forward);
    }
    if (backward != null && seekIntervals.contains(backward)) {
      await _prefs.setInt('seekBackwardSeconds', backward);
    }
  }
}
