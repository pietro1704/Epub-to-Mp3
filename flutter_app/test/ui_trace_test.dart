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

  testWidgets('the semantics snapshot lists what is on screen with its place, replacing the accessibility tree', (tester) async {
    final file = File('${dir.path}/semantics.jsonl');
    final trace = UiTrace(file.path);
    UiTrace.override(trace);
    final handle = trace.keepSemanticsOn();
    trace.startSemanticsSnapshots();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(children: [
              ElevatedButton(onPressed: () {}, child: const Text('Add a book')),
              IconButton(onPressed: () {}, tooltip: 'Show menu', icon: const Icon(Icons.more_vert)),
            ]),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final events = file.readAsLinesSync().map((l) => jsonDecode(l) as Map).where((e) => e['event'] == 'ui.semantics').toList();
    expect(events, isNotEmpty);
    final nodes = (events.last['nodes'] as List).cast<Map>();
    final add = nodes.singleWhere((n) => n['label'] == 'Add a book');
    expect(add['button'], isTrue);
    expect(nodes.where((n) => n['label'] == 'Show menu' && n['button'] == true), hasLength(1),
        reason: 'an icon button is found by its tooltip');
    expect(add['width'] as num, greaterThan(20));
    expect(add['height'] as num, greaterThan(20));
    expect(add['left'] as num, greaterThan(0), reason: 'a place in logical pixels, from the window origin');
    expect(events.last['dpr'], isA<num>());
    handle?.dispose();
  });
}
