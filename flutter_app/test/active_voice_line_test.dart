import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/active_voice_line.dart';
import 'package:flutter_app/services/conversion/active_voice_log.dart';

String _line(String engine, {String model = '', String voice = ''}) =>
    '[Rust] unix_ms=1 elapsed_ms=1 since_event_ms=1 state=running chapter=Some(0) completed=0 '
    'total=1 percent=1.0 engine=${engine.isEmpty ? 'None' : 'Some("$engine")'} model_id="$model" '
    'voice="$voice" cached_segments=0 eta_seconds=None converting\n';

Widget _host(String? log, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: ActiveVoiceLine(log: log)),
);

void main() {
  test(
    'the last progress line that names an engine wins; unnamed lines keep it',
    () {
      final voice = activeVoiceFromLog(
        _line('piper', model: 'pt_BR-faber-medium') +
            _line('system', voice: 'Luciana') +
            _line(''),
      );
      expect(voice?.engine, 'system');
      expect(voice?.voice, 'Luciana');
      expect(activeVoiceFromLog(_line('')), isNull);
      expect(activeVoiceFromLog(''), isNull);
    },
  );

  testWidgets('a running conversion names the active voice', (tester) async {
    await tester.pumpWidget(_host(_line('piper', model: 'pt_BR-faber-medium')));
    expect(
      find.text('Active voice: Piper · pt_BR-faber-medium'),
      findsOneWidget,
    );
  });

  testWidgets('a system voice is labelled as such', (tester) async {
    await tester.pumpWidget(_host(_line('system', voice: 'Luciana')));
    expect(find.text('Active voice: Luciana (system voice)'), findsOneWidget);
  });

  testWidgets('the line is localized and absent before any engine is named', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_line('system', voice: 'Luciana'), locale: const Locale('pt')),
    );
    expect(find.text('Voz ativa: Luciana (voz do sistema)'), findsOneWidget);
    await tester.pumpWidget(_host(_line('')));
    expect(find.textContaining('Active voice'), findsNothing);
  });
}
