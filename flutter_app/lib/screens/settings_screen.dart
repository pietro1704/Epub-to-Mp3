import '../design_system/adaptive_settings_layout.dart';
import '../features/settings/local_audio_storage_screen.dart';
import '../models/tts_preferences.dart';
import '../models/tts_catalog.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../models/app_settings.dart';
import '../state/providers.dart';

part 'voice_selection_settings.dart';
part 'installed_narration_models.dart';
part 'playback_preferences.dart';

final _ttsCatalogSelections = FutureProvider<List<TtsSelection>>(
  (ref) async =>
      TtsCatalog.decode(await ref.read(embeddedConverterProvider).ttsModels())
          .selections(),
);

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
          const VoiceSelectionSettings(),
          const InstalledNarrationModelsCard(),
          const SizedBox(height: 20),
        ],
        preferences: [
          // ── Reader ──
          _SectionHeader(t.readerTitle),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: Text(t.originalTypography),
                  trailing: const Icon(Icons.restore),
                  onTap: notifier.resetReaderTypography,
                ),
                const Divider(height: 1, indent: 56),
                // Font size stepper
                ListTile(
                  leading: Icon(Icons.format_size, color: cs.onSurfaceVariant),
                  title: Text(t.fontSizeLabel),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: settings.readerFontSize > 0
                            ? () => notifier.setReaderFontSize(
                                settings.readerFontSize - 1,
                              )
                            : null,
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(
                          t.nOfSteps(settings.readerFontSize + 1, 5),
                          textAlign: TextAlign.center,
                          style: tt.bodyMedium?.copyWith(
                            fontFeatures: [const FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: settings.readerFontSize < 4
                            ? () => notifier.setReaderFontSize(
                                settings.readerFontSize + 1,
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, indent: 56),

                // Font family
                ListTile(
                  leading: Icon(
                    Icons.font_download,
                    color: cs.onSurfaceVariant,
                  ),
                  title: Text(t.fontLabel),
                  trailing: DropdownButton<ReaderFontFamily>(
                    value: settings.readerFontFamily,
                    underline: const SizedBox.shrink(),
                    onChanged: (v) {
                      if (v != null) notifier.setReaderFontFamily(v);
                    },
                    items: ReaderFontFamily.values
                        .map(
                          (f) => DropdownMenuItem(
                            value: f,
                            child: Text(f.displayName),
                          ),
                        )
                        .toList(),
                  ),
                ),
                const Divider(height: 1, indent: 56),

                // Theme
                ListTile(
                  leading: Icon(
                    Icons.palette_outlined,
                    color: cs.onSurfaceVariant,
                  ),
                  title: Text(t.themeLabel),
                  trailing: DropdownButton<ReaderTheme>(
                    value: settings.readerTheme,
                    underline: const SizedBox.shrink(),
                    onChanged: (v) {
                      if (v != null) notifier.setReaderTheme(v);
                    },
                    items: ReaderTheme.values
                        .where((t) => t != ReaderTheme.custom)
                        .map(
                          (t) => DropdownMenuItem(
                            value: t,
                            child: Text(t.displayName),
                          ),
                        )
                        .toList(),
                  ),
                ),
                const Divider(height: 1, indent: 56),

                // Layout
                ListTile(
                  leading: Icon(
                    Icons.view_agenda_outlined,
                    color: cs.onSurfaceVariant,
                  ),
                  title: Text(t.layoutLabel),
                  trailing: SegmentedButton<ReaderLayout>(
                    segments: ReaderLayout.values
                        .map(
                          (l) => ButtonSegment(
                            value: l,
                            label: Text(l.displayName),
                          ),
                        )
                        .toList(),
                    selected: {settings.readerLayout},
                    onSelectionChanged: (s) =>
                        notifier.setReaderLayout(s.first),
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
                const Divider(height: 1, indent: 56),

                // Line spacing stepper
                ListTile(
                  leading: Icon(
                    Icons.format_line_spacing,
                    color: cs.onSurfaceVariant,
                  ),
                  title: Text(t.lineSpacingLabel),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: settings.readerLineSpacing > 0
                            ? () => notifier.setReaderLineSpacing(
                                settings.readerLineSpacing - 2,
                              )
                            : null,
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(
                          '${settings.readerLineSpacing.toInt()} pt',
                          textAlign: TextAlign.center,
                          style: tt.bodyMedium?.copyWith(
                            fontFeatures: [const FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: settings.readerLineSpacing < 16
                            ? () => notifier.setReaderLineSpacing(
                                settings.readerLineSpacing + 2,
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, indent: 56),

                // Margin stepper
                ListTile(
                  leading: Icon(
                    Icons.format_indent_increase,
                    color: cs.onSurfaceVariant,
                  ),
                  title: Text(t.marginLabel),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: settings.readerMargin > 16
                            ? () => notifier.setReaderMargin(
                                settings.readerMargin - 4,
                              )
                            : null,
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(
                          '${settings.readerMargin.toInt()} pt',
                          textAlign: TextAlign.center,
                          style: tt.bodyMedium?.copyWith(
                            fontFeatures: [const FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: settings.readerMargin < 80
                            ? () => notifier.setReaderMargin(
                                settings.readerMargin + 4,
                              )
                            : null,
                      ),
                    ],
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
                    t.platformAndroid,
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
