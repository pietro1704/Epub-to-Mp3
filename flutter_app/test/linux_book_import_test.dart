import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/library_screen.dart';
import 'package:flutter_app/services/linux_book_import.dart';
import 'package:flutter_app/services/storage/library_store.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = LinuxBookImport.channel;
  final linux = TargetPlatformVariant({TargetPlatform.linux});
  late Directory files;
  late List<MethodCall> calls;
  late List<String> picked;
  late List<String> copied;
  late List<Map<String, Object>> pending;

  setUp(() async {
    files = await Directory.systemTemp.createTemp('linux-book-import-');
    calls = [];
    picked = [];
    copied = [];
    pending = [];
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      final batches = pending;
      if (call.method == 'takePending') pending = [];
      return SynchronousFuture<Object?>(switch (call.method) {
        'chooseBooks' => picked,
        'pasteBooks' => copied,
        'takePending' => batches,
        _ => throw MissingPluginException(call.method),
      });
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await files.delete(recursive: true);
  });

  Future<(LibraryStore, ProviderContainer)> showLibrary(
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = LibraryStore(prefs: prefs);
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        libraryStoreProvider.overrideWith((_) => store),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (store, container);
  }

  String fixture(String name) {
    final file = File('${files.path}/$name')..writeAsStringSync(name);
    return file.path;
  }

  Future<void> expectImport(
    WidgetTester tester,
    LibraryStore store,
    int count,
    Future<void> Function() action,
  ) async {
    await tester.runAsync(() async {
      final done = Completer<void>();
      void observe() {
        if (store.books.length == count && !done.isCompleted) done.complete();
      }

      store.addListener(observe);
      try {
        await action();
        await done.future.timeout(const Duration(seconds: 5));
      } finally {
        store.removeListener(observe);
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> notifyFiles() => messenger.handlePlatformMessage(
    channel.name,
    const StandardMethodCodec().encodeMethodCall(
      const MethodCall('booksAvailable'),
    ),
    (_) {},
  );

  testWidgets(
    'both Linux Add buttons open the native chooser, including cancel',
    (tester) async {
      final path = fixture('Picker Book.epub');
      final (store, _) = await showLibrary(tester);
      await tester.tap(find.widgetWithIcon(IconButton, Icons.add));
      await tester.pumpAndSettle();
      expect(store.books, isEmpty);
      expect(calls.where((call) => call.method == 'chooseBooks'), hasLength(1));

      picked = [path];
      await expectImport(
        tester,
        store,
        1,
        () => tester.tap(find.byType(FilledButton)),
      );
      expect(store.books.single.filePath, path);
      expect(calls.where((call) => call.method == 'chooseBooks'), hasLength(2));
    },
    variant: linux,
  );

  testWidgets('Ctrl+V imports copied local books', (tester) async {
    copied = [fixture('Copied Book.EPUB')];
    final (store, _) = await showLibrary(tester);
    await expectImport(tester, store, 1, () async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    });
    expect(store.books.single.filePath, copied.single);
  }, variant: linux);

  testWidgets('drop imports books and OS open selects the reader', (
    tester,
  ) async {
    final dropped = fixture('Dropped Book.pdf');
    final opened = fixture('Opened Book.epub');
    final unsupported = fixture('ignored.txt');
    final (store, container) = await showLibrary(tester);
    pending.add({
      'paths': [dropped, unsupported, dropped],
      'open': false,
    });
    await expectImport(tester, store, 1, notifyFiles);
    expect(store.books.single.filePath, dropped);
    expect(container.read(appDestinationProvider), AppDestination.library);

    pending.add({
      'paths': [opened],
      'open': true,
    });
    await expectImport(tester, store, 2, notifyFiles);
    final book = store.books.singleWhere((book) => book.filePath == opened);
    expect(container.read(currentlyReadingBookIdProvider), book.id);
    expect(container.read(appDestinationProvider), AppDestination.reader);
  }, variant: linux);
}
