// Mirror of ios/EpubToMp3/EpubToMp3/Models/BookEntity.swift @ b7c962a
//
// One book in the user's local library. Library is the hero UI on the
// Apple side; we mirror the data shape + status logic so the Flutter
// LibraryStore can persist the same JSON layout under
// `library.books.v1` in SharedPreferences.
//
// Differences vs Swift:
//   - `bookmark` (security-scoped bookmark Data) has no Flutter
//     equivalent. We persist the absolute file path instead. macOS /
//     iOS aren't supported targets for the Flutter app (see project
//     scope memory), so the sandbox bookmark concept is moot here.
//   - `coverPNG` -> base64-encoded String, since SharedPreferences
//     cannot store raw bytes directly.

import 'dart:convert';

enum LibraryStatus { textOnly, caching, offlineReady }

extension LibraryStatusX on LibraryStatus {
  String get rawValue => switch (this) {
        LibraryStatus.textOnly => 'textOnly',
        LibraryStatus.caching => 'caching',
        LibraryStatus.offlineReady => 'offlineReady',
      };
}

class BookEntity {
  /// Stable id derived from the SHA-256 of the EPUB file contents.
  final String id;
  String title;
  String? author;

  /// Absolute path on disk. Flutter does not have iOS-style
  /// security-scoped bookmarks; if the file is gone the UI re-prompts.
  String filePath;

  /// Display-only filename. Use [filePath] for I/O.
  final String displayFilename;

  final DateTime addedAt;
  DateTime? lastOpenedAt;

  int? lastChapterIndex;
  double? lastPositionSeconds;

  /// PNG/JPEG bytes for cover art, base64-encoded for prefs storage.
  String? coverBase64;

  /// Most recent conversion jobId, to reattach to backend audio assets.
  String? lastJobId;

  /// User opted in to caching audio offline.
  bool cachedOffline;

  BookEntity({
    required this.id,
    required this.title,
    this.author,
    required this.filePath,
    required this.displayFilename,
    required this.addedAt,
    this.lastOpenedAt,
    this.lastChapterIndex,
    this.lastPositionSeconds,
    this.coverBase64,
    this.lastJobId,
    this.cachedOffline = false,
  });

  LibraryStatus get status {
    if (cachedOffline) return LibraryStatus.offlineReady;
    if (lastJobId != null) return LibraryStatus.caching;
    return LibraryStatus.textOnly;
  }

  String get resolvedTitle {
    final t = title.trim();
    return t.isEmpty ? displayFilename : t;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (author != null) 'author': author,
        'filePath': filePath,
        'displayFilename': displayFilename,
        'addedAt': addedAt.toIso8601String(),
        if (lastOpenedAt != null)
          'lastOpenedAt': lastOpenedAt!.toIso8601String(),
        if (lastChapterIndex != null) 'lastChapterIndex': lastChapterIndex,
        if (lastPositionSeconds != null)
          'lastPositionSeconds': lastPositionSeconds,
        if (coverBase64 != null) 'coverBase64': coverBase64,
        if (lastJobId != null) 'lastJobId': lastJobId,
        'cachedOffline': cachedOffline,
      };

  factory BookEntity.fromJson(Map<String, dynamic> json) => BookEntity(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        author: json['author'] as String?,
        filePath: json['filePath'] as String? ?? '',
        displayFilename: json['displayFilename'] as String? ?? '',
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        lastOpenedAt: json['lastOpenedAt'] is String
            ? DateTime.tryParse(json['lastOpenedAt'] as String)
            : null,
        lastChapterIndex: (json['lastChapterIndex'] as num?)?.toInt(),
        lastPositionSeconds:
            (json['lastPositionSeconds'] as num?)?.toDouble(),
        coverBase64: json['coverBase64'] as String?,
        lastJobId: json['lastJobId'] as String?,
        cachedOffline: json['cachedOffline'] as bool? ?? false,
      );

  String encode() => jsonEncode(toJson());

  static BookEntity decode(String s) =>
      BookEntity.fromJson(jsonDecode(s) as Map<String, dynamic>);
}
