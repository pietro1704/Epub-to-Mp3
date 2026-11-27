part of 'convert_screen.dart';

class ConversionOptionsSection extends StatelessWidget {
  const ConversionOptionsSection({
    super.key,
    required this.engine,
    required this.allowSecondary,
    required this.voice,
    required this.language,
    required this.startController,
    required this.endController,
    required this.includeCover,
    required this.normalizeAudio,
    required this.silenceTrim,
    required this.onSilenceTrimChanged,
    required this.usesEmbeddedConversion,
    required this.onEngineChanged,
    required this.onAllowSecondaryChanged,
    required this.onVoiceChanged,
    required this.onLanguageChanged,
    required this.onIncludeCoverChanged,
    required this.onNormalizeAudioChanged,
  });

  final String engine;
  final bool allowSecondary;
  final String voice;
  final String language;
  final TextEditingController startController;
  final TextEditingController endController;
  final bool includeCover;
  final bool normalizeAudio;
  final SilenceTrim silenceTrim;
  final ValueChanged<SilenceTrim> onSilenceTrimChanged;
  final bool usesEmbeddedConversion;
  final ValueChanged<String> onEngineChanged;
  final ValueChanged<bool> onAllowSecondaryChanged;
  final ValueChanged<String> onVoiceChanged;
  final ValueChanged<String> onLanguageChanged;
  final ValueChanged<bool> onIncludeCoverChanged;
  final ValueChanged<bool> onNormalizeAudioChanged;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: engine,
          decoration: InputDecoration(labelText: t.convertEngine),
          items: [
            DropdownMenuItem(
              value: 'preferences',
              child: Text(t.ttsUsePreferences),
            ),
            DropdownMenuItem(value: 'piper', child: Text(t.ttsAutomaticPiper)),
            DropdownMenuItem(value: 'edge', child: Text(t.ttsEdgeOnline)),
          ],
          onChanged: (v) => onEngineChanged(v ?? engine),
        ),
        if (engine != 'preferences')
          SwitchListTile(
            title: Text(t.ttsAllowJobSecondary),
            value: allowSecondary,
            onChanged: (v) => onAllowSecondaryChanged(v),
          ),
        if (engine == 'edge')
          DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: voice,
            decoration: InputDecoration(labelText: t.convertVoice),
            items: const [
              DropdownMenuItem(
                value: 'pt-BR-AntonioNeural',
                child: Text('Antonio (pt-BR)'),
              ),
              DropdownMenuItem(
                value: 'en-US-GuyNeural',
                child: Text('Guy (en-US)'),
              ),
              DropdownMenuItem(
                value: 'es-MX-JorgeNeural',
                child: Text('Jorge (es-MX)'),
              ),
            ],
            onChanged: (v) => onVoiceChanged(v ?? voice),
          ),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: language,
          decoration: InputDecoration(labelText: t.convertLanguage),
          items: [
            DropdownMenuItem(value: '', child: Text(t.ttsDetectLanguage)),
            DropdownMenuItem(value: 'pt', child: Text(t.convertLanguagePortuguese)),
            DropdownMenuItem(value: 'en', child: Text(t.convertLanguageEnglish)),
            DropdownMenuItem(value: 'es', child: Text(t.convertLanguageSpanish)),
          ],
          onChanged: (v) => onLanguageChanged(v ?? language),
        ),
        const SizedBox(height: 12),
        Text(
          t.convertChapterRange,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: startController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t.convertChapterFrom),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: endController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: t.convertChapterTo),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          t.convertOptions,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        if (usesEmbeddedConversion)
          Text(t.convertOptionsManagedLocally)
        else ...[
          SwitchListTile(
            title: Text(t.convertIncludeCover),
            value: includeCover,
            onChanged: (v) => onIncludeCoverChanged(v),
          ),
          SwitchListTile(
            title: Text(t.convertNormalizeAudio),
            value: normalizeAudio,
            onChanged: (v) => onNormalizeAudioChanged(v),
          ),
        ],
        const SizedBox(height: 8),
        SilenceTrimField(
          key: const ValueKey('convert-silence-trim'),
          value: silenceTrim,
          onChanged: onSilenceTrimChanged,
        ),
      ],
    );
  }
}
