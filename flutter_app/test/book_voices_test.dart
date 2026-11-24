import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_voices.dart';
import 'package:flutter_app/models/tts_catalog.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_narration_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// F4: the reader's voice picker sets the voice of THIS book. A book without its own voice uses the
/// voice of its language (Models); "Use the default" returns to it. Nothing global changes.
const _faber = TtsSelection(engine: 'piper', modelId: 'pt_BR-faber-medium');
const _cadu = TtsSelection(engine: 'piper', modelId: 'pt_BR-cadu-medium');

void main() {
  test('a book voice is stored per book and cleared by "use the default"', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = BookVoices(prefs);
    expect(store.voiceFor('a'), isNull);
    await store.set('a', _cadu);
    expect(store.voiceFor('a')?.modelId, 'pt_BR-cadu-medium');
    expect(store.voiceFor('b'), isNull, reason: 'other books keep the language voice');
    await store.clear('a');
    expect(store.voiceFor('a'), isNull);
    expect(BookVoices(prefs).voiceFor('a'), isNull, reason: 'persisted');
  });

  Future<ProviderContainer> pump(WidgetTester tester, {Map<String, Object> seed = const {}, List<TtsSelection>? changes}) async {
    SharedPreferences.setMockInitialValues(seed);
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        ttsCatalogProvider.overrideWith((ref) => Future<TtsCatalog>.error(StateError('catalog unavailable'))),
        installedNarrationModelIdsProvider.overrideWith((ref) async => {'pt_BR-faber-medium', 'pt_BR-cadu-medium'}),
        readerBookLanguageProvider('book-1').overrideWith((ref) async => 'pt'),
        systemVoiceLanguagesProvider.overrideWith((_) async => const <String>[]),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            appBar: AppBar(
              actions: [
                ReaderNarrationMenu(
                  bookId: 'book-1',
                  onChanged: (selection, _) async => changes?.add(selection),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return container;
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('reader-overflow-menu')));
    await tester.pumpAndSettle();
  }

  testWidgets('choosing a voice in the reader sets the voice of the book and nothing global', (tester) async {
    final changes = <TtsSelection>[];
    final container = await pump(tester, changes: changes);
    await openMenu(tester);
    expect(find.text('Voice for this book'), findsOneWidget);
    await tester.tap(find.textContaining('cadu'));
    await tester.pumpAndSettle();
    expect(container.read(bookVoiceProvider('book-1'))?.modelId, 'pt_BR-cadu-medium');
    expect(container.read(languageModelChoicesProvider).byLanguage['pt'], isNull, reason: 'the language voice is untouched');
    expect(container.read(settingsProvider).configuredTtsPreferences, isNull, reason: 'the global voice is untouched');
    expect(changes.single.modelId, 'pt_BR-cadu-medium');
  });

  testWidgets('"Use the default" appears only with a book voice and returns to the language voice', (tester) async {
    final changes = <TtsSelection>[];
    final container = await pump(tester, changes: changes);
    await openMenu(tester);
    expect(find.text('Use the default'), findsNothing);
    await tester.tap(find.textContaining('cadu'));
    await tester.pumpAndSettle();
    await openMenu(tester);
    expect(find.text('Use the default'), findsOneWidget);
    await tester.tap(find.text('Use the default'));
    await tester.pumpAndSettle();
    expect(container.read(bookVoiceProvider('book-1')), isNull);
    expect(changes, hasLength(2), reason: 'the narration is restarted with the voice it falls back to');
  });

  testWidgets('the book voice is the one marked in the menu', (tester) async {
    await pump(tester, seed: {BookVoices.preferenceKey: '{"book-1":${jsonEncode(_cadu.toJson())}}'});
    await openMenu(tester);
    final marked = tester.widgetList<CheckedPopupMenuItem<Object>>(find.byType(CheckedPopupMenuItem<Object>)).where((i) => i.checked).toList();
    expect(marked, hasLength(1));
    expect(find.descendant(of: find.byWidget(marked.single), matching: find.textContaining('cadu')), findsOneWidget);
    expect(_faber.modelId, 'pt_BR-faber-medium');
  });
}
