import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import 'conversion/local_conversion_record.dart';

/// The chapter audio files of [job] that are finished and still on disk, in chapter order
/// (the 16e shares exactly the audio that is available).
List<String> availableAudioPaths(LocalConversionJob? job) {
  if (job == null) return const [];
  final chapters = [...job.chapters]..sort((a, b) => a.index.compareTo(b.index));
  return [
    for (final chapter in chapters)
      if (chapter.status == 'completed' &&
          chapter.outputPath != null &&
          File(chapter.outputPath!).existsSync())
        chapter.outputPath!,
  ];
}

/// Opens the platform share sheet for audio files.
abstract class AudioSharer {
  Future<void> share(List<String> paths, {required String title});
}

class SharePlusAudioSharer implements AudioSharer {
  const SharePlusAudioSharer();

  @override
  Future<void> share(List<String> paths, {required String title}) async {
    await SharePlus.instance.share(
      ShareParams(
        title: title,
        subject: title,
        files: [for (final path in paths) XFile(path, mimeType: 'audio/mpeg')],
      ),
    );
  }
}

final audioSharerProvider = Provider<AudioSharer>((ref) => const SharePlusAudioSharer());
