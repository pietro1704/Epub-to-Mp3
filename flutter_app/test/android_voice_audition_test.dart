import 'package:flutter/services.dart';
import 'package:flutter_app/services/conversion/android_voice_audition.dart';
import 'package:flutter_app/services/conversion/voice_audition.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/embedded_converter');
  final calls = <MethodCall>[];

  tearDown(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'renders through the voiceAudition channel method with a request id',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return '/out/preview.mp3';
          });
      await androidVoiceAuditionRender(channel)(
        '{"a":1}',
        'Olá',
        '/out/preview.mp3',
        AuditionCancellation(),
      );
      final args = calls.single.arguments as Map;
      expect(calls.single.method, 'voiceAudition');
      expect(args['optionsJson'], '{"a":1}');
      expect(args['text'], 'Olá');
      expect(args['output'], '/out/preview.mp3');
      expect((args['request'] as String).startsWith('voice-audition-'), isTrue);
    },
  );

  test(
    'cancelling sends cancelVoiceAudition with the same request id',
    () async {
      String? started;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'voiceAudition') {
              started = (call.arguments as Map)['request'] as String;
              await Future<void>.delayed(const Duration(milliseconds: 30));
              throw PlatformException(code: 'X', message: 'cancelled');
            }
            return null;
          });
      final cancel = AuditionCancellation();
      final render = androidVoiceAuditionRender(channel)(
        '{}',
        'a',
        '/o.mp3',
        cancel,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      cancel.cancel();
      await render;
      final stop = calls.firstWhere((c) => c.method == 'cancelVoiceAudition');
      expect((stop.arguments as Map)['request'], started);
    },
  );

  test(
    'a native failure that is not a cancellation surfaces its message',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'E', message: 'model missing');
          });
      await expectLater(
        androidVoiceAuditionRender(channel)(
          '{}',
          'a',
          '/o.mp3',
          AuditionCancellation(),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'model missing',
          ),
        ),
      );
    },
  );
}
