import 'dart:async';

import 'package:flutter_app/services/incoming_document_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    test(
      'default bridge matches channel availability on $platform',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final calls = <String>[];
        const method = MethodChannel('epub_to_mp3/incoming_documents');
        const events = MethodChannel('epub_to_mp3/incoming_documents/events');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(method, (call) async {
          calls.add(call.method);
          return <dynamic>[];
        });
        messenger.setMockMethodCallHandler(events, (call) async {
          calls.add(call.method);
          return null;
        });
        final service = IncomingDocumentService(importCallback: (_) async {});
        try {
          await service.start();
          await service.idle;
          await service.dispose();
          expect(
            calls,
            platform == TargetPlatform.android
                ? ['listen', 'getPendingDocuments', 'cancel']
                : isEmpty,
          );
        } finally {
          await service.dispose();
          messenger.setMockMethodCallHandler(method, null);
          messenger.setMockMethodCallHandler(events, null);
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  test(
    'imports pending and warm-start documents with their display names',
    () async {
      final events = StreamController<IncomingDocument>();
      final imported = <IncomingDocument>[];
      final acknowledged = <IncomingDocument>[];
      final service = IncomingDocumentService(
        pendingLoader: () async => [
          const IncomingDocument(
            path: '/private/book.epub',
            displayName: 'Book.epub',
          ),
        ],
        eventStream: events.stream,
        importCallback: (document) async {
          imported.add(document);
        },
        acknowledgeCallback: (document) async {
          acknowledged.add(document);
        },
      );

      await service.start();
      events.add(
        const IncomingDocument(
          path: '/private/book.epub',
          displayName: 'Book.epub',
        ),
      );
      events.add(
        const IncomingDocument(
          path: '/private/other.pdf',
          displayName: 'Other.pdf',
        ),
      );
      await service.idle;

      expect(imported, [
        const IncomingDocument(
          path: '/private/book.epub',
          displayName: 'Book.epub',
        ),
        const IncomingDocument(
          path: '/private/other.pdf',
          displayName: 'Other.pdf',
        ),
      ]);
      expect(acknowledged, imported);
      await service.dispose();
    },
  );

  test('does not acknowledge failed imports, allowing durable retry', () async {
    final pending = StreamController<IncomingDocument>();
    var attempts = 0;
    final acknowledged = <IncomingDocument>[];
    final document = const IncomingDocument(
      path: '/private/retry.epub',
      displayName: 'Retry.epub',
    );
    final service = IncomingDocumentService(
      pendingLoader: () async => [document],
      eventStream: pending.stream,
      importCallback: (_) async {
        attempts++;
        if (attempts == 1) throw StateError('not ready');
      },
      acknowledgeCallback: (value) async => acknowledged.add(value),
    );

    await service.start();
    await service.idle;
    expect(attempts, 1);
    expect(acknowledged, isEmpty);

    pending.add(document);
    await service.idle;
    expect(attempts, 2);
    expect(acknowledged, [document]);
    await service.dispose();
  });
}
