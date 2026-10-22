import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'dart:convert';
import 'package:flutter_app/services/embedded_converter.dart';
import 'package:flutter_app/services/local_conversion_job.dart';
import 'package:flutter_app/services/rust_playback_conversion.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'rust_playback_voice_policy_cases.dart';
part 'rust_playback_resume_cases.dart';
part 'rust_playback_window_cases.dart';

class FakeRustConverter extends UnavailableEmbeddedConverter {
  final List<int> requested = [];
  final List<String?> capturedOptions = [];
  Completer<void>? chapterThreeStarted;
  Completer<void>? releaseChapterThree;

  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) async {
    requested.add(chapterIndex);
    capturedOptions.add(optionsJson);
    if (chapterIndex == 3 && releaseChapterThree != null) {
      chapterThreeStarted?.complete();
      await releaseChapterThree!.future;
    }
    final directory = Directory(outputPath)..createSync(recursive: true);
    final file = File('${directory.path}/chapter.mp3')
      ..writeAsBytesSync([chapterIndex, 0x49, 0x44, 0x33]);
    return ConvertedChapterAudio(
      chapterIndex: chapterIndex,
      path: file.path,
      title: 'Chapter $chapterIndex',
    );
  }
}

class CancellableBlockingConverter extends FakeRustConverter
    implements CancellableEmbeddedConverter {
  final started = Completer<void>();
  final blocked = Completer<ConvertedChapterAudio>();
  final cancelledOutputs = <String>[];
  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) async {
    if (chapterIndex != 0) {
      return super.convertChapter(
        inputPath: inputPath,
        outputPath: outputPath,
        chapterIndex: chapterIndex,
        optionsJson: optionsJson,
      );
    }
    requested.add(chapterIndex);
    capturedOptions.add(optionsJson);
    started.complete();
    return blocked.future;
  }

  @override
  Future<void> cancelConversion({String? inputPath, String? outputPath}) async {
    cancelledOutputs.add(outputPath!);
    if (!blocked.isCompleted) {
      blocked.completeError(
        EmbeddedConversionFailure('CANCELLED', 'Conversion cancelled'),
      );
    }
  }
}

class PolicyMetadataConverter extends FakeRustConverter {
  PolicyMetadataConverter({this.reportFallback = true});
  final bool reportFallback;
  @override
  Future<ConvertedChapterAudio> convertChapter({
    required String inputPath,
    required String outputPath,
    required int chapterIndex,
    String? optionsJson,
  }) async {
    final result = await super.convertChapter(
      inputPath: inputPath,
      outputPath: outputPath,
      chapterIndex: chapterIndex,
      optionsJson: optionsJson,
    );
    return ConvertedChapterAudio(
      chapterIndex: result.chapterIndex,
      path: result.path,
      title: result.title,
      usedSelections: const [
        TtsSelection(engine: 'edge', voice: 'pt-BR-FranciscaNeural'),
      ],
      fallbackUsed: reportFallback,
      ttsPolicyState: chapterIndex == 0
          ? {'consecutive_failures': 1}
          : {'consecutive_failures': 2},
    );
  }
}

List<FulltextChapter> _chapters() => [
  for (var index = 0; index < 8; index++)
    FulltextChapter(index: index, name: 'Chapter $index', text: 'Text $index'),
];

Future<ConversionJobCoordinator> _coordinator() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ConversionJobCoordinator(LocalConversionJobStore(prefs));
}

void main() {
  registerRustPlaybackVoicePolicyCases();
  registerRustPlaybackResumeCases();
  registerRustPlaybackWindowCases();
}
