import 'dart:async';

import 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

import 'background_audio_handler.dart';

/// MPRIS (org.mpris.MediaPlayer2) for the Linux desktop: `playerctl`, the desktop media keys and
/// shells talk to this object, which forwards to the same [BackgroundAudioHandler] as the Android
/// MediaSession, so next/previous honour the REMOTE-BUTTON-MODE setting and a chapter that is
/// still being synthesized (CAR-REMOTE-CHAPTERS).
const _root = 'org.mpris.MediaPlayer2';
const _playerInterface = 'org.mpris.MediaPlayer2.Player';
const mprisBusName = 'org.mpris.MediaPlayer2.EpubToMp3';

class MprisPlayerObject extends DBusObject {
  MprisPlayerObject(this.handler)
    : super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  final BackgroundAudioHandler handler;

  bool get _playing => handler.playbackState.value.playing;

  Map<String, DBusValue> _rootProperties() => {
    'CanQuit': DBusBoolean(false),
    'CanRaise': DBusBoolean(false),
    'HasTrackList': DBusBoolean(false),
    'Identity': DBusString('EpubToMp3'),
    'SupportedUriSchemes': DBusArray.string(const []),
    'SupportedMimeTypes': DBusArray.string(const []),
  };

  DBusValue _metadata() {
    final item = handler.mediaItem.value;
    final fields = <String, DBusValue>{
      'mpris:trackid': DBusObjectPath(
        '/org/epubtomp3/track/${handler.player.currentIndexValue ?? 0}',
      ),
    };
    if (item != null) {
      fields['xesam:title'] = DBusString(item.title);
      if (item.album != null) fields['xesam:album'] = DBusString(item.album!);
      if (item.artist != null) {
        fields['xesam:artist'] = DBusArray.string([item.artist!]);
      }
      if (item.duration != null) {
        fields['mpris:length'] = DBusInt64(item.duration!.inMicroseconds);
      }
    }
    return DBusDict.stringVariant(fields);
  }

  String get _status {
    final state = handler.playbackState.value;
    if (state.processingState == AudioProcessingState.idle && !state.playing) {
      return handler.mediaItem.value == null ? 'Stopped' : 'Paused';
    }
    return state.playing ? 'Playing' : 'Paused';
  }

  Map<String, DBusValue> _playerProperties() => {
    'PlaybackStatus': DBusString(_status),
    'LoopStatus': DBusString('None'),
    'Rate': DBusDouble(handler.playbackState.value.speed),
    'Shuffle': DBusBoolean(false),
    'Metadata': _metadata(),
    'Volume': DBusDouble(1),
    'Position': DBusInt64((handler.player.positionSeconds * 1000000).round()),
    'MinimumRate': DBusDouble(0.5),
    'MaximumRate': DBusDouble(2),
    'CanGoNext': DBusBoolean(true),
    'CanGoPrevious': DBusBoolean(true),
    'CanPlay': DBusBoolean(true),
    'CanPause': DBusBoolean(true),
    'CanSeek': DBusBoolean(true),
    'CanControl': DBusBoolean(true),
  };

  Map<String, DBusValue>? _properties(String interface) => switch (interface) {
    _root => _rootProperties(),
    _playerInterface => _playerProperties(),
    _ => null,
  };

  /// What a desktop shell must refresh when the playback changes.
  Map<String, DBusValue> get changingProperties => {
    'PlaybackStatus': DBusString(_status),
    'Metadata': _metadata(),
    'Rate': DBusDouble(handler.playbackState.value.speed),
  };

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = _properties(interface)?[name];
    if (value == null) return DBusMethodErrorResponse.unknownProperty();
    return DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      DBusGetAllPropertiesResponse(_properties(interface) ?? const {});

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    switch (methodCall.interface) {
      case _root:
        return switch (methodCall.name) {
          'Raise' || 'Quit' => DBusMethodSuccessResponse(),
          _ => DBusMethodErrorResponse.unknownMethod(),
        };
      case _playerInterface:
        switch (methodCall.name) {
          case 'Next':
            await handler.skipToNext();
          case 'Previous':
            await handler.skipToPrevious();
          case 'Play':
            await handler.play();
          case 'Pause':
            await handler.pause();
          case 'PlayPause':
            await (_playing ? handler.pause() : handler.play());
          case 'Stop':
            await handler.stop();
          case 'Seek':
            final offset = (methodCall.values.first as DBusInt64).value;
            final target = Duration(
              microseconds:
                  (handler.player.positionSeconds * 1000000).round() + offset,
            );
            await handler.seek(target < Duration.zero ? Duration.zero : target);
          case 'SetPosition':
            await handler.seek(
              Duration(microseconds: (methodCall.values[1] as DBusInt64).value),
            );
          case 'OpenUri':
            break;
          default:
            return DBusMethodErrorResponse.unknownMethod();
        }
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownInterface();
  }

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      _root,
      methods: [DBusIntrospectMethod('Raise'), DBusIntrospectMethod('Quit')],
      properties: [
        for (final entry in _rootProperties().entries)
          DBusIntrospectProperty(
            entry.key,
            entry.value.signature,
            access: DBusPropertyAccess.read,
          ),
      ],
    ),
    DBusIntrospectInterface(
      _playerInterface,
      methods: [
        for (final name in [
          'Next',
          'Previous',
          'Pause',
          'PlayPause',
          'Stop',
          'Play',
        ])
          DBusIntrospectMethod(name),
        DBusIntrospectMethod(
          'Seek',
          args: [
            DBusIntrospectArgument(
              DBusSignature('x'),
              DBusArgumentDirection.in_,
              name: 'Offset',
            ),
          ],
        ),
        DBusIntrospectMethod(
          'SetPosition',
          args: [
            DBusIntrospectArgument(
              DBusSignature('o'),
              DBusArgumentDirection.in_,
              name: 'TrackId',
            ),
            DBusIntrospectArgument(
              DBusSignature('x'),
              DBusArgumentDirection.in_,
              name: 'Position',
            ),
          ],
        ),
      ],
      properties: [
        for (final entry in _playerProperties().entries)
          DBusIntrospectProperty(
            entry.key,
            entry.value.signature,
            access: DBusPropertyAccess.read,
          ),
      ],
    ),
  ];
}

/// Owns the session-bus name and keeps the properties current. Absent session bus or a taken
/// name only means no desktop transport: playback is unaffected.
class MprisService {
  MprisService(this.handler);

  final BackgroundAudioHandler handler;
  DBusClient? _client;
  MprisPlayerObject? _object;
  final _subscriptions = <StreamSubscription<Object?>>[];
  String? _lastSignature;

  Future<void> start() async {
    try {
      final client = DBusClient.session();
      final object = MprisPlayerObject(handler);
      await client.registerObject(object);
      await client.requestName(
        mprisBusName,
        flags: {DBusRequestNameFlag.doNotQueue},
      );
      _client = client;
      _object = object;
      _subscriptions
        ..add(handler.playbackState.listen((_) => _changed()))
        ..add(handler.mediaItem.listen((_) => _changed()));
    } catch (error) {
      debugPrint('MPRIS unavailable: $error');
    }
  }

  void _changed() {
    final object = _object;
    if (object == null) return;
    final changed = object.changingProperties;
    final signature = changed.values.map((value) => value.toString()).join('|');
    if (signature == _lastSignature) return;
    _lastSignature = signature;
    unawaited(
      object
          .emitPropertiesChanged(_playerInterface, changedProperties: changed)
          .catchError(
            (Object error) => debugPrint('MPRIS update failed: $error'),
          ),
    );
  }

  Future<void> stop() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    final client = _client;
    _client = null;
    _object = null;
    await client?.close();
  }
}
