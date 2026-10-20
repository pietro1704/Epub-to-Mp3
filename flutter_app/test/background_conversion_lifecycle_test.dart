import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/background_conversion_scheduler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/background-lifecycle');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'cancel targets the persisted job identity and propagates native result',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return false;
      });
      expect(
        await BackgroundConversionScheduler(
          channel: channel,
        ).cancel('job-with-voice-snapshot'),
        false,
      );
      expect(calls.single.method, 'cancel');
      expect(calls.single.arguments, {'jobId': 'job-with-voice-snapshot'});
    },
  );

  test(
    'unsupported platforms never dispatch background conversion to another backend',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return true;
      });
      final scheduler = BackgroundConversionScheduler(channel: channel);
      expect(
        await scheduler.enqueueChapter(
          jobId: 'job',
          inputPath: '/book.epub',
          chapterIndex: 1,
          outputPath: '/audio',
          optionsJson: '{}',
        ),
        false,
      );
      expect(await scheduler.cancel('job'), false);
      expect(calls, 0);
    },
  );
}
