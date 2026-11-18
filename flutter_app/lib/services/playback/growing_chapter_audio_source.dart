import 'dart:async';
import 'dart:io';
import 'package:just_audio/just_audio.dart';

/// One MP3 stream whose immutable, ordered files are published by Rust.
// just_audio exposes incremental encoded audio through this documented API.
// ignore: experimental_member_use
class GrowingChapterAudioSource extends StreamAudioSource {
  GrowingChapterAudioSource(this.requestId);
  final String requestId;
  final List<(String, int)> _chunks = [];
  Completer<void> _changed = Completer<void>();
  final Completer<void> _finished = Completer<void>();
  bool _closed = false;
  Object? _failure;
  int _length = 0;

  bool get isComplete => _closed;
  Future<void> get finished => _finished.future;
  int get chunkCount => _chunks.length;

  Future<void> append(int index, String path) async {
    if (_closed || index < _chunks.length) return;
    if (index != _chunks.length) throw StateError('MP3 chunk order mismatch');
    final length = await File(path).length();
    if (_closed) return;
    if (length == 0) throw StateError('Empty MP3 chunk');
    _chunks.add((path, length));
    _length += length;
    _signal();
  }

  void complete() {
    if (_closed) return;
    _closed = true;
    _finished.complete();
    _signal();
  }

  void fail(Object error) {
    if (_closed) return;
    _failure = error;
    complete();
  }

  void _signal() {
    final previous = _changed;
    _changed = Completer<void>();
    previous.complete();
  }

  Future<void> waitForSeek() async {
    await finished;
    if (_failure != null) throw _failure!;
  }

  @override
  // ignore: experimental_member_use
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    // just_audio's proxy requires known lengths for range responses.
    if (start != null && start > 0 || end != null) await waitForSeek();
    final offset = start ?? 0;
    if (offset < 0 || end != null && end < offset) {
      throw RangeError('Invalid audio range');
    }
    final bounded = _closed;
    if (_failure != null) throw _failure!;
    if (bounded && (offset > _length || end != null && end > _length)) {
      throw RangeError('Requested audio range exceeds the completed chapter');
    }
    // ignore: experimental_member_use
    return StreamAudioResponse(
      rangeRequestsSupported: bounded,
      sourceLength: bounded ? _length : null,
      contentLength: bounded ? (end ?? _length) - offset : null,
      offset: bounded ? offset : null,
      contentType: 'audio/mpeg',
      stream: _read(offset, end),
    );
  }

  Stream<List<int>> _read(int offset, int? end) async* {
    var position = offset;
    while (true) {
      if (_failure != null) throw _failure!;
      final changed = _changed.future;
      var chunkStart = 0;
      for (final chunk in List.of(_chunks)) {
        final chunkEnd = chunkStart + chunk.$2;
        if (position < chunkEnd && (end == null || position < end)) {
          final localStart = position > chunkStart ? position - chunkStart : 0;
          final localEnd = end != null && end < chunkEnd
              ? end - chunkStart
              : chunk.$2;
          await for (final bytes in File(
            chunk.$1,
          ).openRead(localStart, localEnd)) {
            if (_failure != null) throw _failure!;
            position += bytes.length;
            yield bytes;
          }
        }
        chunkStart = chunkEnd;
      }
      if (end != null && position >= end || _closed && position >= _length) {
        return;
      }
      await changed;
    }
  }
}
