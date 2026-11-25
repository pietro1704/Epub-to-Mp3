import 'package:dbus/dbus.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/services/playback/background_audio_handler.dart';
import 'package:flutter_app/services/playback/mpris_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_audio_player_service.dart';

// Linux desktop transport: playerctl / the desktop media keys talk MPRIS to this object, which
// forwards to the same BackgroundAudioHandler as the Android MediaSession (CAR-REMOTE-CHAPTERS).
const _player = 'org.mpris.MediaPlayer2.Player';

Future<DBusMethodResponse> _call(
  MprisPlayerObject object,
  String name, [
  List<DBusValue> values = const [],
]) => object.handleMethodCall(
  DBusMethodCall(
    sender: ':1.7',
    interface: _player,
    name: name,
    values: values,
  ),
);

DBusValue _value(DBusMethodResponse response) =>
    ((response as DBusGetPropertyResponse).values.first as DBusVariant).value;

void main() {
  late FakeAudioPlayerService player;
  late BackgroundAudioHandler handler;
  late MprisPlayerObject object;

  setUp(() async {
    player = FakeAudioPlayerService();
    await player.setQueue([
      for (final index in [0, 1, 2])
        ChapterProgress(
          index: index,
          name: 'Chapter $index',
          status: 'completed',
          downloadUrl: 'file:///fixture/$index.mp3',
        ),
    ]);
    handler = BackgroundAudioHandler(player);
    object = MprisPlayerObject(handler);
  });

  tearDown(() => handler.dispose());

  // Linux run 2026-11-25: with a book loaded but nothing queued yet, MPRIS Play logged
  // "play ignored: no queued audio". The mini player starts the narration in that case; a car,
  // headphones, media keys or the lock screen must do the same.
  test('Play and PlayPause with nothing queued start the narration like the mini player', () async {
    final empty = FakeAudioPlayerService();
    final remote = BackgroundAudioHandler(empty);
    addTearDown(remote.dispose);
    var requests = 0;
    remote.startNarration = () async => requests++;
    final mpris = MprisPlayerObject(remote);
    expect(await _call(mpris, 'Play'), isA<DBusMethodSuccessResponse>());
    expect(requests, 1);
    expect(await _call(mpris, 'PlayPause'), isA<DBusMethodSuccessResponse>());
    expect(requests, 2);
  });

  test('Play with audio queued resumes it without a new request', () async {
    var requests = 0;
    handler.startNarration = () async => requests++;
    await _call(object, 'Play');
    expect(requests, 0);
  });

  test('Next and Previous move between chapters', () async {
    expect(await _call(object, 'Next'), isA<DBusMethodSuccessResponse>());
    expect(player.currentIndexValue, 1);
    expect(await _call(object, 'Previous'), isA<DBusMethodSuccessResponse>());
    expect(player.currentIndexValue, 0);
  });

  test('in skip mode Next and Previous skip the configured seconds', () async {
    handler.remoteButtonMode = RemoteButtonMode.seconds;
    player.seekForwardSeconds = 45;
    await player.seek(const Duration(seconds: 100));
    await _call(object, 'Next');
    expect(player.positionSeconds, 145);
    expect(player.currentIndexValue, 0);
  });

  test('Play, Pause and PlayPause drive the player', () async {
    await _call(object, 'Play');
    expect(player.isPlaying, isTrue);
    await _call(object, 'PlayPause');
    expect(player.isPlaying, isFalse);
    await _call(object, 'PlayPause');
    expect(player.isPlaying, isTrue);
    await _call(object, 'Pause');
    expect(player.isPlaying, isFalse);
  });

  test('Seek and SetPosition use microseconds', () async {
    await _call(object, 'SetPosition', [
      DBusObjectPath('/org/epubtomp3/track/0'),
      DBusInt64(30 * 1000000),
    ]);
    expect(player.positionSeconds, 30);
    await _call(object, 'Seek', [DBusInt64(-10 * 1000000)]);
    expect(player.positionSeconds, 20);
  });

  test('the properties playerctl reads describe the playback', () async {
    Future<DBusValue> read(String name) async =>
        _value(await object.getProperty(_player, name));
    expect(await read('PlaybackStatus'), DBusString('Paused'));
    await handler.setMetadata(
      const BackgroundAudioMetadata(
        bookId: 'book-1',
        bookTitle: 'The Book',
        author: 'Author',
        chapterTitle: 'Chapter 1',
        duration: Duration(minutes: 5),
      ),
    );
    await _call(object, 'Play');
    expect(await read('PlaybackStatus'), DBusString('Playing'));
    final fields = ((await read('Metadata')) as DBusDict).asStringVariantDict();
    expect(fields['xesam:title'], DBusString('Chapter 1'));
    expect(fields['xesam:album'], DBusString('The Book'));
    expect(fields['mpris:length'], DBusInt64(5 * 60 * 1000000));
    for (final capability in [
      'CanGoNext',
      'CanGoPrevious',
      'CanPlay',
      'CanPause',
      'CanSeek',
      'CanControl',
    ]) {
      expect(await read(capability), DBusBoolean(true), reason: capability);
    }
    expect(
      _value(await object.getProperty('org.mpris.MediaPlayer2', 'Identity')),
      DBusString('EpubToMp3'),
    );
  });
}
