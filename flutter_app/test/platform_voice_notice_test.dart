import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/platform_voice_notice.dart';
import 'dart:async';

void main() {
  test('voice change notice tells the user about the offline substitution', () {
    expect(platformVoiceNotice('pt'), contains('Voz local temporária'));
    expect(platformVoiceNotice('es'), contains('Voz local temporal'));
    expect(platformVoiceNotice('en'), contains('Temporary local voice'));
  });

  test(
    'scopes notices to active request and resets for another conversion',
    () async {
      final events = StreamController<dynamic>.broadcast(sync: true);
      final session = PlatformVoiceNoticeSession(events: events.stream);
      var warnings = 0;
      final subscription = session.listen(() => warnings++);
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
}
