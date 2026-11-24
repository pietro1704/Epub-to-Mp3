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
