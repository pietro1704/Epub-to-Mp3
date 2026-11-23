import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/reader_listening_position.dart';
import 'package:flutter_app/models/tts_catalog.dart';
import 'package:flutter_app/models/tts_preferences.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_narration_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _pumpMenu(
  WidgetTester tester, {
  ReaderListeningPosition? sentence,
  List<ReaderListeningPosition?>? sentences,
  Map<String, Object> seed = const {},
  Set<String> installed = const {'pt_BR-faber-medium'},
  required List<TtsSelection> changes,
}) async {
  SharedPreferences.setMockInitialValues(seed);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      ttsCatalogProvider.overrideWith(
        (ref) => Future<TtsCatalog>.error(StateError('catalog unavailable')),
      ),
      installedNarrationModelIdsProvider.overrideWith(
        (ref) async => installed,
      ),
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
                currentSentence: () async => sentence,
                onChanged: (selection, atSentence) async {
                  changes.add(selection);
                  sentences?.add(atSentence);
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('reader-overflow-menu')));
  await tester.pumpAndSettle();
}

Map<String, bool> _checked(WidgetTester tester) => {
  for (final item in tester.widgetList<CheckedPopupMenuItem<Object>>(
    find.byType(CheckedPopupMenuItem<Object>),
  ))
    (item.child! as Text).data!: item.checked,
};

void main() {
  testWidgets('lists narration models and marks the active one', (tester) async {
    final changes = <TtsSelection>[];
    await _pumpMenu(tester, changes: changes);
    await _openMenu(tester);

    expect(find.text('Narration model'), findsOneWidget);
    final checked = _checked(tester);
    expect(
      checked.keys,
      containsAll([
        'Piper · Book language',
        'Faber medium · Offline',
        'System voice · Offline fallback',
      ]),
    );
    expect(checked.values.where((value) => value), hasLength(1));
    expect(checked['Piper · Book language'], isTrue);
    expect(find.text('Edge · Online'), findsNothing,
        reason: 'online speech needs the explicit fallback consent');
  });

  testWidgets('switching saves the new primary and notifies once', (tester) async {
    final changes = <TtsSelection>[];
    final container = await _pumpMenu(tester, changes: changes);
    await _openMenu(tester);
    await tester.tap(find.text('System voice · Offline fallback'));
    await tester.pumpAndSettle();

    expect(changes, hasLength(1));
    expect(changes.single.engine, 'system');
    final saved = container.read(settingsProvider).configuredTtsPreferences;
    expect(saved?.primary.engine, 'system');

    await _openMenu(tester);
    expect(_checked(tester)['System voice · Offline fallback'], isTrue);
    expect(_checked(tester)['Piper · Book language'], isFalse,
        reason: 'the previous model stays selectable so the user can go back');
  });

  testWidgets('a switch reports the sentence being read at the tap', (tester) async {
    final changes = <TtsSelection>[];
    final sentences = <ReaderListeningPosition?>[];
    const sentence = ReaderListeningPosition(4, 88);
    await _pumpMenu(
      tester,
      sentence: sentence,
      sentences: sentences,
      changes: changes,
    );
    await _openMenu(tester);
    await tester.tap(find.text('System voice · Offline fallback'));
    await tester.pumpAndSettle();
    expect(sentences, [sentence]);
  });

  testWidgets('choosing the active model changes nothing', (tester) async {
    final changes = <TtsSelection>[];
    final container = await _pumpMenu(tester, changes: changes);
    await _openMenu(tester);
    await tester.tap(find.text('Piper · Book language'));
    await tester.pumpAndSettle();

    expect(changes, isEmpty);
    expect(container.read(settingsProvider).configuredTtsPreferences, isNull);
  });

  testWidgets('hides Piper models that are not installed', (tester) async {
    await _pumpMenu(tester, installed: const {}, changes: <TtsSelection>[]);
    await _openMenu(tester);
    final labels = _checked(tester).keys;
    expect(labels, isNot(contains('Faber medium · Offline')));
    expect(labels, containsAll(['Piper · Book language', 'System voice · Offline fallback']));
  });

  test('choices keep the active manual model and hide Edge without consent', () {
    const manual = TtsSelection(
      engine: 'piper',
      modelId: 'pt_BR-edresson-low',
      manualModel: true,
    );
    final choices = readerNarrationChoices(
      preferences: const TtsPreferences(primary: manual),
      recommended: const TtsPreferences.appDefaults(),
      catalog: null,
      installedModelIds: const {},
    );
    expect(choices.first.modelId, 'pt_BR-edresson-low');
    expect(choices.any((choice) => choice.engine == 'edge'), isFalse);
    expect(
      choices.where((choice) => choice.representsSameRequest(manual)),
      hasLength(1),
    );
  });
}
