import 'package:flutter_app/services/playback/background_audio_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the media notification is never ongoing once it can be detached from the service', () {
    final config = backgroundAudioConfig();
    expect(config.androidStopForegroundOnPause, isTrue, reason: 'paused playback leaves the foreground');
    expect(
      config.androidNotificationOngoing,
      isFalse,
      reason: 'a detached ongoing notification cannot be swiped away and outlives the process',
    );
    expect(config.androidNotificationChannelId, 'com.pietrocode.epubtomp3.audio');
    expect(config.androidResumeOnClick, isTrue, reason: 'tapping the notification still resumes playback');
  });
}
