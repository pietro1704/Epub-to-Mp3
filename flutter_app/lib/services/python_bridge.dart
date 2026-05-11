import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/ebook_fulltext.dart';

/// Bridges Dart to the embedded CPython runtime that ships inside the
/// Android APK via Chaquopy. The Kotlin side
/// (`MainActivity.kt`) handles the actual `Python.getInstance()` calls and
/// invokes [python_app.src.android_entrypoints] under the hood.
///
/// Mirrors the iOS `PythonBridge.swift` contract — the MethodChannel name
/// and method names must stay in lockstep across both clients.
class PythonBridge {
  PythonBridge._();
  static final PythonBridge instance = PythonBridge._();
  factory PythonBridge() => instance;

  static const MethodChannel _channel = MethodChannel('epub_to_mp3/python');

  /// True only on platforms where Chaquopy is actually wired up. On
  /// desktop / iOS this returns false so callers can transparently fall
  /// back to the remote FastAPI backend.
  bool get isSupported {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Boots the Python runtime and confirms it responds. Returns the
  /// Python `sys.version` string on success.
  Future<String> bootstrap() async {
    final result = await _channel.invokeMethod<String>('bootstrap');
    if (result == null || result.isEmpty) {
      throw StateError('PythonBridge.bootstrap returned empty payload');
    }
    return result;
  }

  /// Parses an EPUB / PDF located at [filePath] off the main isolate (the
  /// Kotlin side dispatches to Chaquopy, which runs on a worker thread)
  /// and decodes the resulting JSON payload into an [EbookFulltext].
  ///
  /// [jobId] is plumbed through into the returned model since the Python
  /// side has no knowledge of the Dart-side job identifier.
  Future<EbookFulltext> parseEpub(String filePath, {String jobId = ''}) async {
    final raw = await _channel.invokeMethod<String>(
      'parseEpub',
      <String, dynamic>{'path': filePath},
    );
    if (raw == null || raw.isEmpty) {
      throw StateError('PythonBridge.parseEpub returned empty payload');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'PythonBridge.parseEpub: expected JSON object, got ${decoded.runtimeType}',
      );
    }
    if (jobId.isNotEmpty) {
      decoded['jobId'] = jobId;
    }
    return EbookFulltext.fromJson(decoded);
  }
}
