// Mirror of ios/EpubToMp3/EpubToMp3/Services/LocalFulltextCache.swift @ b7c962a
//
// On-disk cache of `EbookFulltext` payloads keyed by bookId. The Swift
// side lives under `~/Library/Caches/<bundle>/fulltext/`. We use
// `path_provider`'s `getTemporaryDirectory()` (or
// `getApplicationCacheDirectory()` when available) — same semantics on
// Linux/Windows/Android: contents are evictable by the OS.
//
// All operations swallow errors — the worst case is one extra re-parse
// next launch.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/ebook_fulltext.dart';
import 'rebuildable_cache_policy.dart';

class LocalFulltextCache {
  LocalFulltextCache({
    Future<Directory> Function()? directoryProvider,
    this.maxBytes = 128 * 1024 * 1024,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectoryProvider;

  final Future<Directory> Function() _directoryProvider;
  final int maxBytes;

  static Future<Directory> _defaultDirectoryProvider() async {
    Directory base;
    try {
      base = await getApplicationCacheDirectory();
    } catch (_) {
      base = await getTemporaryDirectory();
    }
    final dir = Directory('${base.path}/fulltext');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File?> _fileFor(String bookId) async {
    final safe = bookId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (safe.isEmpty) return null;
    final dir = await _directoryProvider();
    return File('${dir.path}/$safe.json');
  }

  /// Returns the cached payload if present + decodable; null otherwise.
  Future<EbookFulltext?> read(String bookId) async {
    try {
      final f = await _fileFor(bookId);
      if (f == null || !await f.exists()) return null;
      final txt = await f.readAsString();
      await _touch(f);
      final map = jsonDecode(txt) as Map<String, dynamic>;
      return EbookFulltext.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  /// Best-effort save. Atomic so a crash mid-write can't corrupt.
  Future<void> save(EbookFulltext payload, String bookId) async {
    try {
      final f = await _fileFor(bookId);
      if (f == null) return;
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(payload.toJson()));
      await tmp.rename(f.path);
      await _touch(f);
      await _reclaimRebuildableBytes(f.parent);
    } catch (_) {
      // intentionally ignored
    }
  }

  Future<void> evict(String bookId) async {
    try {
      final f = await _fileFor(bookId);
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {
      // intentionally ignored
    }
  }

  Future<void> _touch(File file) async {
    try {
      await File(
        '${file.path}.last_access',
      ).writeAsString(DateTime.now().toUtc().toIso8601String(), flush: true);
    } catch (_) {}
  }

  Future<void> _reclaimRebuildableBytes(Directory directory) async {
    try {
      final entries = <RebuildableCacheEntry>[];
      await for (final entity in directory.list()) {
        if (entity is! File ||
            !entity.path.endsWith('.json') ||
            entity.path.endsWith('.tmp')) {
          continue;
        }
        final stat = await entity.stat();
        final marker = File('${entity.path}.last_access');
        final accessed = await marker.exists()
            ? DateTime.tryParse(await marker.readAsString())
            : stat.modified;
        entries.add(
          RebuildableCacheEntry(
            key: entity.path,
            bytes: stat.size,
            lastAccessedAt: (accessed ?? stat.modified).toUtc(),
          ),
        );
      }
      final plan = RebuildableCachePolicy(
        maxBytes: maxBytes,
      ).evictionPlan(entries);
      for (final path in plan) {
        await File(path).delete();
        final marker = File('$path.last_access');
        if (await marker.exists()) await marker.delete();
      }
    } catch (_) {}
  }
}
