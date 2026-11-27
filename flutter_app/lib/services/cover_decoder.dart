import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Decodes a stored cover; undecodable input has no cover.
class CoverDecoder {
  CoverDecoder._();

  /// Counts decodes so a test can prove a rebuild does not repeat the work.
  @visibleForTesting
  static int decodeCalls = 0;

  static Uint8List? decode(String? base64Cover) {
    if (base64Cover == null) return null;
    decodeCalls++;
    try {
      return base64Decode(base64Cover);
    } catch (_) {
      return null;
    }
  }
}
