// CONTRAST-AUDIT, area 7: library tiles with real covers. The status badge sits over the cover, so
// its text and icon are measured against the pixels actually drawn, for light, dark, saturated and
// mid-tone covers.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_app/design_system/app_theme.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/screens/library_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/contrast_audit.dart';

Future<String> _cover(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
      .drawRect(const Rect.fromLTWH(0, 0, 90, 130), Paint()..color = color);
  final image = await recorder.endRecording().toImage(90, 130);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return base64Encode(bytes!.buffer.asUint8List());
}

void main() {
  const covers = {
    'white': Color(0xffffffff),
    'black': Color(0xff000000),
    'red': Color(0xffd32f2f),
    'orange': Color(0xffff9800),
    'green': Color(0xff4caf50),
    'mid grey': Color(0xff808080),
  };
  for (final cover in covers.entries) {
    for (final status in [LibraryStatus.offlineReady, LibraryStatus.caching]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'tile with a ${cover.key} cover, ${status.name} (${brightness.name}): badge meets WCAG AA',
          (tester) async {
            final base64 = (await tester.runAsync(() => _cover(cover.value)))!;
            final book = BookEntity(
              id: 'b1',
              title: 'A Book With A Title',
              author: 'An Author',
              filePath: '/tmp/b1.epub',
              displayFilename: 'b1.epub',
              addedAt: DateTime(2025, 1, 1),
              coverBase64: base64,
              cachedOffline: status == LibraryStatus.offlineReady,
              lastJobId: status == LibraryStatus.caching ? 'job' : null,
            );
            final key = GlobalKey();
            tester.view.physicalSize = const Size(300, 400);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              AuditHost(
                boundaryKey: key,
                child: MaterialApp(
                  theme: AppTheme.forBrightness(brightness),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                  home: Scaffold(
                    body: Center(
                      child: SizedBox(
                        width: 160,
                        height: 240,
                        child: LibraryBookTile(
                          book: book,
                          onTap: () {},
                          onLongPress: () {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.runAsync(
              () => precacheImage(
                MemoryImage(base64Decode(base64)),
                tester.element(find.byType(LibraryBookTile)),
              ),
            );
            await tester.pump(const Duration(milliseconds: 300));
            final findings = await auditContrast(tester, key);
            final path = Platform.environment['CONTRAST_REPORT'];
            if (path != null) {
              File(path).writeAsStringSync(
                '## tile ${cover.key} ${status.name} (${brightness.name}): ${findings.length} violation(s)\n'
                '${findings.map((f) => '- $f').join('\n')}\n\n',
                mode: FileMode.append,
              );
            }
            expect(findings, isEmpty, reason: findings.join('\n'));
          },
        );
      }
    }
  }
}
