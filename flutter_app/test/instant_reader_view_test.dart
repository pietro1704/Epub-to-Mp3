import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/instant_reader_view.dart';

EbookFulltext _sampleFulltext() => EbookFulltext.fromJson({
      'jobId': 'test-job',
      'bookTitle': 'Sample Book',
      'bookAuthor': 'Author Name',
      'chapters': [
        {
          'index': 0,
          'name': 'Introduction',
          'text':
              'This is the introduction chapter with enough text to be readable. It has multiple sentences for testing purposes and more.',
        },
        {
          'index': 1,
          'name': 'Chapter 1',
          'text':
              'This is chapter one with content. It continues with more text here. And even more content for testing.',
        },
      ],
    });

Future<SharedPreferences> _mockPrefs([Map<String, Object>? seed]) async {
  SharedPreferences.setMockInitialValues(seed ?? {});
  return SharedPreferences.getInstance();
}

Widget _wrap(SharedPreferences prefs, Widget child) {
  return ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SizedBox(
        width: 400,
        height: 800,
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  group('InstantReaderView', () {
    testWidgets('renders short non-empty front matter', (t) async {
      final prefs = await _mockPrefs();
      final fulltext = EbookFulltext.fromJson({
        'jobId': 'short-front-matter',
        'chapters': [
          {'index': 0, 'name': 'Dedication', 'text': 'To Ana.'},
          {'index': 1, 'name': 'Chapter 1', 'text': 'The story begins here.'},
        ],
      });
      await t.pumpWidget(_wrap(prefs, InstantReaderView(fulltext: fulltext)));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('To Ana.'), findsOneWidget);
      expect(find.text('Dedication'), findsOneWidget);
    });

    testWidgets('shows settings button', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(fulltext: _sampleFulltext()),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.text_format), findsOneWidget);
    });

    testWidgets('renders reader content without a player bar', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(fulltext: _sampleFulltext()),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Author Name'), findsNothing);
    });

    testWidgets('does not render a play button in the reader', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(fulltext: _sampleFulltext()),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.play_circle_filled), findsNothing);
    });

    testWidgets('shows no content when fulltext is empty', (t) async {
      final prefs = await _mockPrefs();
      final empty = EbookFulltext.fromJson({
        'jobId': 'empty',
        'chapters': <Map<String, dynamic>>[],
      });
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(fulltext: empty),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('No content available'), findsOneWidget);
    });

  });
}
