import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../storage/library_store.dart';
import 'desktop_embedded_converter.dart';

/// Returns the library metadata JSON produced by the shared Rust converter for
/// a book path, or null when it cannot be read.
typedef LibraryMetadataSource = Future<String?> Function(String path);

/// Reads EPUB metadata (title, author, cover) through the shared Rust reader:
/// the embedded converter channel on Android and converter-ffi on desktop.
/// Never throws — returns empty [EpubMetadata] on any error.
Future<EpubMetadata> readEpubMetadata(String path) =>
    readEpubMetadataFrom(path, _platformLibraryMetadata);

Future<EpubMetadata> readEpubMetadataFrom(
  String path,
  LibraryMetadataSource source,
) async {
  if (!path.toLowerCase().endsWith('.epub')) return const EpubMetadata();
  try {
    final raw = await source(path);
    if (raw == null || raw.isEmpty) return const EpubMetadata();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return const EpubMetadata();
    String? text(String key) {
      final value = decoded[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    return EpubMetadata(
      title: text('title'),
      author: text('author'),
      coverBase64: text('coverBase64'),
    );
  } catch (_) {
    return const EpubMetadata();
  }
}

const _embeddedConverterChannel = MethodChannel('epub_to_mp3/embedded_converter');

Future<String?> _platformLibraryMetadata(String path) {
  if (Platform.isAndroid) {
    return _embeddedConverterChannel.invokeMethod<String>(
      'libraryMetadata',
      {'inputPath': path},
    );
  }
  return desktopLibraryMetadataJson(path);
}
