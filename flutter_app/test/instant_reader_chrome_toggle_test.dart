// One tap on the page hides the reader header and the mini player together and the next tap
// shows both (Mac #1751, iPhone parity). The mini player follows readerChromeVisibleProvider.
import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/instant_reader_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

bool _headerVisible(WidgetTester tester) => tester
    .widget<Visibility>(
      find
          .ancestor(
            of: find.byType(BackButton),
            matching: find.byType(Visibility),
          )
          .first,
    )
    .visible;

void main() {
  testWidgets(
    'one centre tap hides header and mini player, the next shows both',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final fulltext = EbookFulltext.fromJson({
        'jobId': 'j',
        'bookTitle': 'T',
        'bookAuthor': 'A',
        'chapters': [
          {
            'index': 0,
            'name': 'Chapter',
            'text':
                'A reasonably long chapter text for the reader. Two sentences.',
          },
        ],
      });
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: InstantReaderView(fulltext: fulltext),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(_headerVisible(tester), isTrue);
      expect(container.read(readerChromeVisibleProvider), isTrue);

      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      final centre = Offset(size.width / 2, size.height / 2);
      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_headerVisible(tester), isFalse, reason: 'header hidden');
      expect(
        container.read(readerChromeVisibleProvider),
        isFalse,
        reason: 'mini player hidden',
      );

      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_headerVisible(tester), isTrue, reason: 'header shown');
      expect(
        container.read(readerChromeVisibleProvider),
        isTrue,
        reason: 'mini player shown',
      );
    },
  );
}
