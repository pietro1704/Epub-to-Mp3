// The rich (HTML) reader follows the narration too: the page turns to the spoken
// sentence, forward and back; a manual page turn suspends it; a request to go
// back to the narrated page resumes it.
import 'package:flutter/material.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/features/reader/rich_reader_surface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _paragraphs = List.generate(40, (i) => 'Esta é a frase número ${i + 1} do capítulo em HTML.');
final _text = _paragraphs.join('\n');
final _html = _paragraphs.map((p) => '<p>$p</p>').join();

TextRange _range(int n) {
  final start = _text.indexOf('frase número $n do');
  return TextRange(start: start, end: start + 20);
}

class _Rig {
  final highlight = ValueNotifier<TextRange?>(null);
  final request = ValueNotifier<int>(0);
  final paired = <bool?>[];
}

Future<_Rig> _pump(WidgetTester tester, {bool follow = true}) async {
  SharedPreferences.setMockInitialValues({'readerLayout': 'paginated'});
  final settings = MirrorAppSettings(await SharedPreferences.getInstance());
  final rig = _Rig();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 600,
            height: 400,
            child: ValueListenableBuilder<int>(
              valueListenable: rig.request,
              builder: (_, request, _) => ValueListenableBuilder<TextRange?>(
                valueListenable: rig.highlight,
                builder: (_, highlight, _) => RichReaderSurface(
                  chapter: FulltextChapter(index: 0, text: _text, html: _html),
                  settings: settings,
                  background: Colors.white,
                  foreground: Colors.black,
                  bodyStyle: const TextStyle(fontSize: 20, height: 1.6),
                  headingStyle: const TextStyle(fontSize: 24),
                  highlight: highlight,
                  followNarration: follow,
                  pairRequest: request,
                  onPairedChanged: rig.paired.add,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return rig;
}

double _offset(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(find.byKey(const ValueKey('rich-reader-viewport')))
    .controller!
    .offset;

void main() {
  testWidgets('the page turns forward to the spoken sentence', (tester) async {
    final rig = await _pump(tester);
    expect(_offset(tester), 0);
    rig.highlight.value = _range(35);
    await tester.pumpAndSettle();
    expect(_offset(tester), greaterThan(0));
    expect(rig.paired.last, isTrue);
  });

  testWidgets('and back when the narration goes back', (tester) async {
    final rig = await _pump(tester);
    rig.highlight.value = _range(35);
    await tester.pumpAndSettle();
    final far = _offset(tester);
    rig.highlight.value = _range(2);
    await tester.pumpAndSettle();
    expect(_offset(tester), lessThan(far));
    expect(_offset(tester), 0);
  });

  testWidgets('a manual page turn suspends it; asking for the narrated page resumes', (tester) async {
    final rig = await _pump(tester);
    rig.highlight.value = _range(2);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(650, 200)); // the right edge of the 600 px surface turns the page
    await tester.pumpAndSettle();
    final manual = _offset(tester);
    expect(manual, greaterThan(0));
    expect(rig.paired.last, isFalse);
    rig.highlight.value = _range(38);
    await tester.pumpAndSettle();
    expect(_offset(tester), manual, reason: 'suspended: the page stays where the user left it');
    rig.request.value++;
    await tester.pumpAndSettle();
    expect(_offset(tester), greaterThan(manual));
    expect(rig.paired.last, isTrue);
  });

  testWidgets('with follow spoken text off nothing turns by itself', (tester) async {
    final rig = await _pump(tester, follow: false);
    rig.highlight.value = _range(35);
    await tester.pumpAndSettle();
    expect(_offset(tester), 0);
  });
}
