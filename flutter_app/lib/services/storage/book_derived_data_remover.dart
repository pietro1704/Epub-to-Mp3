import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../playback/audio_player_interface.dart';
import 'local_fulltext_cache.dart';

/// Removes everything the app derived from a book once the book leaves the
/// library: the cached fulltext, the generated audiobook folder, saved reading
/// and listening positions and local conversion jobs. The imported book file
/// itself and installed voice models are never touched, and it is a no-op for
/// an identity that is not a plain id so it can never build a path outside the
/// app-owned audiobook root.
class BookDerivedDataRemover {
  BookDerivedDataRemover({
    required this.prefs,
    required this.fulltextCache,
    required this.documents,
  });

  final SharedPreferences prefs;
  final LocalFulltextCache fulltextCache;
  final Future<Directory> Function() documents;

  static final _plainId = RegExp(r'^[A-Za-z0-9_-]+$');

  /// Preference keys that belong to [bookId], by exact key or exact prefix.
  static bool ownsKey(String key, String bookId) =>
      key == 'readPos_ch_$bookId' ||
      key == 'readPos_pg_$bookId' ||
      key == 'readPos_sourceChapter_$bookId' ||
      key == 'readPos_offset_$bookId' ||
      key.startsWith('resume:book:$bookId:') ||
      key.startsWith('resume:local-$bookId:') ||
      key.startsWith('resume:listen-$bookId-') ||
      key.startsWith('local-conversion.v1:$bookId:');

  /// Stops [player] first when it is playing this book, so nothing keeps
  /// reading files that are about to be deleted.
  Future<void> remove(String bookId, {AudioPlayerInterface? player}) async {
    if (!_plainId.hasMatch(bookId)) return;
    if (player != null && player.currentBookId == bookId) {
      try {
        await player.pause();
        await player.setQueue(const []);
      } catch (_) {
        // The files below are removed regardless.
      }
      player.currentBookId = null;
    }
    for (final key in prefs.getKeys().where((key) => ownsKey(key, bookId)).toList()) {
      await prefs.remove(key);
    }
    await fulltextCache.evict(bookId);
    await _removeAudiobooks(bookId);
  }

  Future<void> _removeAudiobooks(String bookId) async {
    try {
      final target = Directory('${(await documents()).path}/audiobooks/$bookId');
      // Only a real directory owned by the app; a link is never followed.
      if (await FileSystemEntity.type(target.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        await target.delete(recursive: true);
      }
    } catch (_) {
      // Derived data is rebuildable; a locked file must not block removal.
    }
  }
}
