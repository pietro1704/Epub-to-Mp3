import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html;

/// Adds presentation resources to Rust-owned chapter identities and text.
/// Never changes synthesis text, chapter indices or conversion behavior.
abstract final class EpubReaderResources {
  static Future<Map<String, dynamic>> enrich(
    Map<String, dynamic> metadata,
    String path,
  ) => Isolate.run(() => enrichSync(metadata, path));

  static Map<String, dynamic> enrichSync(
    Map<String, dynamic> metadata,
    String path,
  ) {
    metadata['bookTitle'] ??= metadata['title'];
    metadata['bookAuthor'] ??= metadata['author'];
    if (!path.toLowerCase().endsWith('.epub')) return metadata;
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() > 64 * 1024 * 1024) {
      return metadata;
    }
    final archive = ZipDecoder().decodeBytes(
      file.readAsBytesSync(),
      verify: true,
    );
    var budget = 128 * 1024 * 1024;
    List<int>? read(String name) {
      if (name.startsWith('/') || name.split('/').contains('..')) return null;
      final entry = archive.findFile(name);
      if (entry == null ||
          !entry.isFile ||
          entry.size > 32 * 1024 * 1024 ||
          entry.size > budget) {
        return null;
      }
      budget -= entry.size;
      return entry.content;
    }

    String? resolve(String from, String reference) {
      final uri = Uri.tryParse(reference);
      if (uri == null || uri.hasScheme || reference.startsWith('//')) {
        return null;
      }
      return Uri(path: from).resolveUri(uri).path;
    }

    String? resource(String from, String reference) {
      final target = resolve(from, reference);
      final bytes = target == null ? null : read(target);
      if (bytes == null) return null;
      final mime = switch (target!.split('.').last.toLowerCase()) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'gif' => 'image/gif',
        'svg' => 'image/svg+xml',
        'ttf' => 'font/ttf',
        'otf' => 'font/otf',
        'woff' => 'font/woff',
        _ => 'application/octet-stream',
      };
      return 'data:$mime;base64,${base64Encode(bytes)}';
    }

    for (final entry in metadata['chapters'] as List? ?? const []) {
      if (entry is! Map || entry['sourcePath'] is! String) continue;
      final source = entry['sourcePath'] as String;
      final bytes = read(source);
      if (bytes == null) continue;
      final document = html.parse(utf8.decode(bytes, allowMalformed: true));
      final css = <String>[];
      for (final link in document.querySelectorAll('link[rel="stylesheet"]')) {
        final target = resolve(source, link.attributes['href'] ?? '');
        final stylesheet = target == null ? null : read(target);
        if (stylesheet == null) continue;
        final styles = utf8
            .decode(stylesheet, allowMalformed: true)
            .replaceAllMapped(
              RegExp(r'''url\(\s*["']?([^\s)"']+)["']?\s*\)'''),
              (match) => 'url("${resource(target!, match[1]!) ?? match[1]}")',
            );
        css.add(styles);
      }
      css.addAll(
        document.querySelectorAll('style').map((element) => element.text),
      );
      for (final image in document.querySelectorAll('img[src]')) {
        final original = image.attributes['src']!;
        final embedded = resource(source, original);
        if (embedded != null) image.attributes['src'] = embedded;
      }
      // Cross-document links retain their href for the reader's link resolver.
      // Embedded scripts and remote resources never execute in flutter_html.
      entry['html'] = document.outerHtml;
      entry['css'] = css.join('\n');
      entry['charCount'] = entry['textChars'];
    }
    return metadata;
  }
}
