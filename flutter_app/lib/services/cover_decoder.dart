import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Decodes a stored cover; undecodable input has no cover.
class CoverDecoder {
  CoverDecoder._();

  /// Counts decodes so a test can prove a rebuild does not repeat the work.
  @visibleForTesting
  static int decodeCalls = 0;

  static const _capacity = 8;
  static final _cache = <String, Uint8List?>{};

  /// Playback and library notifications rebuild the covers several times a second; the
  /// same bytes keep one image cache entry instead of a fresh decode each time.
  static Uint8List? decode(String? base64Cover) {
    if (base64Cover == null) return null;
    if (_cache.containsKey(base64Cover)) {
      final hit = _cache.remove(base64Cover);
      _cache[base64Cover] = hit;
      return hit;
    }
    decodeCalls++;
    Uint8List? bytes;
    try {
      bytes = base64Decode(base64Cover);
    } catch (_) {
      bytes = null;
    }
    _cache[base64Cover] = bytes;
    if (_cache.length > _capacity) _cache.remove(_cache.keys.first);
    return bytes;
  }
}
