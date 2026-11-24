import '../design_system/adaptive_settings_layout.dart';
import '../features/settings/local_audio_storage_screen.dart';
import '../models/tts_preferences.dart';
import '../models/tts_catalog.dart';
import '../models/tts_session_selection.dart';
import '../views/reader_narration_menu.dart'
    show installedNarrationModelIdsProvider;
import 'models_screen.dart';
import 'reading_preferences_screen.dart';
import '../services/conversion/embedded_converter.dart';
import '../services/conversion/model_install/model_install_models.dart';
import '../services/conversion/model_install/model_install_runner.dart';

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/app_settings.dart';
import '../state/providers.dart';

part 'voice_selection_settings.dart';
part 'narration_voice_picker.dart';
part 'installed_narration_models.dart';
part 'playback_preferences.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.settingsTitle)),
      body: AdaptiveSettingsLayout(
        narration: [
          Card(
            child: ListTile(
              key: const ValueKey('settings-models-row'),
              leading: const Icon(Icons.record_voice_over_outlined),
              title: Text(t.modelsTitle),
              subtitle: Text(t.modelsSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ModelsScreen()),
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
        preferences: [
          // ── Reader ──
          _SectionHeader(t.readerTitle),
          Card(
            child: Column(
              children: [
                ListTile(
                  key: const ValueKey('settings-reading-preferences-row'),
                  leading: Icon(Icons.text_format, color: cs.onSurfaceVariant),
                  title: Text(t.readingPreferencesTitle),
                  subtitle: Text(t.readingModeDefault),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ReadingPreferencesScreen(),
                    ),
                  ),
                ),
                const Divider(height: 1, indent: 56),

                // Auto-scroll
                SwitchListTile(
                  secondary: Icon(
                    Icons.vertical_align_bottom,
                    color: cs.onSurfaceVariant,
                  ),
                  title: Text(t.autoScrollLabel),
                  subtitle: Text(t.autoScrollDesc, style: tt.bodySmall),
                  value: settings.readerAutoScroll,
                  onChanged: (v) => notifier.setReaderAutoScroll(v),
                ),
                const Divider(height: 1, indent: 56),

                // Footnotes are read inline by default (shared Rust narration).
                SwitchListTile(
                  key: const ValueKey('tts-footnote-narration'),
                  secondary: Icon(
                    Icons.notes_outlined,
                    color: cs.onSurfaceVariant,
                  ),
                  title: Text(t.ttsFootnoteNarration),
                  subtitle: Text(
                    t.ttsFootnoteNarrationDescription,
                    style: tt.bodySmall,
                  ),
                  value:
                      settings.ttsPreferences.footnoteNarration ==
                      FootnoteNarration.inline,
                  onChanged: (value) => notifier.setTtsPreferences(
                    settings.ttsPreferences.withFootnoteNarration(
                      value ? FootnoteNarration.inline : FootnoteNarration.skip,
                    ),
                  ),
                ),
              ],
            ),
          ),
          _FooterText(t.readerPrefsFooter),
          const SizedBox(height: 20),

          const PlaybackPreferences(),
          Card(
            child: ListTile(
              leading: const Icon(Icons.download_for_offline_outlined),
              title: Text(t.localAudioStorage),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const LocalAudioStorageScreen(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── About ──
          _SectionHeader(t.aboutSection),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.info_outline, color: cs.onSurfaceVariant),
                  title: Text(t.platformLabel),
                  trailing: Text(
                    kIsWeb
                        ? 'Web'
                        : switch (defaultTargetPlatform) {
                            TargetPlatform.android => t.platformAndroid,
                            TargetPlatform.fuchsia => 'Fuchsia',
                            TargetPlatform.iOS => 'iOS',
                            TargetPlatform.linux => 'Linux',
                            TargetPlatform.macOS => 'macOS',
                            TargetPlatform.windows => 'Windows',
                          },
                    style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                const Divider(height: 1, indent: 56),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(
          text,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _FooterText extends StatelessWidget {
  const _FooterText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
