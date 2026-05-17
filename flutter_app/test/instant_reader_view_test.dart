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

    testWidgets('shows author in bottom bar', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(fulltext: _sampleFulltext()),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Author Name'), findsOneWidget);
    });

    testWidgets('shows play button when onRequestPlay provided', (t) async {
      final prefs = await _mockPrefs();
      var tapped = false;
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(
          fulltext: _sampleFulltext(),
          onRequestPlay: () => tapped = true,
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
      await t.tap(find.byIcon(Icons.play_circle_filled));
      expect(tapped, isTrue);
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

    testWidgets('error banner shows warning icon', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(
          fulltext: _sampleFulltext(),
          statusBanner: 'Conversion failed',
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('converting banner shows progress indicator', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(
          fulltext: _sampleFulltext(),
          statusBanner: 'Converting 2/3',
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('headphones icon shown when no cover art', (t) async {
      final prefs = await _mockPrefs();
      await t.pumpWidget(_wrap(
        prefs,
        InstantReaderView(fulltext: _sampleFulltext()),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.headphones), findsOneWidget);
    });
  });
}
