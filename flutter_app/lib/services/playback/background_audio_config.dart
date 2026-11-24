import 'package:audio_service/audio_service.dart';

/// The Android media notification of the audiobook player.
///
/// It must stay dismissible. `androidStopForegroundOnPause` makes `audio_service`
/// detach the notification from the foreground service when playback pauses; an
/// *ongoing* notification that was detached cannot be swiped away and survives the
/// death of the process, so a ghost notification stayed on the device until the
/// user tapped it (A8, 2026-11-24).
AudioServiceConfig backgroundAudioConfig() => AudioServiceConfig(
  androidNotificationChannelId: 'com.pietrocode.epubtomp3.audio',
  androidNotificationChannelName: 'Audiobook playback',
  androidNotificationOngoing: false,
  androidStopForegroundOnPause: true,
  androidNotificationClickStartsActivity: true,
  androidResumeOnClick: true,
);
