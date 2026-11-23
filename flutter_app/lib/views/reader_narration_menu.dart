import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/tts_catalog.dart';
import '../models/tts_preferences.dart';
import '../state/providers.dart';

/// Localized name of a narration choice, shared by Settings and the reader.
String ttsSelectionLabel(AppLocalizations t, TtsSelection selection) {
  if (selection.representsSameRequest(TtsSelection.automaticPiper)) {
    return t.ttsAutomaticPiper;
  }
  if (selection.representsSameRequest(TtsSelection.faber)) {
    return t.ttsFaberOffline;
  }
  if (selection.representsSameRequest(TtsSelection.edge)) {
    return t.ttsEdgeOnline;
  }
  if (selection.engine == 'system') return t.ttsSystemOffline;
  return selection.displayName;
}

/// Narration models the reader can switch to without installing anything.
///
/// The active primary comes first so it is always listed and marked. Manual
/// low-quality models stay in Settings, and online Edge speech is offered only
/// after the user has consented to online fallback.
List<TtsSelection> readerNarrationChoices({
  required TtsPreferences preferences,
  required TtsPreferences recommended,
  required TtsCatalog? catalog,
}) {
  final result = <TtsSelection>[];
  void add(TtsSelection candidate) {
    if (candidate.manualModel && !candidate.representsSameRequest(preferences.primary)) {
      return;
    }
    if (candidate.engine == 'edge' &&
        !preferences.allowOnlineFallback &&
        !candidate.representsSameRequest(preferences.primary)) {
      return;
    }
    if (!result.any((existing) => existing.representsSameRequest(candidate))) {
      result.add(candidate);
    }
  }

  add(preferences.primary);
  for (final selection in catalog?.selections() ?? const <TtsSelection>[]) {
    add(selection);
  }
  add(recommended.primary);
  add(TtsSelection.faber);
  add(TtsSelection.edge);
  add(TtsSelection.system);
  return result;
}

/// Reader overflow menu: lists narration models, marks the active one and
/// persists the choice. [onChanged] runs only after a different model is saved.
class ReaderNarrationMenu extends ConsumerWidget {
  const ReaderNarrationMenu({super.key, this.color, this.onChanged});

  final Color? color;
  final Future<void> Function(TtsSelection selection)? onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final settings = ref.watch(settingsProvider);
    final catalog = ref.watch(ttsCatalogProvider).asData?.value;
    final recommended =
        catalog?.recommendedPreferences ?? const TtsPreferences.appDefaults();
    final preferences = settings.configuredTtsPreferences ?? recommended;
    final choices = readerNarrationChoices(
      preferences: preferences,
      recommended: recommended,
      catalog: catalog,
    );

    return PopupMenuButton<int>(
      key: const ValueKey('reader-overflow-menu'),
      icon: Icon(Icons.more_vert, color: color),
      tooltip: MaterialLocalizations.of(context).showMenuTooltip,
      onSelected: (index) async {
        final selected = choices[index];
        if (selected.representsSameRequest(preferences.primary)) return;
        await ref
            .read(settingsProvider.notifier)
            .setTtsPreferences(preferences.withPrimary(selected));
        await onChanged?.call(selected);
      },
      itemBuilder: (_) => [
        PopupMenuItem<int>(
          enabled: false,
          child: Text(t.readerNarrationModel),
        ),
        for (var index = 0; index < choices.length; index++)
          CheckedPopupMenuItem<int>(
            key: ValueKey('narration-${jsonEncode(choices[index].toJson())}'),
            value: index,
            checked: choices[index].representsSameRequest(preferences.primary),
            child: Text(ttsSelectionLabel(t, choices[index])),
          ),
      ],
    );
  }
}
