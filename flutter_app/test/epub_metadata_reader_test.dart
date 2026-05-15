import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_app/services/epub_metadata_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a minimal valid EPUB archive in memory and returns the ZIP bytes.
List<int> _buildMinimalEpub({
  String title = 'Test Book',
  String author = 'Test Author',
  bool includeCover = true,
  String coverMeta = 'epub2', // 'epub2', 'epub3', or 'none'
}) {
  final archive = Archive();

  // mimetype (uncompressed, first entry — EPUB spec)
  archive.addFile(ArchiveFile(
    'mimetype',
    'application/epub+zip'.length,
    utf8.encode('application/epub+zip'),
  ));

  // META-INF/container.xml
  const containerXml = '''<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
           version="1.0">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf"
              media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';
  archive.addFile(ArchiveFile(
    'META-INF/container.xml',
    utf8.encode(containerXml).length,
    utf8.encode(containerXml),
  ));

  // Cover metadata in OPF
  final coverMetaTag = switch (coverMeta) {
    'epub2' => '<meta name="cover" content="cover-img"/>',
    _ => '',
  };

  final coverProperties = coverMeta == 'epub3' ? ' properties="cover-image"' : '';
  final coverItemId = coverMeta == 'epub3' ? 'cover-img-3' : 'cover-img';
  final coverItem = includeCover
      ? '<item id="$coverItemId" href="images/cover.png" media-type="image/png"$coverProperties/>'
      : '';

  final opfXml = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
    <dc:creator>$author</dc:creator>
    $coverMetaTag
  </metadata>
  <manifest>
    $coverItem
    <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
</package>''';
  archive.addFile(ArchiveFile(
    'OEBPS/content.opf',
    utf8.encode(opfXml).length,
    utf8.encode(opfXml),
  ));

  // Minimal PNG (1x1 red pixel)
  if (includeCover) {
    final pngBytes = _minimal1x1Png();
    archive.addFile(ArchiveFile(
      'OEBPS/images/cover.png',
      pngBytes.length,
      pngBytes,
    ));
  }

  return ZipEncoder().encode(archive);
}

/// 1x1 red PNG — smallest valid PNG image.
List<int> _minimal1x1Png() {
  return base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4'
    'nGP4z8BQDwAEgAF/pooBPQAAAABJRU5ErkJggg==',
  );
}

Future<File> _writeTempFile(String name, List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp('epub_meta_test_');
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes);
  return f;
}

void main() {
  test('returns empty metadata for non-existent file', () async {
    final result = await readEpubMetadata('/tmp/does_not_exist_12345.epub');
    expect(result.title, isNull);
    expect(result.author, isNull);
    expect(result.coverBase64, isNull);
  });

  test('returns empty metadata for non-ZIP file', () async {
    final f = await _writeTempFile('bad.epub', utf8.encode('not a zip'));
    final result = await readEpubMetadata(f.path);
    expect(result.title, isNull);
    expect(result.author, isNull);
    expect(result.coverBase64, isNull);
  });

  test('returns empty metadata for PDF path', () async {
    final f = await _writeTempFile('doc.pdf', [0x25, 0x50, 0x44, 0x46]);
    final result = await readEpubMetadata(f.path);
    expect(result.title, isNull);
  });

  test('extracts title and author from minimal EPUB', () async {
    final bytes = _buildMinimalEpub(
      title: 'Dom Casmurro',
      author: 'Machado de Assis',
      includeCover: false,
      coverMeta: 'none',
    );
    final f = await _writeTempFile('dom.epub', bytes);
    final result = await readEpubMetadata(f.path);
    expect(result.title, 'Dom Casmurro');
    expect(result.author, 'Machado de Assis');
    expect(result.coverBase64, isNull);
  });

  test('extracts EPUB2 cover via meta name=cover', () async {
    final bytes = _buildMinimalEpub(coverMeta: 'epub2');
    final f = await _writeTempFile('cover2.epub', bytes);
    final result = await readEpubMetadata(f.path);
    expect(result.coverBase64, isNotNull);
    expect(result.coverBase64!.isNotEmpty, isTrue);
    // Verify it decodes to valid bytes
    final decoded = base64Decode(result.coverBase64!);
    expect(decoded.length, greaterThan(0));
  });

  test('extracts EPUB3 cover via properties=cover-image', () async {
    final bytes = _buildMinimalEpub(coverMeta: 'epub3');
    final f = await _writeTempFile('cover3.epub', bytes);
    final result = await readEpubMetadata(f.path);
    expect(result.coverBase64, isNotNull);
    final decoded = base64Decode(result.coverBase64!);
    expect(decoded.length, greaterThan(0));
  });

  test('handles EPUB with no cover gracefully', () async {
    final bytes = _buildMinimalEpub(includeCover: false, coverMeta: 'epub2');
    final f = await _writeTempFile('nocover.epub', bytes);
    final result = await readEpubMetadata(f.path);
    expect(result.title, 'Test Book');
    expect(result.coverBase64, isNull);
  });
}
