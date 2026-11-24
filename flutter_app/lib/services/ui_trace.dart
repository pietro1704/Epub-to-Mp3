import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Verification-only record of what the app shows (`EPUB2MP3_UI_TRACE=<file>`).
///
/// The packaged Windows journey reads this instead of scraping the Flutter
/// accessibility tree, which cannot expose long reader text. Disabled (and free)
/// unless the variable names a file; it appends one JSON object per line and
/// never throws into the app.
class UiTrace {
  UiTrace(this.path);

  /// The trace file, or null when tracing is off.
  final String? path;

  bool get enabled => path != null && path!.isNotEmpty;

  /// Longest text a field may carry: enough to identify a passage, never a book.
  static const maxText = 200;

  static UiTrace? _override;
  static final UiTrace _fromEnvironment = UiTrace(
    kIsWeb ? null : Platform.environment['EPUB2MP3_UI_TRACE'],
  );

  static UiTrace get instance => _override ?? _fromEnvironment;

  /// Tests substitute the trace; null restores the environment one.
  @visibleForTesting
  static void override(UiTrace? trace) => _override = trace;

  void emit(String event, [Map<String, Object?> fields = const {}]) {
    if (!enabled) return;
    try {
      final line = jsonEncode({
        't': DateTime.now().millisecondsSinceEpoch,
        'event': event,
        for (final entry in fields.entries) entry.key: _bounded(entry.value),
      });
      File(path!).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Tracing must never affect the app.
    }
  }

  static Object? _bounded(Object? value) =>
      value is String && value.length > maxText ? value.substring(0, maxText) : value;
}
