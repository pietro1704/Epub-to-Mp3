import 'package:flutter/services.dart';

import 'voice_audition.dart';

/// Renders one voice sample through the Android embedded converter (JNI). The request id
/// names the native cancellation control, so stopping the sample stops the synthesis.
AuditionRender androidVoiceAuditionRender(MethodChannel channel) {
  var counter = 0;
  return (optionsJson, text, output, cancel) async {
    final request =
        'voice-audition-${DateTime.now().microsecondsSinceEpoch}-${counter++}';
    cancel.onCancel = () =>
        channel.invokeMethod<void>('cancelVoiceAudition', {'request': request});
    try {
      await channel.invokeMethod<String>('voiceAudition', {
        'request': request,
        'optionsJson': optionsJson,
        'text': text,
        'output': output,
      });
    } on PlatformException catch (error) {
      if (cancel.isCancelled) return;
      throw StateError(
        error.message ?? 'The voice sample could not be rendered.',
      );
    } finally {
      cancel.onCancel = null;
    }
  };
}
