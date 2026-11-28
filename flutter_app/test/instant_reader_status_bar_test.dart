// The Android status and navigation bars follow the reader chrome (iOS statusBarHidden parity,
// STATUS-BAR-WITH-CHROME): hidden with the header, and shown again when a book opens.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/instant_reader_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('system bars show on open and hide/show with the chrome', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final modes = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIOverlays') {
          modes.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
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
    // The previous book left the chrome (and the system bars) hidden.
    container.read(readerChromeVisibleProvider.notifier).state = false;
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
    expect(container.read(readerChromeVisibleProvider), isTrue);
    expect(
      modes.isNotEmpty && modes.last.toString().contains('top'),
      isTrue,
      reason: 'opening a book shows the status bar again (modes: $modes)',
    );

    modes.clear();
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(size.width / 2, size.height / 2));
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(readerChromeVisibleProvider), isFalse);
    expect(
      modes.last.toString(),
      isNot(contains('top')),
      reason: 'hiding the chrome hides the status bar (modes: $modes)',
    );
  });
}
