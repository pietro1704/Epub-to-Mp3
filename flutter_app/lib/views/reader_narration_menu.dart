import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/tts_catalog.dart';
import '../models/reader_listening_position.dart';
import '../models/tts_preferences.dart';
import '../state/providers.dart';

/// Catalog models already on disk. The reader never downloads anything: model
/// installation stays an explicit action in Settings.
final installedNarrationModelIdsProvider =
    FutureProvider.autoDispose<Set<String>>((ref) async {
      final converter = ref.watch(embeddedConverterProvider);
      final catalog = await ref.watch(ttsCatalogProvider.future);
      final root = await ref.watch(ttsModelRootProvider.future);
      final installed = <String>{};
      for (final model in catalog.models) {
        final id = model['id'];
        if (id is! String || id.isEmpty) continue;
        if (await converter.ttsModelMetadata(modelId: id, root: root) != null) {
          installed.add(id);
        }
      }
      return installed;
    });

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
/// The active primary comes first so it is always listed and marked. Piper
/// models appear only when installed, manual low-quality models stay in
/// Settings, and online Edge speech is offered only after the user has
/// consented to online fallback.
List<TtsSelection> readerNarrationChoices({
  required TtsPreferences preferences,
  required TtsPreferences recommended,
  required TtsCatalog? catalog,
  required Set<String> installedModelIds,
}) {
  final result = <TtsSelection>[];
  void add(TtsSelection candidate) {
    final isPrimary = candidate.representsSameRequest(preferences.primary);
    final modelId = candidate.modelId;
    if (!isPrimary &&
        candidate.engine == 'piper' &&
        modelId != null &&
        modelId != TtsSelection.automaticPiper.modelId &&
        !installedModelIds.contains(modelId)) {
      return;
    }
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

/// One command of the reader overflow menu. A [tool] entry becomes the recent
/// tool when chosen; an entry without one is a plain command.
class ReaderMenuEntry {
  const ReaderMenuEntry({
    required this.keyName,
    required this.icon,
    required this.label,
    required this.onSelected,
    this.tool,
  });

  final String keyName;
  final IconData icon;
  final String label;
  final VoidCallback onSelected;
  final ReaderTool? tool;
}

/// Reader overflow menu ("More"): the reader tools that are not the recent
/// one, then the narration models with the active one marked. A different
/// model is saved before [onChanged] runs; choosing the active model does
/// nothing.
class ReaderNarrationMenu extends ConsumerWidget {
  const ReaderNarrationMenu({
    super.key,
    this.color,
    this.onChanged,
    this.currentSentence,
    this.entries = const [],
  });

  final Color? color;

  /// Tools and commands listed above the narration models.
  final List<ReaderMenuEntry> entries;

  /// Called after a different model is saved, with the sentence that was
  /// being read when it was chosen (null when none is playing).
  final Future<void> Function(
    TtsSelection selection,
    ReaderListeningPosition? sentence,
  )?
  onChanged;

  /// Sampled at the moment of the tap, before anything is saved.
  final Future<ReaderListeningPosition?> Function()? currentSentence;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final settings = ref.watch(settingsProvider);
    final catalog = ref.watch(ttsCatalogProvider).asData?.value;
    final installed =
        ref.watch(installedNarrationModelIdsProvider).asData?.value ??
        const <String>{};
    final recommended =
        catalog?.recommendedPreferences ?? const TtsPreferences.appDefaults();
    final preferences = settings.configuredTtsPreferences ?? recommended;
    final choices = readerNarrationChoices(
      preferences: preferences,
      recommended: recommended,
      catalog: catalog,
      installedModelIds: installed,
    );

    return PopupMenuButton<Object>(
      key: const ValueKey('reader-overflow-menu'),
      icon: Icon(Icons.more_vert, color: color),
      tooltip: MaterialLocalizations.of(context).showMenuTooltip,
      onSelected: (value) async {
        if (value is ReaderMenuEntry) {
          final tool = value.tool;
          if (tool != null) {
            ref.read(readerRecentToolProvider.notifier).set(tool);
          }
          value.onSelected();
          return;
        }
        final selected = choices[value as int];
        if (selected.representsSameRequest(preferences.primary)) return;
        final sentence = await currentSentence?.call();
        await ref
            .read(settingsProvider.notifier)
            .setTtsPreferences(preferences.withPrimary(selected));
        await onChanged?.call(selected, sentence);
      },
      itemBuilder: (_) => [
        for (final entry in entries)
          PopupMenuItem<Object>(
            key: ValueKey('reader-menu-${entry.keyName}'),
            value: entry,
            child: Row(
              children: [
                Icon(entry.icon, size: 20),
                const SizedBox(width: 12),
                Flexible(child: Text(entry.label)),
              ],
            ),
          ),
        if (entries.isNotEmpty) const PopupMenuDivider(),
        PopupMenuItem<Object>(
          enabled: false,
          child: Text(t.readerNarrationModel),
        ),
        for (var index = 0; index < choices.length; index++)
          CheckedPopupMenuItem<Object>(
            key: ValueKey('narration-${jsonEncode(choices[index].toJson())}'),
            value: index,
            checked: choices[index].representsSameRequest(preferences.primary),
            child: Text(ttsSelectionLabel(t, choices[index])),
          ),
      ],
    );
  }
}
