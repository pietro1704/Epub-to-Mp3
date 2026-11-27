import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/screens/library_screen.dart'
    show libraryStoreProvider;
import 'package:flutter_app/services/conversion/audio_export.dart';
import 'package:flutter_app/services/conversion/local_conversion_record.dart';
import 'package:flutter_app/services/storage/library_store.dart';
import 'package:flutter_app/services/storage/local_conversion_store.dart';
import 'package:flutter_app/state/providers.dart';

Future<void> _pump(
  WidgetTester t, {
  required String audioName,
  required AudioExporter exporter,
  String? folder = '/chosen',
  String filePath = '/books/hamlet.epub',
  LibraryStore Function(SharedPreferences prefs)? library,
}) async {
  final dir = Directory.systemTemp.createTempSync('manual-actions');
  addTearDown(() => dir.deleteSync(recursive: true));
  final audio = File('${dir.path}/$audioName')..writeAsBytesSync([1]);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await LocalConversionJobStore(prefs).save(
    LocalConversionJob(
      bookId: filePath,
      jobId: 'job-1',
      status: LocalConversionJobStatus.completed,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      chapters: [
        LocalConversionChapter(
          index: 0,
          name: 'Act I',
          status: 'completed',
          outputPath: audio.path,
        ),
      ],
    ),
  );
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        if (library != null)
          libraryStoreProvider.overrideWith((_) => library(prefs)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ManualConversionActions(
            filePath: filePath,
            bookId: filePath,
            jobId: 'job-1',
            exporter: exporter,
            chooseFolder: () async => folder,
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('offers adding to the library and exports one file per chapter', (
    t,
  ) async {
    Map<String, dynamic>? request;
    await _pump(
      t,
      audioName: 'one.mp3',
      exporter: AudioExporter(
        call: (json) async {
          request = jsonDecode(json) as Map<String, dynamic>;
          return jsonEncode({
            'files': ['/chosen/01 - Act I.mp3'],
          });
        },
      ),
    );
    expect(find.text('Add to library'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('manual-export-audio')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('export-per-chapter')));
    await t.pumpAndSettle();
    expect(request?['layout'], 'perChapter');
    expect(request?['destination'], '/chosen');
    expect(request?['title'], 'hamlet');
    expect(find.text('1 file exported.'), findsOneWidget);
  });

  testWidgets('says MP3 export needs Piper when the audio is not MP3', (
    t,
  ) async {
    await _pump(
      t,
      audioName: 'one.wav',
      exporter: AudioExporter(call: (_) async => fail('must not export')),
    );
    expect(
      find.byKey(const ValueKey('manual-export-needs-piper')),
      findsOneWidget,
    );
    final button = t.widget<OutlinedButton>(
      find.byKey(const ValueKey('manual-export-audio')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('cancelling the folder picker exports nothing', (t) async {
    await _pump(
      t,
      audioName: 'one.mp3',
      folder: null,
      exporter: AudioExporter(call: (_) async => fail('must not export')),
    );
    await t.tap(find.byKey(const ValueKey('manual-export-audio')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('export-single')));
    await t.pumpAndSettle();
    expect(find.textContaining('exported'), findsNothing);
  });

  testWidgets('adds the book to the library and links the audio job to it', (
    t,
  ) async {
    final dir = Directory.systemTemp.createTempSync('manual-add');
    addTearDown(() => dir.deleteSync(recursive: true));
    final book = File('${dir.path}/hamlet.epub')
      ..writeAsStringSync('synthetic');
    late LibraryStore store;
    await _pump(
      t,
      audioName: 'one.mp3',
      filePath: book.path,
      library: (prefs) => store = LibraryStore(
        prefs: prefs,
        metadataReader: (_) async => const EpubMetadata(title: 'Hamlet'),
      ),
      exporter: AudioExporter(call: (_) async => fail('must not export')),
    );
    expect(store.books, isEmpty);
    await t.tap(find.byKey(const ValueKey('manual-add-to-library')));
    // Hashing the file is real I/O: let it finish outside the fake clock.
    for (var i = 0; i < 20 && store.books.isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    await t.pumpAndSettle();

    expect(store.books, hasLength(1));
    final added = store.books.single;
    expect(added.filePath, book.path);
    expect(added.lastJobId, 'local-${added.id}');
    expect(find.text('Added to the library with its audio.'), findsOneWidget);
    expect(find.byKey(const ValueKey('manual-add-to-library')), findsNothing);
    final linked = await LocalConversionJobStore(
      await SharedPreferences.getInstance(),
    ).load(added.id, 'local-${added.id}');
    expect(linked?.chapters.single.name, 'Act I');
  });
}
