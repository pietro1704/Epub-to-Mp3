import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/services/background_conversion_scheduler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'background request persists source chapter and captured local policy',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const channel = MethodChannel('test/background-tts');
      MethodCall? captured;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return true;
      });
      try {
        final options = const TtsPreferences().optionsJson(
          modelsRoot: '/models',
        );
        expect(
          await BackgroundConversionScheduler(channel: channel).enqueueChapter(
            jobId: 'job',
            inputPath: '/book.epub',
            chapterIndex: 2,
            outputPath: '/audio',
            optionsJson: options,
          ),
          true,
        );
        final args = Map<String, dynamic>.from(captured!.arguments as Map);
        expect(args['inputPath'], '/book.epub');
        expect(args['chapterIndex'], 2);
        expect(
          jsonDecode(
            args['optionsJson'],
          )['tts_preferences']['primary']['model_id'],
          'pt_BR-faber-medium',
        );
        expect(args.containsKey('backendUrl'), false);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
