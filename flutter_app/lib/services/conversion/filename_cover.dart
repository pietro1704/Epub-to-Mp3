import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show Color;

import 'desktop_embedded_converter.dart';

/// A cover drawn by the client from the Rust contract: [label] in white over [background].
class FilenameCover {
  const FilenameCover({required this.label, required this.background});
  final String label;
  final Color background;
}

FilenameCover? parseFilenameCover(String? json) {
  if (json == null) return null;
  try {
    final map = jsonDecode(json) as Map;
    final rgb = (map['backgroundRgb'] as List).cast<num>();
    final label = map['label'] as String;
    if (rgb.length != 3 || label.isEmpty) return null;
    return FilenameCover(
      label: label,
      background: Color.fromARGB(
        0xff,
        rgb[0].toInt().clamp(0, 255),
        rgb[1].toInt().clamp(0, 255),
        rgb[2].toInt().clamp(0, 255),
      ),
    );
  } catch (_) {
    return null;
  }
}

typedef FilenameCoverCall = Future<String?> Function(String fileName);

/// Resolves and memoises filename covers; null where no Rust binding exists (mobile until
/// its channel lands), so the tile keeps its icon placeholder.
class FilenameCoverResolver {
  FilenameCoverResolver({FilenameCoverCall? call})
    : _call = call ?? desktopFilenameCoverJson;

  static final instance = FilenameCoverResolver(
    call: Platform.isAndroid || Platform.isIOS
        ? (String _) async => null
        : desktopFilenameCoverJson,
  );

  final FilenameCoverCall _call;
  final _cache = <String, Future<FilenameCover?>>{};

  Future<FilenameCover?> resolve(String fileName) => _cache.putIfAbsent(
    fileName,
    () async => parseFilenameCover(await _call(fileName)),
  );
}
