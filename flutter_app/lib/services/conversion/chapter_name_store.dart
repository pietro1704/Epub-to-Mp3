import 'dart:convert';
import 'dart:io' show Directory, Platform;

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'desktop_embedded_converter.dart';

/// Per-book chapter name overrides, persisted by Rust. Keys are the parsed chapter indexes.
abstract class ChapterNameStore {
  Future<Map<int, String>> load(String bookId);

  /// A null or blank [name] restores the automatic name.
  Future<Map<int, String>> set(String bookId, int chapterIndex, String? name);
}

Map<int, String> parseChapterNames(String? json) {
  if (json == null) return const {};
  try {
    final names = (jsonDecode(json) as Map)['names'] as Map;
    return {
      for (final entry in names.entries)
        if (int.tryParse('${entry.key}') != null)
          int.parse('${entry.key}'): '${entry.value}',
    };
  } catch (_) {
    return const {};
  }
}

typedef ChapterNamesCall = Future<String?> Function(
  String path, {
  String? index,
  String? name,
});

/// Rust-backed store: one overrides file per book under the app support directory.
class RustChapterNameStore implements ChapterNameStore {
  RustChapterNameStore({
    ChapterNamesCall? call,
    Future<String> Function()? directory,
  }) : _call =
           call ??
           ((path, {index, name}) =>
               _platformChapterNames(path, index: index, name: name)),
       _directory = directory ?? _supportDirectory;

  final ChapterNamesCall _call;
  final Future<String> Function() _directory;

  static Future<String> _supportDirectory() async =>
      '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}chapter-names';

  Future<String> _path(String bookId) async {
    final directory = await _directory();
    await Directory(directory).create(recursive: true);
    return '$directory${Platform.pathSeparator}${Uri.encodeComponent(bookId)}.json';
  }

  @override
  Future<Map<int, String>> load(String bookId) async =>
      parseChapterNames(await _call(await _path(bookId)));

  @override
  Future<Map<int, String>> set(
    String bookId,
    int chapterIndex,
    String? name,
  ) async => parseChapterNames(
    await _call(await _path(bookId), index: '$chapterIndex', name: name),
  );
}

const _channel = MethodChannel('epub_to_mp3/embedded_converter');

Future<String?> _platformChapterNames(
  String path, {
  String? index,
  String? name,
}) {
  if (Platform.isAndroid) {
    return _channel.invokeMethod<String>('chapterNames', {
      'path': path,
      'index': index,
      'name': name,
    });
  }
  return desktopChapterNamesJson(path, index: index, name: name);
}

/// Null where no Rust binding exists yet (iOS): no rename UI.
ChapterNameStore? defaultChapterNameStore() =>
    Platform.isIOS ? null : RustChapterNameStore();
