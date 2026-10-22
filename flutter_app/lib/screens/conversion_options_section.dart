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
          initialValue: engine,
          decoration: const InputDecoration(labelText: 'Engine'),
          items: [
            DropdownMenuItem(
              value: 'preferences',
              child: Text(t.ttsUsePreferences),
            ),
            DropdownMenuItem(value: 'piper', child: Text(t.ttsFaberOffline)),
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
            initialValue: voice,
            decoration: const InputDecoration(labelText: 'Voice'),
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
          initialValue: language,
          decoration: const InputDecoration(labelText: 'Language'),
          items: const [
            DropdownMenuItem(value: 'pt', child: Text('Portuguese')),
            DropdownMenuItem(value: 'en', child: Text('English')),
            DropdownMenuItem(value: 'es', child: Text('Spanish')),
          ],
          onChanged: (v) => onLanguageChanged(v ?? language),
        ),
        const SizedBox(height: 12),
        const Text(
          'Chapter range',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: startController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'From'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: endController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'To'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text('Options', style: TextStyle(fontWeight: FontWeight.bold)),
        if (usesEmbeddedConversion)
          const Text(
            'Cover and audio processing options are managed by the local converter.',
          )
        else ...[
          SwitchListTile(
            title: const Text('Include cover'),
            value: includeCover,
            onChanged: (v) => onIncludeCoverChanged(v),
          ),
          SwitchListTile(
            title: const Text('Normalize audio'),
            value: normalizeAudio,
            onChanged: (v) => onNormalizeAudioChanged(v),
          ),
        ],
      ],
    );
  }
}
