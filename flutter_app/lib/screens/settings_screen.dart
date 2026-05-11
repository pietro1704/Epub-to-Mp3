import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../state/providers.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _urlCtl;

  @override
  void initState() {
    super.initState();
    _urlCtl = TextEditingController(text: ref.read(settingsProvider).backendURL);
  }

  @override
  void dispose() {
    _urlCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: Text(t.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _urlCtl,
            decoration: InputDecoration(labelText: t.backendUrl),
            onSubmitted: notifier.setBackendUrl,
          ),
          const SizedBox(height: 24),
          Text('${t.wpmLabel}: ${settings.wpm}'),
          Slider(
            min: 100,
            max: 320,
            divisions: 22,
            value: settings.wpm.toDouble(),
            label: '${settings.wpm}',
            onChanged: (v) => notifier.setWpm(v.round()),
          ),
          const SizedBox(height: 16),
          Text('${t.audioRateLabel}: ${settings.audioRate.toStringAsFixed(2)}x'),
          Slider(
            min: 0.5,
            max: 2.0,
            divisions: 30,
            value: settings.audioRate,
            label: '${settings.audioRate.toStringAsFixed(2)}x',
            onChanged: notifier.setAudioRate,
          ),
          const SizedBox(height: 16),
          Text('${t.fontSizeLabel}: ${settings.fontSize.toStringAsFixed(0)}'),
          Slider(
            min: 12,
            max: 28,
            divisions: 16,
            value: settings.fontSize,
            label: settings.fontSize.toStringAsFixed(0),
            onChanged: notifier.setFontSize,
          ),
          SwitchListTile(
            title: Text(t.themeLabel),
            value: settings.darkMode,
            onChanged: notifier.setDarkMode,
          ),
        ],
      ),
    );
  }
}
