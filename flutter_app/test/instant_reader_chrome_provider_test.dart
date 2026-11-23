// Opening a book while the reader chrome is hidden (the previous book hid it) used to
// modify a provider during initState: "Tried to modify a provider while the widget tree
// was building" and the red error screen in debug builds (seen on the SM-X620).
import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/instant_reader_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'opening a book with the chrome hidden does not modify a provider while building',
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
            'text': 'A reasonably long chapter text for the reader. It has two sentences.',
          },
        ],
      });
      final container = ProviderContainer(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      // The previous book hid the chrome, and a shell widget watches it.
      container.read(readerChromeVisibleProvider.notifier).state = false;
      final open = ValueNotifier(false);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Consumer(
              builder: (context, ref, _) {
                final visible = ref.watch(readerChromeVisibleProvider);
                return ValueListenableBuilder<bool>(
                  valueListenable: open,
                  builder: (_, isOpen, _) => isOpen
                      ? Column(
                          children: [
                            Text('chrome $visible'),
                            Expanded(
                              child: InstantReaderView(fulltext: fulltext),
                            ),
                          ],
                        )
                      : const SizedBox(),
                );
              },
            ),
          ),
        ),
      );
      open.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(
        container.read(readerChromeVisibleProvider),
        isTrue,
        reason: 'opening a book shows the chrome',
      );
    },
  );
}
