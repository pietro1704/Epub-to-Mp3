import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Small, versioned contract consumed by Android widgets and the Flutter
/// mini-player. It intentionally contains no book object, so stale/deleted
/// library entries cannot be resurrected by a widget.
class WidgetPlaybackSnapshot {
  const WidgetPlaybackSnapshot({
    required this.bookId,
    required this.title,
    required this.chapter,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.progress,
    this.savedAt,
  });

  const WidgetPlaybackSnapshot.empty()
    : bookId = null,
      title = null,
      chapter = null,
      position = 0,
      duration = 0,
      isPlaying = false,
      progress = 0,
      savedAt = null;

  final String? bookId;
  final String? title;
  final String? chapter;
  final double position;
  final double duration;
  final bool isPlaying;
  final double progress;
  final DateTime? savedAt;

  Map<String, dynamic> toJson({DateTime? savedAt}) => {
    'version': 1,
    'bookId': bookId,
    'title': title,
    'chapter': chapter,
    'position': position,
    'duration': duration,
    'isPlaying': isPlaying,
    'progress': progress.clamp(0.0, 1.0),
    'savedAt': (savedAt ?? this.savedAt ?? DateTime.now()).toIso8601String(),
  };

  static WidgetPlaybackSnapshot? tryFromJson(Object? value) {
    if (value is! Map || value['version'] != 1) return null;
    final position = (value['position'] as num?)?.toDouble();
    final duration = (value['duration'] as num?)?.toDouble();
    final progress = (value['progress'] as num?)?.toDouble();
    final savedAt = DateTime.tryParse(value['savedAt']?.toString() ?? '');
    if (position == null ||
        duration == null ||
        progress == null ||
        savedAt == null) {
      return null;
    }
    return WidgetPlaybackSnapshot(
      bookId: value['bookId'] as String?,
      title: value['title'] as String?,
      chapter: value['chapter'] as String?,
      position: position,
      duration: duration,
      isPlaying: value['isPlaying'] == true,
      progress: progress,
      savedAt: savedAt,
    );
  }

  factory WidgetPlaybackSnapshot.fromJson(Map<String, dynamic> json) =>
      tryFromJson(json) ?? const WidgetPlaybackSnapshot.empty();

  @override
  bool operator ==(Object other) =>
      other is WidgetPlaybackSnapshot &&
      other.bookId == bookId &&
      other.title == title &&
      other.chapter == chapter &&
      other.position == position &&
      other.duration == duration &&
      other.isPlaying == isPlaying &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(
    bookId,
    title,
    chapter,
    position,
    duration,
    isPlaying,
    progress,
  );
}

class WidgetPlaybackSnapshotStore {
  WidgetPlaybackSnapshotStore(this._prefs, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const key = 'widget.playback_snapshot.v1';
  final SharedPreferences _prefs;
  final DateTime Function() _now;

  Future<void> save(WidgetPlaybackSnapshot snapshot, {DateTime? savedAt}) =>
      _prefs.setString(key, jsonEncode(snapshot.toJson(savedAt: savedAt)));

  Future<WidgetPlaybackSnapshot> load({
    Duration maxAge = const Duration(days: 30),
  }) async {
    final raw = _prefs.getString(key);
    if (raw == null) return const WidgetPlaybackSnapshot.empty();
    try {
      final parsed = WidgetPlaybackSnapshot.tryFromJson(jsonDecode(raw));
      if (parsed == null ||
          parsed.bookId == null ||
          _now().difference(parsed.savedAt!).compareTo(maxAge) > 0 ||
          _now().isBefore(parsed.savedAt!)) {
        return const WidgetPlaybackSnapshot.empty();
      }
      return parsed;
    } catch (_) {
      return const WidgetPlaybackSnapshot.empty();
    }
  }

  Future<void> rawWrite(String value) => _prefs.setString(key, value);
}
