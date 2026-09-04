import 'package:flutter/services.dart';

/// Prevents a new protected-audio write when device storage is already low.
///
/// The guard deliberately never reclaims completed audio. Callers surface the
/// recoverable error and let the listener choose what to remove.
class ProtectedAudioStorageError implements Exception {
  const ProtectedAudioStorageError(this.requiredBytes, this.availableBytes);

  final int requiredBytes;
  final int availableBytes;

  @override
  String toString() => 'Not enough storage for protected audio';
}

class ProtectedAudioStorageGuard {
  ProtectedAudioStorageGuard({
    Future<int?> Function()? availableBytes,
    this.reserveBytes = 64 * 1024 * 1024,
  }) : _availableBytes = availableBytes ?? _platformAvailableBytes;

  final Future<int?> Function() _availableBytes;
  final int reserveBytes;
  static const MethodChannel _channel = MethodChannel('epub_to_mp3/storage');

  static Future<int?> _platformAvailableBytes() async {
    try {
      return await _channel.invokeMethod<int>('availableBytes');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> ensureCanRetain({required int estimatedBytes}) async {
    final available = await _availableBytes();
    if (available == null) return;
    final required = reserveBytes + estimatedBytes;
    if (available < required) {
      throw ProtectedAudioStorageError(required, available);
    }
  }

  static int estimateChapterAudioBytes(String text) {
    const minimum = 8 * 1024 * 1024;
    const maximum = 128 * 1024 * 1024;
    return (text.length * 8).clamp(minimum, maximum).toInt();
  }
}
