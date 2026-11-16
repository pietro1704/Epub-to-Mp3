import 'dart:io';

class LocalAudioEntry {
  const LocalAudioEntry(this.category, this.id, this.bytes);
  final String category, id;
  final int bytes;
}

/// Only app-owned listening/download directories are eligible for explicit
/// removal. Original books, model installations and arbitrary export paths are
/// outside this module's interface.
class LocalAudioStorage {
  LocalAudioStorage(this.documents);
  final Directory documents;
  static const categories = ['audiobooks', 'downloads'];

  Future<List<LocalAudioEntry>> scan() async {
    final entries = <LocalAudioEntry>[];
    for (final category in categories) {
      final root = Directory('${documents.path}/$category');
      if (await FileSystemEntity.type(root.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      await for (final child in root.list(followLinks: false)) {
        if (child is! Directory) continue;
        var bytes = 0;
        await for (final entity in child.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) bytes += await entity.length();
        }
        entries.add(
          LocalAudioEntry(
            category,
            child.uri.pathSegments.where((segment) => segment.isNotEmpty).last,
            bytes,
          ),
        );
      }
    }
    return entries;
  }

  Future<bool> remove(
    LocalAudioEntry entry, {
    required Set<String> activeIds,
  }) async {
    if (!categories.contains(entry.category) ||
        activeIds.contains(entry.id) ||
        entry.id.isEmpty ||
        entry.id == '.' ||
        entry.id == '..' ||
        entry.id.contains(RegExp(r'[/\\\x00]'))) {
      return false;
    }
    final root = Directory('${documents.path}/${entry.category}');
    final target = Directory('${root.path}/${entry.id}');
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    final canonicalRoot = await root.resolveSymbolicLinks();
    final canonicalTarget = await target.resolveSymbolicLinks();
    final canonicalDocuments = await documents.resolveSymbolicLinks();
    if (!canonicalRoot.startsWith(
          '$canonicalDocuments${Platform.pathSeparator}',
        ) ||
        !canonicalTarget.startsWith(
          '$canonicalRoot${Platform.pathSeparator}',
        )) {
      return false;
    }
    await target.delete(recursive: true);
    return true;
  }
}
