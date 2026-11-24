import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/services/ui_trace.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// EPUB2MP3_UI_TRACE: a verification-only record of what the app shows, read by
/// the packaged Windows journey instead of scraping the accessibility tree.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ui-trace-'));
  tearDown(() {
    UiTrace.override(null);
    dir.deleteSync(recursive: true);
  });

  test('writes one JSON line per event, with the text head bounded', () {
    final file = File('${dir.path}/trace.jsonl');
    final trace = UiTrace(file.path);
    trace.emit('reader.chapter', {'index': 1, 'name': 'O mapa', 'head': 'x' * 500});
    trace.emit('library.books', {'titles': ['A', 'B']});
    final lines = file.readAsLinesSync().map((l) => jsonDecode(l) as Map).toList();
    expect(lines.map((l) => l['event']), ['reader.chapter', 'library.books']);
    expect(lines.first['index'], 1);
    expect((lines.first['head'] as String).length, lessThanOrEqualTo(200));
    expect(lines.last['titles'], ['A', 'B']);
    expect(lines.first['t'], isA<int>());
  });

  test('without a path nothing is written and nothing can fail', () {
    final trace = UiTrace(null);
    expect(trace.enabled, isFalse);
    trace.emit('reader.chapter', {'index': 0});
    expect(dir.listSync(), isEmpty);
  });

  test('tracing keeps the semantics tree on; without a trace it does nothing', () {
    expect(UiTrace(null).keepSemanticsOn(), isNull);
    final handle = UiTrace('${dir.path}/s.jsonl').keepSemanticsOn();
    expect(handle, isNotNull, reason: 'a held semantics handle keeps the tree on');
    handle!.dispose();
  });

  testWidgets('the reader reports the chapter it shows', (tester) async {
    final file = File('${dir.path}/reader.jsonl');
    UiTrace.override(UiTrace(file.path));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final chapter = FulltextChapter.fromJson({
      'index': 3,
      'name': 'O mapa antigo',
      'text': 'um mapa antigo, dobrado em quatro. Outra frase.',
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SizedBox(
            width: 400,
            height: 800,
            child: Scaffold(
              body: ReaderView(chapter: chapter, spans: chapter.splitSentences()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final events = file.readAsLinesSync().map((l) => jsonDecode(l) as Map).toList();
    final shown = events.singleWhere((e) => e['event'] == 'reader.chapter');
    expect(shown['index'], 3);
    expect(shown['name'], 'O mapa antigo');
    expect(shown['head'], startsWith('um mapa antigo, dobrado'));
  });
}
