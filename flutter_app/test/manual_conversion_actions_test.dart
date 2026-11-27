import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/services/conversion/audio_export.dart';
import 'package:flutter_app/services/conversion/local_conversion_record.dart';
import 'package:flutter_app/services/storage/local_conversion_store.dart';
import 'package:flutter_app/state/providers.dart';

Future<void> _pump(
  WidgetTester t, {
  required String audioName,
  required AudioExporter exporter,
  String? folder = '/chosen',
}) async {
  final dir = Directory.systemTemp.createTempSync('manual-actions');
  addTearDown(() => dir.deleteSync(recursive: true));
  final audio = File('${dir.path}/$audioName')..writeAsBytesSync([1]);
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await LocalConversionJobStore(prefs).save(
    LocalConversionJob(
      bookId: '/books/hamlet.epub',
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
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ManualConversionActions(
            filePath: '/books/hamlet.epub',
            bookId: '/books/hamlet.epub',
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
}
