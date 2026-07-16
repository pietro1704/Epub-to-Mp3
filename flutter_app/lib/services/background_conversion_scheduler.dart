import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class BackgroundConversionScheduler {
  BackgroundConversionScheduler({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('epub_to_mp3/background_conversion');

  final MethodChannel _channel;

  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  Future<bool> enqueueChapter({
    required String jobId,
    required String text,
    required String voice,
    required String outputPath,
  }) async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('enqueueChapter', {
          'jobId': jobId,
          'text': text,
          'voice': voice,
          'outputPath': outputPath,
        }) ??
        false;
  }

  Future<bool> cancel(String jobId) async {
    if (!isSupported) return false;
    return await _channel.invokeMethod<bool>('cancel', {'jobId': jobId}) ?? false;
  }
}
