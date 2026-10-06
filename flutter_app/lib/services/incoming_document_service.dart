import 'dart:async';

import 'package:flutter/services.dart';

/// A document copied by the Android host into app-private storage.
class IncomingDocument {
  const IncomingDocument({required this.path, required this.displayName});

  final String path;
  final String displayName;

  factory IncomingDocument.fromMap(Map<dynamic, dynamic> map) {
    return IncomingDocument(
      path: map['path'] as String? ?? '',
      displayName: map['displayName'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IncomingDocument &&
      other.path == path &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(path, displayName);
}

typedef IncomingDocumentImport =
    Future<void> Function(IncomingDocument document);
typedef IncomingDocumentLoader = Future<List<IncomingDocument>> Function();
typedef IncomingDocumentAcknowledger =
    Future<void> Function(IncomingDocument document);

/// Bridges Android's durable copied-file queue to the library.
///
/// The injected stream/loader/callbacks make lifecycle and retry behavior
/// testable without a platform channel. Failed imports are deliberately not
/// acknowledged, so the native queue can retry them on the next launch.
class IncomingDocumentService {
  IncomingDocumentService({
    required this.importCallback,
    IncomingDocumentLoader? pendingLoader,
    Stream<IncomingDocument>? eventStream,
    IncomingDocumentAcknowledger? acknowledgeCallback,
  }) : _pendingLoader = pendingLoader ?? _loadPendingFromPlatform,
       _eventStream = eventStream ?? _platformEvents,
       _acknowledge = acknowledgeCallback ?? _acknowledgeOnPlatform;

  static const _channel = MethodChannel('epub_to_mp3/incoming_documents');
  static const _events = EventChannel('epub_to_mp3/incoming_documents/events');

  final IncomingDocumentImport importCallback;
  final IncomingDocumentLoader _pendingLoader;
  final Stream<IncomingDocument> _eventStream;
  final IncomingDocumentAcknowledger _acknowledge;

  StreamSubscription<IncomingDocument>? _subscription;
  final Set<String> _known = <String>{};
  Future<void> _tail = Future<void>.value();
  bool _started = false;

  /// Completes after all documents queued so far have been processed,
  /// including stream events already scheduled on the current microtask turn.
  Future<void> get idle async {
    await Future<void>.delayed(Duration.zero);
    await _tail;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _subscription = _eventStream.listen(_enqueue, onError: (_) {});
    try {
      for (final document in await _pendingLoader()) {
        _enqueue(document);
      }
    } on MissingPluginException {
      // The Android bridge is intentionally absent on desktop/iOS targets.
    } on PlatformException {
      // A platform without the Android queue behaves like an empty queue.
    }
  }

  void _enqueue(IncomingDocument document) {
    if (document.path.isEmpty) return;
    final key = '${document.path}\u0000${document.displayName}';
    if (!_known.add(key)) return;
    _tail = _tail.then((_) async {
      try {
        await importCallback(document);
        await _acknowledge(document);
      } catch (_) {
        _known.remove(key);
      }
    });
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
  }

  static Future<List<IncomingDocument>> _loadPendingFromPlatform() async {
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'getPendingDocuments',
    );
    return (raw ?? const <dynamic>[])
        .whereType<Map<dynamic, dynamic>>()
        .map(IncomingDocument.fromMap)
        .where((document) => document.path.isNotEmpty)
        .toList(growable: false);
  }

  static Stream<IncomingDocument> get _platformEvents => _events
      .receiveBroadcastStream()
      .where((value) => value is Map<dynamic, dynamic>)
      .map((value) => IncomingDocument.fromMap(value as Map<dynamic, dynamic>));

  static Future<void> _acknowledgeOnPlatform(IncomingDocument document) {
    return _channel.invokeMethod<void>('acknowledgeDocument', {
      'path': document.path,
      'displayName': document.displayName,
    });
  }
}
