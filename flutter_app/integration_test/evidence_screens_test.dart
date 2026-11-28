// Visual evidence of the resume alert (#1736) and the manual-conversion export (#1740) in the
// real Linux app, with a public-domain text (Hamlet) and fake audio. Writes PNGs to EVIDENCE_DIR.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/screens/settings_screen.dart';
import 'package:flutter_app/services/conversion/audio_export.dart';
import 'package:flutter_app/services/conversion/local_conversion_record.dart';
import 'package:flutter_app/services/storage/local_conversion_store.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/views/instant_reader_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/fake_audio_player_service.dart';

final _shot = GlobalKey();

Future<void> _save(WidgetTester t, String name) async {
  await t.pumpAndSettle();
  final boundary =
      _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 1.5);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final dir = Directory(Platform.environment['EVIDENCE_DIR']!)
    ..createSync(recursive: true);
  File('${dir.path}/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
}

Widget _app(SharedPreferences prefs, Locale locale, Widget home) =>
    RepaintBoundary(
      key: _shot,
      child: ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: home),
        ),
      ),
    );

final _hamlet = EbookFulltext.fromJson({
  'jobId': 'hamlet',
  'bookTitle': 'Hamlet',
  'bookAuthor': 'William Shakespeare',
  'chapters': [
    {
      'index': 0,
      'name': 'Act I',
      'text':
          'Who is there? Nay, answer me: stand, and unfold yourself. Long live the king! Bernardo? He. You come most carefully upon your hour. ' *
          3,
    },
    {
      'index': 1,
      'name': 'Act II',
      'text':
          'Give him heedful note; for I mine eyes will rivet to his face. Well, my lord. If he steal aught the whilst this play is playing, and scape detecting, I will pay the theft. ' *
          3,
    },
  ],
});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final locale in const [Locale('en'), Locale('pt'), Locale('es')]) {
    testWidgets('resume alert ${locale.languageCode}', (t) async {
      t.view.physicalSize = const Size(900, 1200);
      t.view.devicePixelRatio = 1;
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final player = FakeAudioPlayerService()..currentBookId = 'hamlet';
      await player.setQueue([
        const ChapterProgress(
          index: 0,
          name: 'Act I',
          status: 'completed',
          durationSeconds: 60,
        ),
        const ChapterProgress(
          index: 1,
          name: 'Act II',
          status: 'completed',
          durationSeconds: 60,
        ),
      ]);
      player.duration = const Duration(seconds: 60);
      await player.seek(const Duration(seconds: 15), index: 0);
      await t.pumpWidget(
        _app(
          prefs,
          locale,
          InstantReaderView(
            fulltext: _hamlet,
            bookId: 'hamlet',
            player: player,
            initialChapterIndex: 1,
            onListenFrom: (_) async {},
          ),
        ),
      );
      await t.pumpAndSettle();
      final inBar = find.byKey(const ValueKey('reader-tool-listen'));
      if (inBar.evaluate().isNotEmpty) {
        await t.tap(inBar);
      } else {
        await t.tap(find.byKey(const ValueKey('reader-overflow-menu')));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('reader-menu-listen')));
      }
      await t.pumpAndSettle();
      await _save(t, 'resume-alert-${locale.languageCode}');
    });
  }

  for (final locale in const [Locale('en'), Locale('pt'), Locale('es')]) {
    for (final mp3 in [true, false]) {
      testWidgets('manual export ${locale.languageCode} mp3=$mp3', (t) async {
        t.view.physicalSize = const Size(900, 700);
        t.view.devicePixelRatio = 1;
        final dir = Directory.systemTemp.createTempSync('evidence');
        addTearDown(() => dir.deleteSync(recursive: true));
        final audio = File('${dir.path}/act1.${mp3 ? 'mp3' : 'wav'}')
          ..writeAsBytesSync([1]);
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
          _app(
            prefs,
            locale,
            Padding(
              padding: const EdgeInsets.all(16),
              child: ManualConversionActions(
                filePath: '/books/hamlet.epub',
                bookId: '/books/hamlet.epub',
                jobId: 'job-1',
                exporter: AudioExporter(
                  call: (_) async => '{"files":["/x/01 - Act I.mp3"]}',
                ),
                chooseFolder: () async => '/home/user/Music',
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        await _save(
          t,
          'manual-export-${locale.languageCode}-${mp3 ? 'buttons' : 'needs-piper'}',
        );
        if (mp3) {
          await t.tap(find.byKey(const ValueKey('manual-export-audio')));
          await t.pumpAndSettle();
          await _save(t, 'manual-export-${locale.languageCode}-choice');
        }
      });
    }
  }

  for (final locale in const [Locale('en'), Locale('pt'), Locale('es')]) {
    testWidgets('silence trim setting ${locale.languageCode}', (t) async {
      t.view.physicalSize = const Size(900, 900);
      t.view.devicePixelRatio = 1;
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await t.pumpWidget(_app(prefs, locale, const SettingsScreen()));
      await t.pumpAndSettle();
      await t.scrollUntilVisible(
        find.byKey(const ValueKey('tts-silence-trim')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _save(t, 'silence-trim-${locale.languageCode}');
    });
  }
}
