import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'library_store.dart';

const _maxCoverBytes = 2 * 1024 * 1024; // 2 MB

/// Reads EPUB metadata (title, author, cover image) from the file at [path].
/// Never throws — returns partial [EpubMetadata] on any error.
Future<EpubMetadata> readEpubMetadata(String path) async {
  if (!path.toLowerCase().endsWith('.epub')) return const EpubMetadata();

  try {
    final bytes = await File(path).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    return _extractFromArchive(archive);
  } catch (_) {
    return const EpubMetadata();
  }
}

EpubMetadata _extractFromArchive(Archive archive) {
  final opfPath = _findOpfPath(archive);
  if (opfPath == null) return const EpubMetadata();

  final opfFile = archive.findFile(opfPath);
  if (opfFile == null) return const EpubMetadata();

  final opfContent = utf8.decode(opfFile.content as List<int>);
  final opfDoc = XmlDocument.parse(opfContent);

  final opfDir = opfPath.contains('/')
      ? '${opfPath.substring(0, opfPath.lastIndexOf('/'))}/'
      : '';

  final title = _extractDcElement(opfDoc, 'title');
  final author = _extractDcElement(opfDoc, 'creator');
  final coverBase64 = _extractCover(opfDoc, opfDir, archive);

  return EpubMetadata(
    title: title,
    author: author,
    coverBase64: coverBase64,
  );
}

String? _findOpfPath(Archive archive) {
  final container = archive.findFile('META-INF/container.xml');
  if (container == null) return null;

  try {
    final doc = XmlDocument.parse(utf8.decode(container.content as List<int>));
    final rootfile = doc.findAllElements('rootfile').firstOrNull;
    return rootfile?.getAttribute('full-path');
  } catch (_) {
    return null;
  }
}

String? _extractDcElement(XmlDocument doc, String localName) {
  for (final el in doc.findAllElements(localName)) {
    final text = el.innerText.trim();
    if (text.isNotEmpty) return text;
  }
  // Try with dc: namespace prefix explicitly
  for (final el in doc.descendants.whereType<XmlElement>()) {
    if (el.localName == localName &&
        (el.namespaceUri == 'http://purl.org/dc/elements/1.1/' ||
            el.name.prefix == 'dc')) {
      final text = el.innerText.trim();
      if (text.isNotEmpty) return text;
    }
  }
  return null;
}

String? _extractCover(XmlDocument opfDoc, String opfDir, Archive archive) {
  final href = _findCoverHref(opfDoc);
  if (href == null) return null;

  final resolvedPath = _resolveHref(opfDir, href);

  final coverFile = archive.findFile(resolvedPath);
  if (coverFile == null) return null;

  final Uint8List imageBytes = coverFile.content;
  if (imageBytes.isEmpty) return null;
  if (imageBytes.length > _maxCoverBytes) return null;

  return base64Encode(imageBytes);
}

String? _findCoverHref(XmlDocument opfDoc) {
  // EPUB3: <item properties="cover-image" href="..."/>
  for (final item in opfDoc.findAllElements('item')) {
    final props = item.getAttribute('properties') ?? '';
    if (props.contains('cover-image')) {
      return item.getAttribute('href');
    }
  }

  // EPUB2: <meta name="cover" content="cover-id"/> -> <item id="cover-id"/>
  for (final meta in opfDoc.findAllElements('meta')) {
    if (meta.getAttribute('name') == 'cover') {
      final coverId = meta.getAttribute('content');
      if (coverId == null) continue;
      for (final item in opfDoc.findAllElements('item')) {
        if (item.getAttribute('id') == coverId) {
          final mediaType = item.getAttribute('media-type') ?? '';
          if (mediaType.startsWith('image/')) {
            return item.getAttribute('href');
          }
        }
      }
    }
  }

  return null;
}

String _resolveHref(String opfDir, String href) {
  if (href.startsWith('/')) return href.substring(1);
  final raw = '$opfDir$href';
  // Normalize ".." segments
  final segments = <String>[];
  for (final s in raw.split('/')) {
    if (s == '..') {
      if (segments.isNotEmpty) segments.removeLast();
    } else if (s != '.' && s.isNotEmpty) {
      segments.add(s);
    }
  }
  return segments.join('/');
}
