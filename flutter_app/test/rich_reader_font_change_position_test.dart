// Changing the font size keeps the reader on the same passage of the text (the Mac card
// MAC-FONT-CHANGE-KEEPS-TEXT-POSITION, checked on Flutter).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/features/reader/rich_reader_surface.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _paragraphs = List.generate(
  60,
  (i) =>
      'Paragrafo ${i.toString().padLeft(2, '0')} do capitulo, com texto para ocupar varias linhas na tela do leitor de teste.',
);

void main() {
  for (final layout in ['scrolling', 'paginated']) {
    testWidgets(
      'rich reader keeps its text position when the font grows ($layout)',
      (t) async {
        SharedPreferences.setMockInitialValues({'readerLayout': layout});
        final settings = MirrorAppSettings(
          await SharedPreferences.getInstance(),
        );
        final chapter = FulltextChapter(
          index: 0,
          text: _paragraphs.join('\n'),
          html: _paragraphs.map((p) => '<p>$p</p>').join(),
        );
        int? visible;
        Widget app(double size) => MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 400,
                height: 360,
                child: RichReaderSurface(
                  chapter: chapter,
                  settings: settings,
                  background: Colors.white,
                  foreground: Colors.black,
                  bodyStyle: TextStyle(
                    fontSize: size,
                    height: 1.4,
                    color: Colors.black,
                  ),
                  headingStyle: const TextStyle(fontSize: 24),
                  onVisibleTextOffset: (offset) => visible = offset,
                ),
              ),
            ),
          ),
        );
        await t.pumpWidget(app(16));
        await t.pumpAndSettle();
        // Read well into the chapter.
        for (var i = 0; i < 12; i++) {
          if (layout == 'paginated') {
            await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          } else {
            await t.drag(find.byType(RichReaderSurface), const Offset(0, -300));
          }
          await t.pumpAndSettle();
        }
        final before = visible!;
        expect(
          before,
          greaterThan(1000),
          reason: 'the reader moved into the chapter',
        );
        visible = null;
        await t.pumpWidget(app(32));
        await t.pumpAndSettle();
        expect(
          (visible! - before).abs(),
          lessThan(300),
          reason:
              'same passage after the font change (was $before, now $visible)',
        );
      },
    );
  }
}
