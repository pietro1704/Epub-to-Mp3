// A remote seek/skip re-pairs the reader only when "follow audio" is on.
import 'package:flutter_app/services/playback/background_audio_handler.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_audio_player_service.dart';

Future<int> _pairRequestsAfterRemoteJump(bool follow) async {
  SharedPreferences.setMockInitialValues({'readerAutoScroll': follow});
  final prefs = await SharedPreferences.getInstance();
  final handler = BackgroundAudioHandler(FakeAudioPlayerService());
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      backgroundAudioHandlerProvider.overrideWithValue(handler),
    ],
  );
  addTearDown(container.dispose);
  container.read(remotePlayStartSyncProvider);
  await handler.skipToNext();
  return container.read(readerPairRequestProvider);
}

void main() {
  test('a remote jump re-pairs the reader when follow audio is on', () async {
    expect(await _pairRequestsAfterRemoteJump(true), 1);
  });

  test('with follow audio off a remote jump does not move the page', () async {
    expect(await _pairRequestsAfterRemoteJump(false), 0);
  });
}
