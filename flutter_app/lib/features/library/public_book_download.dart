import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

enum PublicBookFormat { epub, pdf }

const _gutenbergMirrorHost = 'gutenberg.pglaf.org';

const gutenbergEpubUrls = {
  11: 'https://$_gutenbergMirrorHost/cache/epub/11/pg11-images-3.epub',
  76: 'https://$_gutenbergMirrorHost/cache/epub/76/pg76.epub',
  1342: 'https://$_gutenbergMirrorHost/cache/epub/1342/pg1342.epub',
  57001: 'https://$_gutenbergMirrorHost/cache/epub/57001/pg57001-images-3.epub',
};

class PublicBookDownload {
  PublicBookDownload({HttpClient Function()? createClient})
    : _createClient = createClient ?? HttpClient.new;

  static const _maxBytes = 100 * 1024 * 1024;
  static const _maxRedirects = 5;
  static const _idleTimeout = Duration(seconds: 20);
  static const _transferTimeout = Duration(minutes: 3);
  static const _providerHosts = <Set<String>>[
    {_gutenbergMirrorHost},
    {'bd-rest.camara.leg.br'},
  ];
  static final _gutenbergEpubUris = gutenbergEpubUrls.values
      .map(Uri.parse)
      .toSet();

  final HttpClient Function() _createClient;

  /// Returns a validated staging file. The caller owns its promotion or removal.
  Future<File> download({
    required Uri uri,
    required PublicBookFormat format,
    required Directory directory,
  }) async {
    final provider = _providerHosts.indexWhere(
      (hosts) => _isAllowed(uri, hosts),
    );
    if (provider < 0) {
      throw ArgumentError.value(uri, 'uri', 'Unsupported public book source');
    }

    final client = _createClient();
    File? partial;
    try {
      client
        ..connectionTimeout = _idleTimeout
        ..autoUncompress = false;
      final clock = Stopwatch()..start();
      final response = await _open(
        client,
        uri,
        _providerHosts[provider],
        clock,
      );
      final length = response.contentLength;
      if (length == 0 || length > _maxBytes) {
        throw const FormatException('Public book download has an invalid size');
      }

      await directory.create(recursive: true);
      final name = 'public-book-${const Uuid().v4()}';
      final staging = File.fromUri(directory.uri.resolve('$name.part'));
      await staging.create(exclusive: true);
      partial = staging;
      await _write(response, partial, clock);
      if (format == PublicBookFormat.epub) {
        await _validateEpub(staging.path);
      } else {
        await _validatePdf(partial);
      }
      final file = await partial.rename(
        directory.uri.resolve('$name.${format.name}').toFilePath(),
      );
      partial = null;
      return file;
    } finally {
      client.close(force: true);
      if (partial != null && await partial.exists()) {
        await partial.delete();
      }
    }
  }

  static bool _isAllowed(Uri uri, Set<String> hosts) =>
      uri.scheme == 'https' &&
      hosts.contains(uri.host) &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      (uri.host != _gutenbergMirrorHost || _gutenbergEpubUris.contains(uri));

  Future<HttpClientResponse> _open(
    HttpClient client,
    Uri uri,
    Set<String> allowedHosts,
    Stopwatch clock,
  ) async {
    for (var redirects = 0; redirects <= _maxRedirects; redirects++) {
      final request = await client.getUrl(uri).timeout(_remaining(clock));
      request
        ..followRedirects = false
        ..headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(_remaining(clock));
      switch (response.statusCode) {
        case HttpStatus.ok:
          return response;
        case HttpStatus.movedPermanently:
        case HttpStatus.found:
        case HttpStatus.seeOther:
        case HttpStatus.temporaryRedirect:
        case HttpStatus.permanentRedirect:
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null || location.isEmpty) {
            throw const HttpException('Public book redirect has no location');
          }
          uri = uri.resolve(location);
          if (!_isAllowed(uri, allowedHosts)) {
            throw const HttpException('Public book redirect left its source');
          }
          await response.listen(null).cancel().timeout(_remaining(clock));
        default:
          throw HttpException(
            'Public book request returned HTTP ${response.statusCode}',
          );
      }
    }
    throw const HttpException('Too many public book redirects');
  }

  static Duration _remaining(Stopwatch clock) {
    final remaining = _transferTimeout - clock.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException('Public book download timed out');
    }
    return remaining < _idleTimeout ? remaining : _idleTimeout;
  }

  Future<void> _write(
    HttpClientResponse response,
    File partial,
    Stopwatch clock,
  ) async {
    final output = await partial.open(mode: FileMode.write);
    final chunks = StreamIterator(response);
    try {
      var received = 0;
      while (await chunks.moveNext().timeout(_remaining(clock))) {
        final chunk = chunks.current;
        received += chunk.length;
        if (received > _maxBytes) {
          throw const FormatException('Public book download is too large');
        }
        await output.writeFrom(chunk);
      }
      if (received == 0 ||
          (response.contentLength >= 0 && received != response.contentLength)) {
        throw const FormatException('Public book download is incomplete');
      }
      await output.flush();
    } finally {
      try {
        await chunks.cancel();
      } finally {
        await output.close();
      }
    }
  }

  static Future<void> _validatePdf(File file) async {
    final input = await file.open();
    try {
      final header = ascii.decode(await input.read(8), allowInvalid: true);
      if (!RegExp(r'^%PDF-[0-9]\.[0-9]$').hasMatch(header)) {
        throw const FormatException('Public book is not a PDF');
      }
    } finally {
      await input.close();
    }
  }

  static Future<void> _validateEpub(String path) =>
      Isolate.run(() => _validateEpubSync(path));

  static void _validateEpubSync(String path) {
    final input = InputFileStream(path);
    try {
      final directory = ZipDirectory();
      ZipFileHeader? mimetype;
      ZipFileHeader? container;
      for (final entry in directory.headers(input, verify: true)) {
        switch (entry.filename) {
          case 'mimetype':
            if (mimetype != null) {
              throw const FormatException(
                'EPUB has duplicate mimetype entries',
              );
            }
            mimetype = entry;
          case 'META-INF/container.xml':
            if (container != null) {
              throw const FormatException('EPUB has duplicate containers');
            }
            container = entry;
        }
      }
      if (mimetype == null ||
          mimetype.localHeaderOffset != 0 ||
          mimetype.compressionMethod != 0 ||
          mimetype.uncompressedSize != 20 ||
          mimetype.compressedSize != 20 ||
          utf8.decode(_readEpubEntry(mimetype)) != 'application/epub+zip' ||
          container == null ||
          container.uncompressedSize <= 0 ||
          container.uncompressedSize > 64 * 1024 ||
          container.compressedSize > 128 * 1024) {
        throw const FormatException('Public book is not an EPUB');
      }
      final rootFiles = _readEpubRootFiles(container);
      if (!directory
          .headers(input, verify: true, files: false)
          .any(
            (entry) =>
                entry.uncompressedSize > 0 &&
                rootFiles.contains(entry.filename),
          )) {
        throw const FormatException('EPUB package is missing');
      }
    } on XmlException {
      throw const FormatException('Public book has an invalid EPUB container');
    } on ArchiveException {
      throw const FormatException('Public book has an invalid EPUB archive');
    } finally {
      input.closeSync();
    }
  }

  static Set<String> _readEpubRootFiles(ZipFileHeader container) {
    const namespace = 'urn:oasis:names:tc:opendocument:xmlns:container';
    final root = XmlDocument.parse(utf8.decode(_readEpubEntry(container)))
        .rootElement;
    if (root.localName != 'container' || root.namespaceUri != namespace) {
      throw const FormatException('EPUB container has an invalid root element');
    }
    return {
      for (final list in root.findElements(
        'rootfiles',
        namespaceUri: namespace,
      ))
        for (final entry in list.findElements(
          'rootfile',
          namespaceUri: namespace,
        ))
          if (entry.getAttribute('media-type') ==
              'application/oebps-package+xml')
            if (entry.getAttribute('full-path') case final String path) path,
    };
  }

  static List<int> _readEpubEntry(ZipFileHeader entry) {
    final file = entry.file!;
    file
      ..verify = true
      ..throwOnError = true;
    return ArchiveFile.file(
      entry.filename,
      entry.uncompressedSize,
      file,
    ).content;
  }
}
