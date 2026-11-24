import 'dart:async';

import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// A just_audio platform that plays nothing: every item lasts [itemDuration] and the position
/// is whatever was last sought. It lets host tests drive the REAL `AudioPlayerService`
/// (queue, current index, navigation) without a native decoder.
class MockJustAudioPlatform extends JustAudioPlatform
    with MockPlatformInterfaceMixin {
  static const itemDuration = Duration(seconds: 30);
  final _players = <String, _MockPlayer>{};

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      _players[request.id] = _MockPlayer(request.id);

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async {
    await _players.remove(request.id)?.close();
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
    DisposeAllPlayersRequest request,
  ) async {
    for (final player in _players.values) {
      await player.close();
    }
    _players.clear();
    return DisposeAllPlayersResponse();
  }
}

class _MockPlayer extends AudioPlayerPlatform {
  _MockPlayer(super.id);

  final _events = StreamController<PlaybackEventMessage>.broadcast();
  ProcessingStateMessage _state = ProcessingStateMessage.idle;
  Duration _position = Duration.zero;
  int _index = 0;
  bool _playing = false;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  Future<void> close() => _events.close();

  void _emit() {
    if (_events.isClosed) return;
    _events.add(
      PlaybackEventMessage(
        processingState: _state,
        updateTime: DateTime.now(),
        updatePosition: _position,
        bufferedPosition: MockJustAudioPlatform.itemDuration,
        duration: _state == ProcessingStateMessage.idle
            ? null
            : MockJustAudioPlatform.itemDuration,
        icyMetadata: null,
        currentIndex: _state == ProcessingStateMessage.idle ? null : _index,
        androidAudioSessionId: null,
      ),
    );
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _index = request.initialIndex ?? 0;
    _position = request.initialPosition ?? Duration.zero;
    _state = ProcessingStateMessage.ready;
    _emit();
    return LoadResponse(duration: MockJustAudioPlatform.itemDuration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _playing = true;
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _playing = false;
    _emit();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _position = request.position ?? Duration.zero;
    _index = request.index ?? _index;
    _emit();
    return SeekResponse();
  }

  bool get playing => _playing;

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    await close();
    return DisposeResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
    SetAndroidAudioAttributesRequest request,
  ) async => SetAndroidAudioAttributesResponse();

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
  setAutomaticallyWaitsToMinimizeStalling(
    SetAutomaticallyWaitsToMinimizeStallingRequest request,
  ) async => SetAutomaticallyWaitsToMinimizeStallingResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async => SetShuffleModeResponse();

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
    SetShuffleOrderRequest request,
  ) async => SetShuffleOrderResponse();

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
    SetSkipSilenceRequest request,
  ) async => SetSkipSilenceResponse();

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
    ConcatenatingInsertAllRequest request,
  ) async => ConcatenatingInsertAllResponse();

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
    ConcatenatingMoveRequest request,
  ) async => ConcatenatingMoveResponse();

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
    ConcatenatingRemoveRangeRequest request,
  ) async => ConcatenatingRemoveRangeResponse();
}
