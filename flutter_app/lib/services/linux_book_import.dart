import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef LinuxBookBatchHandler = Future<void> Function(
  List<String> paths, {
  required bool openInReader,
});

class LinuxBookImport {
  static const channel = MethodChannel('epub_to_mp3/linux_book_import');

  static bool get isAvailable =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  static Future<List<String>> choose({
    required String title,
    required String cancel,
    required String accept,
  }) async =>
      await channel.invokeListMethod<String>('chooseBooks', {
        'title': title,
        'cancel': cancel,
        'accept': accept,
      }) ??
      const [];

  static Future<List<String>> paste() async =>
      await channel.invokeListMethod<String>('pasteBooks') ?? const [];

  LinuxBookImport(this.onBatch);

  final LinuxBookBatchHandler onBatch;
  Future<void> _pending = Future<void>.value();

  Future<void> start() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'booksAvailable') await _drain();
    });
    return _drain();
  }

  Future<void> _drain() => _pending = _pending.then((_) async {
    try {
      final batches = await channel.invokeListMethod<Object?>('takePending');
      for (final batch in batches ?? const []) {
        if (batch case {
          'paths': final List<Object?> paths,
          'open': final bool open,
        }) {
          await onBatch(paths.whereType<String>().toList(), openInReader: open);
        }
      }
    } on MissingPluginException {
      // A detached Flutter engine has no Linux runner channel.
    }
  });

  void dispose() => channel.setMethodCallHandler(null);
}
