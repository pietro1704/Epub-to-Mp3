import 'dart:convert';
import 'dart:io';

import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/models/tts_session_selection.dart';
import 'package:flutter_app/services/conversion/voice_audition.dart';
import 'package:flutter_test/flutter_test.dart';

final _piper = TtsSelection(
  engine: 'piper',
  modelId: 'pt_BR-faber-medium',
  session: TtsSessionSelection(
    provider: 'piper',
    runtime: 'piper',
    modelId: 'pt_BR-faber-medium',
    modelRevision: 'r1',
  ),
);
final _edge = TtsSelection(
  engine: 'edge',
  modelId: 'edge-pt',
  session: TtsSessionSelection(
    provider: 'edge',
    runtime: 'edge',
    modelId: 'edge-pt',
  ),
);

void main() {
  test('the sample text follows the language', () {
    expect(VoiceAudition.sampleText('pt-BR'), startsWith('Esta é uma amostra'));
    expect(VoiceAudition.sampleText('es'), startsWith('Esta es una muestra'));
    expect(VoiceAudition.sampleText('en-US'), startsWith('This is a sample'));
  });

  test(
    'a Piper sample asks for one voice, no fallback and no online voices',
    () {
      final options = jsonDecode(
        VoiceAudition.optionsJson(
          _piper,
          'pt',
          allowOnline: false,
          modelsRoot: '/m',
        ),
      ) as Map;
      expect(options['contract_version'], 2);
      expect(options['language'], 'pt');
      expect(options['models_root'], '/m');
      final prefs = options['tts_preferences'] as Map;
      expect(prefs['secondary'], isNull);
      expect(prefs['allow_online_fallback'], isFalse);
      expect((prefs['primary'] as Map)['model_id'], 'pt_BR-faber-medium');
    },
  );

  test('an Edge sample without the online consent never renders', () async {
    var rendered = false;
    final audition = VoiceAudition(
      render: (options, text, output, cancel) async => rendered = true,
      play: (path) async {},
      stopPlayback: () async {},
    );
    await expectLater(
      audition.start(_edge, 'pt', allowOnline: false, modelsRoot: null),
      throwsA(isA<OnlineVoiceConsentRequired>()),
    );
    expect(rendered, isFalse);
    expect(audition.state.value, VoiceAuditionState.idle);
  });

  test(
    'a consented Edge sample renders with consent and plays the file',
    () async {
      String? options;
      String? played;
      final audition = VoiceAudition(
        render: (json, text, output, cancel) async {
          options = json;
          File(output).writeAsBytesSync([1]);
        },
        play: (path) async => played = path,
        stopPlayback: () async {},
      );
      await audition.start(_edge, 'pt', allowOnline: true, modelsRoot: null);
      final prefs = (jsonDecode(options!) as Map)['tts_preferences'] as Map;
      expect(prefs['allow_online_fallback'], isTrue);
      expect(played, endsWith('preview.mp3'));
      expect(audition.state.value, VoiceAuditionState.playing);
      await audition.stop();
      expect(audition.state.value, VoiceAuditionState.idle);
      expect(
        File(played!).existsSync(),
        isFalse,
        reason: 'temporary sample removed',
      );
    },
  );

  test('a failed render reports failure and leaves nothing behind', () async {
    String? output;
    final audition = VoiceAudition(
      render: (json, text, out, cancel) async {
        output = out;
        throw StateError('boom');
      },
      play: (path) async => fail('must not play'),
      stopPlayback: () async {},
    );
    await expectLater(
      audition.start(_piper, 'pt', allowOnline: false, modelsRoot: '/m'),
      throwsStateError,
    );
    expect(audition.state.value, VoiceAuditionState.failed);
    expect(Directory(File(output!).parent.path).existsSync(), isFalse);
  });

  test('stopping while rendering cancels the render and never plays', () async {
    late AuditionCancellation token;
    final gate = Future<void>.delayed(const Duration(milliseconds: 50));
    final audition = VoiceAudition(
      render: (json, text, out, cancel) async {
        token = cancel;
        await gate;
      },
      play: (path) async => fail('must not play after stop'),
      stopPlayback: () async {},
    );
    final started = audition.start(
      _piper,
      'pt',
      allowOnline: false,
      modelsRoot: '/m',
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await audition.stop();
    await started;
    expect(token.isCancelled, isTrue);
    expect(audition.state.value, VoiceAuditionState.idle);
  });
}
