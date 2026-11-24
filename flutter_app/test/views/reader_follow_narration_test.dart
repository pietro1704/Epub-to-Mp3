// FLUTTER-READER-FOLLOW-NARRATION: with "follow spoken text" on, the page turns by
// itself when the spoken sentence leaves the screen (forward and back, also after
// skips), and a manual page turn suspends the following until the narration is
// visible again or the user asks to go back to the narrated page.
import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

FulltextChapter _chapter() => FulltextChapter.fromJson({
  'index': 0,
  'name': 'Capítulo 1',
  'text': List.generate(60, (i) => 'Esta é a frase número ${i + 1} do capítulo de teste.').join(' '),
});

class _Harness {
  _Harness(this.container, this.key, this.sentence, this.spans);
  final ProviderContainer container;
  final GlobalKey<State<ReaderView>> key;
  final ValueNotifier<String?> sentence;
  final List<SentenceSpan> spans;
  String idOf(int n) => spans[n - 1].id;
}

Future<_Harness> _pump(WidgetTester tester, {Map<String, Object> prefs = const {}}) async {
  SharedPreferences.setMockInitialValues({'readerLayout': 'paginated', ...prefs});
  final preferences = await SharedPreferences.getInstance();
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final chapter = _chapter();
  final spans = chapter.splitSentences();
  final key = GlobalKey<State<ReaderView>>();
  final sentence = ValueNotifier<String?>(null);
  final container = ProviderContainer(overrides: [sharedPrefsProvider.overrideWithValue(preferences)]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ValueListenableBuilder<String?>(
            valueListenable: sentence,
            builder: (_, id, _) => ReaderView(key: key, chapter: chapter, spans: spans, currentSentenceId: id),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(container, key, sentence, spans);
}

Future<void> _speak(WidgetTester tester, _Harness h, int n) async {
  h.sentence.value = h.idOf(n);
  await tester.pumpAndSettle();
}

bool _shows(int n) => find.textContaining('frase número $n do', findRichText: true).evaluate().isNotEmpty;

void main() {
  testWidgets('the page turns forward by itself when the spoken sentence leaves the screen', (tester) async {
    final h = await _pump(tester);
    expect(_shows(1), isTrue);
    await _speak(tester, h, 45);
    expect(_shows(45), isTrue, reason: 'the page that holds the spoken sentence is showing');
    expect(h.container.read(readerNarrationPairedProvider), isTrue);
  });

  testWidgets('and back when the narration goes back (skip or seek backwards)', (tester) async {
    final h = await _pump(tester);
    await _speak(tester, h, 45);
    await _speak(tester, h, 3);
    expect(_shows(3), isTrue);
  });

  testWidgets('a manual page turn suspends the following', (tester) async {
    final h = await _pump(tester);
    await _speak(tester, h, 2);
    (h.key.currentState as dynamic).advancePage();
    await tester.pumpAndSettle();
    expect(_shows(2), isFalse, reason: 'the user is on the next page');
    expect(h.container.read(readerNarrationPairedProvider), isFalse);
    await _speak(tester, h, 50);
    expect(_shows(50), isFalse, reason: 'following is suspended: the page stays where the user left it');
    expect(h.container.read(readerNarrationPairedProvider), isFalse);
  });

  testWidgets('asking to go back to the narrated page resumes the following', (tester) async {
    final h = await _pump(tester);
    await _speak(tester, h, 2);
    (h.key.currentState as dynamic).advancePage();
    await tester.pumpAndSettle();
    await _speak(tester, h, 50);
    h.container.read(readerPairRequestProvider.notifier).state++;
    await tester.pumpAndSettle();
    expect(_shows(50), isTrue);
    expect(h.container.read(readerNarrationPairedProvider), isTrue);
    await _speak(tester, h, 10);
    expect(_shows(10), isTrue, reason: 'and it keeps following');
  });

  testWidgets('with follow spoken text off the page never turns by itself', (tester) async {
    final h = await _pump(tester, prefs: {'readerAutoScroll': false});
    await _speak(tester, h, 45);
    expect(_shows(45), isFalse);
    expect(_shows(1), isTrue);
  });
}
