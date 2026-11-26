import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/services/playback/platform_voice_notice.dart';
import 'dart:async';

void main() {
  test('voice change notice names the system voice in every locale', () {
    expect(
      lookupAppLocalizations(const Locale('pt')).platformVoiceNotice,
      contains('voz do sistema'),
    );
    expect(
      lookupAppLocalizations(const Locale('es')).platformVoiceNotice,
      contains('voz del sistema'),
    );
    expect(
      lookupAppLocalizations(const Locale('en')).platformVoiceNotice,
      contains('system voice'),
    );
  });

  test(
    'scopes notices to active request and resets for another conversion',
    () async {
      final events = StreamController<dynamic>.broadcast(sync: true);
      final session = PlatformVoiceNoticeSession(events: events.stream);
      var warnings = 0;
      final subscription = session.listen((_) => warnings++);
      session.begin('/book-a.epub');
      events.add({'engine': 'system', 'inputPath': '/book-b.epub'});
      events.add({'engine': 'edge', 'inputPath': '/book-a.epub'});
      expect(warnings, 0);
      events.add({'engine': 'system', 'inputPath': '/book-a.epub'});
      events.add({'engine': 'system', 'inputPath': '/book-a.epub'});
      expect(warnings, 1);
      session.end();
      events.add({'engine': 'system', 'inputPath': '/book-a.epub'});
      expect(warnings, 1);
      session.begin('/book-a.epub');
      events.add({'engine': 'system', 'inputPath': '/book-a.epub'});
      expect(warnings, 2);
      await subscription.cancel();
      await events.close();
    },
  );
  test('notice carries the active system speech engine', () async {
    final events = StreamController<dynamic>.broadcast(sync: true);
    final session = PlatformVoiceNoticeSession(events: events.stream);
    final engines = <String?>[];
    final subscription = session.listen(engines.add);
    session.begin('/book.epub');
    events.add({
      'engine': 'system',
      'voiceEngine': 'com.google.android.tts',
      'inputPath': '/book.epub',
    });
    expect(engines, ['com.google.android.tts']);
    await subscription.cancel();
    await events.close();
  });
}
