import 'package:flutter/foundation.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

/// Register the Linux/Windows decoder before any AudioPlayer is constructed.
/// Android keeps its platform player and Apple clients remain native Swift.
void initializeDesktopAudioBackend(TargetPlatform platform) {
  if (!kIsWeb &&
      (platform == TargetPlatform.linux ||
          platform == TargetPlatform.windows)) {
    JustAudioMediaKit.ensureInitialized(
      linux: platform == TargetPlatform.linux,
      windows: platform == TargetPlatform.windows,
      // A local chapter stream can wait for the next synthesized MP3 chunk.
      networkTimeout: platform == TargetPlatform.windows
          ? const Duration(seconds: 20)
          : null,
    );
  }
}
