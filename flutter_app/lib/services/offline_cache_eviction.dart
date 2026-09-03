import 'dart:io';

import 'package:path_provider/path_provider.dart';

// MARK: - Configuration constants

/// Maximum on-device cache budget for downloaded audiobooks (bytes).
/// Default 2 GB.
const int kDefaultOfflineCacheBudgetBytes = 2 * 1024 * 1024 * 1024;

/// Maximum age (seconds) before a cached audiobook entry is evicted.
/// Default 24 hours.
const int kDefaultOfflineCacheTTLSeconds = 24 * 60 * 60;

// MARK: - AudiobookCacheEntry

/// Snapshot of one on-disk audiobook entry for the eviction algorithm.
class AudiobookCacheEntry {
  const AudiobookCacheEntry({
    required this.jobId,
    required this.totalBytes,
    required this.lastAccessedAt,
  });

  final String jobId;
  final int totalBytes;
  final DateTime lastAccessedAt;
}

// MARK: - OfflineCacheEviction

/// Legacy cache-maintenance entry point for the Flutter offline audiobook cache.
///
/// **Layout:** `<documents>/downloads/<jobId>/` — mirrors [DownloadManager].
///
/// **Last-access tracking:** A sidecar file `.last_access` (ISO-8601 UTC)
/// lives inside each jobId folder. Call [touchLastAccess] when playback
/// opens a book.
///
/// **Testability:** All public methods accept an optional [downloadsRoot]
/// override so tests can operate on a temp directory without mocking
/// `path_provider` at the platform level.
///
/// Completed streamed audio and manual downloads are listener-owned offline
/// media. Automatic TTL/LRU cleanup must never remove them; explicit delete
/// actions use [deleteJob] instead.
class OfflineCacheEviction {
  OfflineCacheEviction._();

  // MARK: Root folder

  static Future<Directory> _resolveRoot(Directory? override) async {
    if (override != null) {
      final root = Directory('${override.path}/downloads');
      if (!await root.exists()) await root.create(recursive: true);
      return root;
    }
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/downloads');
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  static File _lastAccessFile(Directory root, String jobId) =>
      File('${root.path}/$jobId/.last_access');

  // MARK: Last-access sidecar

  /// Write a UTC ISO-8601 timestamp into the `.last_access` sidecar.
  /// Pass [downloadsRoot] in tests to avoid the real documents directory.
  static Future<void> touchLastAccess(
    String jobId, {
    Directory? downloadsRoot,
  }) async {
    try {
      final root = await _resolveRoot(downloadsRoot);
      final file = _lastAccessFile(root, jobId);
      await file.writeAsString(
        DateTime.now().toUtc().toIso8601String(),
        flush: true,
      );
    } catch (_) {
      // Best-effort — never crash the caller.
    }
  }

  static Future<DateTime?> _readLastAccess(Directory root, String jobId) async {
    try {
      final file = _lastAccessFile(root, jobId);
      if (!await file.exists()) return null;
      final raw = (await file.readAsString()).trim();
      return DateTime.tryParse(raw)?.toUtc();
    } catch (_) {
      return null;
    }
  }

  // MARK: Entry scan

  /// Enumerate all jobId subfolders under `downloads/`. Returns entries
  /// sorted oldest-accessed first (LRU order).
  /// Pass [downloadsRoot] in tests to avoid the real documents directory.
  static Future<List<AudiobookCacheEntry>> scanEntries({
    Directory? downloadsRoot,
  }) async {
    final root = await _resolveRoot(downloadsRoot);
    final entries = <AudiobookCacheEntry>[];

    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final jobId = entity.path.split(Platform.pathSeparator).last;
      // Skip hidden / dot-folders.
      if (jobId.startsWith('.')) continue;

      final totalBytes = await _folderSize(entity);
      final lastAccess =
          await _readLastAccess(root, jobId) ?? await _folderMtime(entity);
      entries.add(
        AudiobookCacheEntry(
          jobId: jobId,
          totalBytes: totalBytes,
          lastAccessedAt: lastAccess,
        ),
      );
    }

    // LRU: oldest first.
    entries.sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));
    return entries;
  }

  // MARK: Total cached bytes

  /// Sum of all entry sizes.
  /// Pass [downloadsRoot] in tests to avoid the real documents directory.
  static Future<int> totalCachedBytes({Directory? downloadsRoot}) async {
    final entries = await scanEntries(downloadsRoot: downloadsRoot);
    return entries.fold<int>(0, (s, e) => s + e.totalBytes);
  }

  // MARK: Eviction

  /// Legacy automatic maintenance hook. It deliberately performs no deletion.
  ///
  /// - [budgetBytes]: max total cache size; default [kDefaultOfflineCacheBudgetBytes].
  /// - [ttlSeconds]: max age in seconds; default [kDefaultOfflineCacheTTLSeconds].
  /// - [activeJobIds]: job IDs currently playing or downloading — never evicted.
  /// - [downloadsRoot]: override the root directory (for tests).
  ///
  /// Returns the list of evicted jobIds. Individual delete failures are swallowed.
  static Future<List<String>> runEviction({
    int budgetBytes = kDefaultOfflineCacheBudgetBytes,
    int ttlSeconds = kDefaultOfflineCacheTTLSeconds,
    Set<String> activeJobIds = const {},
    Directory? downloadsRoot,
  }) async {
    // Keep the signature while callers migrate to explicit storage management.
    // Referencing inputs avoids hiding stale call sites behind unused warnings.
    final _ = (budgetBytes, ttlSeconds, activeJobIds, downloadsRoot);
    return const [];
  }

  // MARK: Delete

  /// Delete the entire folder for [jobId].
  /// Pass [downloadsRoot] in tests to avoid the real documents directory.
  static Future<bool> deleteJob(
    String jobId, {
    Directory? downloadsRoot,
  }) async {
    final root = await _resolveRoot(downloadsRoot);
    return _deleteJob(root, jobId);
  }

  static Future<bool> _deleteJob(Directory root, String jobId) async {
    try {
      final folder = Directory('${root.path}/$jobId');
      if (await folder.exists()) {
        await folder.delete(recursive: true);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  // MARK: Helpers

  /// Recursive byte count of a directory.
  static Future<int> _folderSize(Directory dir) async {
    var total = 0;
    try {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          try {
            final stat = await entity.stat();
            total += stat.size;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// Best mtime for a folder (modification time of the folder itself).
  static Future<DateTime> _folderMtime(Directory dir) async {
    try {
      final stat = await dir.stat();
      return stat.modified.toUtc();
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  }
}
