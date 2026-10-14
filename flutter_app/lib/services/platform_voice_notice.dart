import 'package:flutter/services.dart';
import 'dart:async';

const _channel = EventChannel('epub_to_mp3/platform_voice');

final Stream<dynamic> platformVoiceChanges = _channel.receiveBroadcastStream();

/// One request owns its warning; unrelated books and repeated chunks are ignored.
class PlatformVoiceNoticeSession {
  PlatformVoiceNoticeSession({Stream<dynamic>? events})
    : _events = events ?? platformVoiceChanges;
  final Stream<dynamic> _events;
  String? _inputPath;
  bool _shown = false;

  void begin(String inputPath) {
    _inputPath = inputPath;
    _shown = false;
  }

  void end() {
    _inputPath = null;
  }

  StreamSubscription<dynamic> listen(void Function() onNotice) =>
      _events.listen((event) {
        if (event is! Map ||
            event['engine'] != 'system' ||
            event['inputPath'] != _inputPath ||
            _inputPath == null ||
            _shown) {
          return;
        }
        _shown = true;
        onNotice();
      }, onError: (Object _) {});
}

String platformVoiceNotice(String languageCode) => switch (languageCode) {
  'pt' => 'Edge indisponível. Voz local temporária neste trecho.',
  'es' => 'Edge no disponible. Voz local temporal en este fragmento.',
  _ => 'Edge unavailable. Temporary local voice for this segment.',
};
