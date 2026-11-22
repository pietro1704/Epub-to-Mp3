import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_app/features/library/public_book_download.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final gutenberg = Uri.https(
    'gutenberg.pglaf.org',
    '/cache/epub/11/pg11-images-3.epub',
  );
  final camara = Uri.https('bd-rest.camara.leg.br', '/book.pdf');
  late Directory directory;
  late File savedBook;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('public-book-test-');
    savedBook = await File.fromUri(directory.uri.resolve('saved.epub'))
        .writeAsString('existing book');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<void> expectUntouchedLibrary() async {
    expect(await directory.list().map((entry) => entry.path).toList(), [
      savedBook.path,
    ]);
    expect(await savedBook.readAsString(), 'existing book');
  }

  test(
    'follows an HTTPS redirect within Gutenberg and stages an EPUB',
    () async {
      final book = _epub();
      final client = _Client([
        _Response(statusCode: 302, location: '/cache/epub/76/pg76.epub'),
        _Response(body: [book]),
      ]);

      final file = await PublicBookDownload(createClient: () => client)
          .download(
            uri: gutenberg,
            format: PublicBookFormat.epub,
            directory: directory,
          );

      expect(client.requested, [
        gutenberg,
        Uri.https('gutenberg.pglaf.org', '/cache/epub/76/pg76.epub'),
      ]);
      expect(client.closed, isTrue);
      expect(file.path, endsWith('.epub'));
      expect(await file.readAsBytes(), book);
      expect(
        await directory.list().map((entry) => entry.path).toList(),
        unorderedEquals([savedBook.path, file.path]),
      );
    },
  );

  test('accepts a Câmara PDF and stages repeated downloads uniquely', () async {
    final pdf = ascii.encode('%PDF-1.7\nfixture');
    final downloader = PublicBookDownload(
      createClient: () => _Client([
        _Response(body: [pdf]),
      ]),
    );

    final files = await Future.wait([
      for (var i = 0; i < 2; i++)
        downloader.download(
          uri: camara,
          format: PublicBookFormat.pdf,
          directory: directory,
        ),
    ]);

    expect(files.map((file) => file.path).toSet(), hasLength(2));
    for (final file in files) {
      expect(file.path, endsWith('.pdf'));
      expect(await file.readAsBytes(), pdf);
    }
  });

  test('rejects unsupported hosts before constructing a client', () async {
    final downloader = PublicBookDownload(
      createClient: () => throw StateError('Network must not be used'),
    );
    await expectLater(
      downloader.download(
        uri: Uri.https('gutenberg.pglaf.org.example.com', '/book.epub'),
        format: PublicBookFormat.epub,
        directory: directory,
      ),
      throwsArgumentError,
    );
    await expectUntouchedLibrary();
  });

  test('rejects redirects from the Câmara REST API to HTML pages', () async {
    for (final host in ['bd.camara.leg.br', 'livraria.camara.leg.br']) {
      final client = _Client([
        _Response(statusCode: 302, location: 'https://$host/book'),
      ]);
      await expectLater(
        PublicBookDownload(createClient: () => client).download(
          uri: camara,
          format: PublicBookFormat.pdf,
          directory: directory,
        ),
        throwsA(isA<HttpException>()),
      );
      expect(client.requested, [camara]);
      expect(client.closed, isTrue);
      await expectUntouchedLibrary();
    }
  });

  for (final location in [
    'http://gutenberg.pglaf.org/book.epub',
    'https://www.gutenberg.org/book.epub',
    '/cache/epub/1342/pg1342-images-3.epub',
    '/cache/epub/11/pg11-images-3.epub?alternate=1',
    'https://bd-rest.camara.leg.br/book.epub',
    '//example.com/book.epub',
  ]) {
    test('rejects a redirect to $location before requesting it', () async {
      final client = _Client([_Response(statusCode: 302, location: location)]);
      await expectLater(
        PublicBookDownload(createClient: () => client).download(
          uri: gutenberg,
          format: PublicBookFormat.epub,
          directory: directory,
        ),
        throwsA(isA<HttpException>()),
      );
      expect(client.requested, [gutenberg]);
      expect(client.closed, isTrue);
      await expectUntouchedLibrary();
    });
  }

  test('caps redirect chains', () async {
    final client = _Client([
      for (var i = 0; i < 6; i++)
        _Response(statusCode: 302, location: '/cache/epub/76/pg76.epub'),
    ]);
    await expectLater(
      PublicBookDownload(createClient: () => client).download(
        uri: gutenberg,
        format: PublicBookFormat.epub,
        directory: directory,
      ),
      throwsA(isA<HttpException>()),
    );
    expect(client.requested, hasLength(6));
    await expectUntouchedLibrary();
  });

  test('rejects errors, oversized lengths and truncated bodies', () async {
    for (final (response, expectedError) in [
      (_Response(statusCode: 503), isA<HttpException>()),
      (_Response(contentLength: 101 * 1024 * 1024), isA<FormatException>()),
      (
        _Response(contentLength: 100, body: [ascii.encode('%PDF-1.7')]),
        isA<FormatException>(),
      ),
    ]) {
      final client = _Client([response]);
      await expectLater(
        PublicBookDownload(createClient: () => client).download(
          uri: camara,
          format: PublicBookFormat.pdf,
          directory: directory,
        ),
        throwsA(expectedError),
      );
      expect(client.closed, isTrue);
      await expectUntouchedLibrary();
    }
  });

  test('removes bytes staged before a response stream fails', () async {
    Stream<List<int>> disconnectedBody() async* {
      yield ascii.encode('%PDF-1.7\nfixture');
      throw const SocketException('Connection closed');
    }

    final client = _Client([_Response(stream: disconnectedBody())]);
    await expectLater(
      PublicBookDownload(createClient: () => client).download(
        uri: camara,
        format: PublicBookFormat.pdf,
        directory: directory,
      ),
      throwsA(isA<SocketException>()),
    );
    expect(client.closed, isTrue);
    await expectUntouchedLibrary();
  });

  test(
    'rejects HTML and invalid EPUB structure, removing partial files',
    () async {
      final cases = [
        (PublicBookFormat.pdf, ascii.encode('<html>Sign in</html>')),
        (PublicBookFormat.epub, _epub(includeContainer: false)),
        (PublicBookFormat.epub, _epub(packagePath: 'missing.opf')),
        (PublicBookFormat.epub, _epub(containerXml: '<unclosed>')),
        (PublicBookFormat.epub, _epub().take(45).toList()),
      ];

      for (final (format, body) in cases) {
        await expectLater(
          PublicBookDownload(
            createClient: () => _Client([
              _Response(body: [body]),
            ]),
          ).download(uri: gutenberg, format: format, directory: directory),
          throwsFormatException,
        );
        await expectUntouchedLibrary();
      }
    },
  );
}

List<int> _epub({
  bool includeContainer = true,
  String packagePath = 'OEBPS/book.opf',
  String? containerXml,
}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.noCompress(
        'mimetype',
        20,
        ascii.encode('application/epub+zip'),
      ),
    );
  if (includeContainer) {
    archive.addFile(
      ArchiveFile.string(
        'META-INF/container.xml',
        containerXml ??
            '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="$packagePath" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''',
      ),
    );
  }
  archive.addFile(ArchiveFile.string('OEBPS/book.opf', '<package/>'));
  return ZipEncoder().encode(archive);
}

class _Client implements HttpClient {
  _Client(this.responses);

  final List<_Response> responses;
  final requested = <Uri>[];
  bool closed = false;

  @override
  Duration? connectionTimeout;

  @override
  bool autoUncompress = true;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final response = responses[requested.length];
    requested.add(url);
    return _Request(response);
  }

  @override
  void close({bool force = false}) {
    expect(force, isTrue);
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.response);

  final _Response response;

  @override
  bool followRedirects = true;

  @override
  final HttpHeaders headers = _Headers();

  @override
  Future<HttpClientResponse> close() async {
    expect(followRedirects, isFalse);
    expect(headers.value(HttpHeaders.acceptEncodingHeader), 'identity');
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response({
    this.statusCode = 200,
    this.contentLength = -1,
    String? location,
    this.body = const [],
    this.stream,
  }) {
    if (location != null) {
      headers.set(HttpHeaders.locationHeader, location);
    }
  }

  final List<List<int>> body;
  final Stream<List<int>>? stream;

  @override
  final int statusCode;

  @override
  final int contentLength;

  @override
  final HttpHeaders headers = _Headers();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => (stream ?? Stream<List<int>>.fromIterable(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  final _values = <String, String>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name] = value as String;
  }

  @override
  String? value(String name) => _values[name];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
