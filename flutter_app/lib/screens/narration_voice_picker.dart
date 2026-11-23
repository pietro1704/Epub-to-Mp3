part of 'settings_screen.dart';

/// The first level of a narration choice is the engine; the voice or model is
/// chosen inside it.
String ttsEngineKey(TtsSelection selection) => switch (selection.engine) {
  'system' => 'system',
  'edge' => 'edge',
  _ => 'piper',
};

String ttsEngineLabel(AppLocalizations t, String engine) => switch (engine) {
  'system' => t.ttsEngineSystem,
  'edge' => t.ttsEngineEdge,
  _ => t.ttsEnginePiper,
};

/// The voice or model inside its engine (the row's subtitle).
String ttsVoiceLabel(AppLocalizations t, TtsSelection selection) {
  if (selection.representsSameRequest(TtsSelection.automaticPiper)) {
    return t.ttsVoiceBookLanguage;
  }
  if (selection.representsSameRequest(TtsSelection.faber)) {
    return 'Faber medium';
  }
  return switch (selection.engine) {
    'system' => t.ttsVoiceSystem,
    'edge' => selection.voice ?? t.ttsVoiceEdge,
    _ => [selection.modelId, selection.voice].whereType<String>().join(' · '),
  };
}

/// What a picker returns: a selection, or "none" for the optional secondary.
class NarrationPick {
  const NarrationPick(this.selection);
  final TtsSelection? selection;
}

/// One narration row: the engine as the title and the voice as its subtitle.
class NarrationChoiceRow extends StatelessWidget {
  const NarrationChoiceRow({
    super.key,
    required this.label,
    required this.selection,
    required this.onTap,
  });

  final String label;

  /// Null shows "None" (the secondary voice).
  final TtsSelection? selection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final engine = selection == null
        ? t.ttsNoSecondary
        : ttsEngineLabel(t, ttsEngineKey(selection!));
    final voice = selection == null ? null : ttsVoiceLabel(t, selection!);
    return Semantics(
      label: label,
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.graphic_eq),
            title: Text(engine),
            subtitle: voice == null || voice.isEmpty ? null : Text(voice),
            trailing: const Icon(Icons.chevron_right),
            onTap: onTap,
          ),
        ],
      ),
    );
  }
}

/// Engine first, then the voice inside it. The check follows the tap at once,
/// without waiting for the sheet to finish closing.
Future<NarrationPick?> showNarrationPicker(
  BuildContext context, {
  required String title,
  required List<TtsSelection> options,
  required TtsSelection? current,
  required bool Function(TtsSelection) enabled,
  bool allowNone = false,
}) {
  return showModalBottomSheet<NarrationPick>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _NarrationPickerSheet(
      title: title,
      options: options,
      current: current,
      enabled: enabled,
      allowNone: allowNone,
    ),
  );
}

class _NarrationPickerSheet extends StatefulWidget {
  const _NarrationPickerSheet({
    required this.title,
    required this.options,
    required this.current,
    required this.enabled,
    required this.allowNone,
  });

  final String title;
  final List<TtsSelection> options;
  final TtsSelection? current;
  final bool Function(TtsSelection) enabled;
  final bool allowNone;

  @override
  State<_NarrationPickerSheet> createState() => _NarrationPickerSheetState();
}

class _NarrationPickerSheetState extends State<_NarrationPickerSheet> {
  /// Engine whose voices are showing; null shows the engines.
  String? _openEngine;

  /// What the check marks, updated on the tap itself.
  late String? _checkedEngine = widget.current == null
      ? null
      : ttsEngineKey(widget.current!);
  late TtsSelection? _checked = widget.current;
  bool _noneChecked = false;

  void _finish(TtsSelection? selection) {
    setState(() {
      _checked = selection;
      _noneChecked = selection == null;
      _checkedEngine = selection == null ? null : ttsEngineKey(selection);
    });
    Navigator.of(context).pop(NarrationPick(selection));
  }

  void _chooseEngine(String engine) {
    final voices = widget.options
        .where((option) => ttsEngineKey(option) == engine)
        .toList();
    setState(() => _checkedEngine = engine);
    final usable = voices.where(widget.enabled).toList();
    if (voices.length == 1 && usable.length == 1) {
      _finish(usable.single);
    } else {
      setState(() => _openEngine = engine);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final engines = <String>[];
    for (final option in widget.options) {
      final key = ttsEngineKey(option);
      if (!engines.contains(key)) engines.add(key);
    }
    final open = _openEngine;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            if (open == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              )
            else
              ListTile(
                key: const ValueKey('narration-picker-back'),
                leading: const Icon(Icons.arrow_back),
                title: Text(ttsEngineLabel(t, open)),
                onTap: () => setState(() => _openEngine = null),
              ),
            if (open == null) ...[
              if (widget.allowNone)
                ListTile(
                  key: const ValueKey('narration-engine-none'),
                  title: Text(t.ttsNoSecondary),
                  trailing: _noneChecked || widget.current == null
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => _finish(null),
                ),
              for (final engine in engines)
                Builder(
                  builder: (context) {
                    final voices = widget.options
                        .where((option) => ttsEngineKey(option) == engine)
                        .toList();
                    final usable = voices.any(widget.enabled);
                    return ListTile(
                      key: ValueKey('narration-engine-$engine'),
                      enabled: usable,
                      title: Text(ttsEngineLabel(t, engine)),
                      subtitle: engine == 'edge' && !usable
                          ? Text(t.modelsOnlineNeedsConsent)
                          : null,
                      trailing: _checkedEngine == engine && !_noneChecked
                          ? const Icon(Icons.check)
                          : (voices.length > 1 || !usable
                                ? const Icon(Icons.chevron_right)
                                : null),
                      onTap: usable ? () => _chooseEngine(engine) : null,
                    );
                  },
                ),
            ] else
              for (final option in widget.options.where(
                (option) => ttsEngineKey(option) == open,
              ))
                ListTile(
                  key: ValueKey('narration-voice-${jsonEncode(option.toJson())}'),
                  enabled: widget.enabled(option),
                  title: Text(ttsVoiceLabel(t, option)),
                  trailing:
                      _checked != null && _checked!.representsSameRequest(option)
                      ? const Icon(Icons.check)
                      : null,
                  onTap: widget.enabled(option) ? () => _finish(option) : null,
                ),
          ],
        ),
      ),
    );
  }
}
