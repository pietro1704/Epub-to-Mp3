import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/app_localizations.dart';
import '../models/app_settings.dart';
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
    _urlCtl = TextEditingController(
      text: ref.read(settingsProvider).backendURL,
    );
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
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(t.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          // ── Audio Engine ──
          _SectionHeader(t.audioEngineSection),
          Card(
            child: SwitchListTile(
              secondary: Icon(Icons.memory, color: cs.primary),
              title: Text(t.useBuiltInEngine),
              subtitle: Text(t.useBuiltInEngineDesc, style: tt.bodySmall),
              value: settings.useEmbeddedRuntime,
              onChanged: (v) => notifier.setUseEmbeddedRuntime(v),
            ),
          ),
          _FooterText(t.audioEngineFooter),
          const _TtsModelManagerCard(),
          const SizedBox(height: 20),

          // ── Remote Backend ──
          _SectionHeader(t.remoteBackendSection),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.dns_outlined,
                        size: 20,
                        color: cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _urlCtl,
                          decoration: InputDecoration(
                            labelText: t.backendUrl,
                            hintText: t.backendUrlHint,
                            border: InputBorder.none,
                          ),
                          style: tt.bodyMedium,
                          onSubmitted: notifier.setBackendUrl,
                        ),
                      ),
                    ],
                  ),
                  if (settings.resolvedBaseURL == null)
                    Padding(
                      padding: const EdgeInsets.only(left: 32, bottom: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            size: 14,
                            color: cs.error,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            t.backendUnavailable,
                            style: tt.bodySmall?.copyWith(color: cs.error),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          _FooterText(t.backendUrlFooter),
          const SizedBox(height: 20),

          // ── Reader ──
          _SectionHeader(t.readerTitle),
          Card(
            child: Column(
              children: [
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

          // ── Playback ──
          _SectionHeader(t.playbackSection),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.speed, color: cs.onSurfaceVariant),
                  title: Text(t.audioRateLabel),
                  subtitle: Slider(
                    value: settings.audioRate,
                    min: 0.5,
                    max: 2.0,
                    divisions: 30,
                    label: '${settings.audioRate.toStringAsFixed(2)}x',
                    onChanged: notifier.setAudioRate,
                  ),
                  trailing: Text(
                    '${settings.audioRate.toStringAsFixed(2)}x',
                    style: tt.bodyMedium?.copyWith(
                      fontFeatures: [const FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: Icon(
                    Icons.timer_outlined,
                    color: cs.onSurfaceVariant,
                  ),
                  title: Text(t.wpmLabel),
                  subtitle: Slider(
                    value: settings.wpm.toDouble(),
                    min: 100,
                    max: 320,
                    divisions: 22,
                    label: '${settings.wpm}',
                    onChanged: (v) => notifier.setWpm(v.round()),
                  ),
                  trailing: Text(
                    '${settings.wpm}',
                    style: tt.bodyMedium?.copyWith(
                      fontFeatures: [const FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
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
                ListTile(
                  leading: Icon(Icons.open_in_new, color: cs.onSurfaceVariant),
                  title: Text(t.projectOnGithub),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    // URL launch placeholder
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _TtsModelManagerCard extends ConsumerStatefulWidget {
  const _TtsModelManagerCard();

  @override
  ConsumerState<_TtsModelManagerCard> createState() =>
      _TtsModelManagerCardState();
}

class _TtsModelManagerCardState extends ConsumerState<_TtsModelManagerCard> {
  Future<List<Map<String, dynamic>>>? _catalog;
  Map<String, String> _installedMetadata = const {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _catalog ??= _loadCatalog();
  }

  Future<List<Map<String, dynamic>>> _loadCatalog() async {
    final raw = await ref.read(embeddedConverterProvider).ttsModels();
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw const FormatException('Invalid TTS model catalog');
    }
    final models = decoded
        .whereType<Map>()
        .map(Map<String, dynamic>.from)
        .toList();
    final root = await _modelRoot();
    final metadata = <String, String>{};
    for (final model in models) {
      final id = model['id'];
      if (id is! String || id.isEmpty) continue;
      final value = await ref
          .read(embeddedConverterProvider)
          .ttsModelMetadata(modelId: id, root: root);
      if (value != null) metadata[id] = value;
    }
    if (mounted) _installedMetadata = metadata;
    return models;
  }

  Future<String> _modelRoot() async {
    final directory = await getApplicationSupportDirectory();
    return '${directory.path}/tts-models';
  }

  Future<void> _install(String modelId) async {
    try {
      await ref
          .read(embeddedConverterProvider)
          .installTtsModelFromCatalog(
            modelId: modelId,
            root: await _modelRoot(),
          );
      if (mounted) setState(() => _catalog = _loadCatalog());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Card(
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _catalog,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const ListTile(leading: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ListTile(
              leading: const Icon(Icons.memory_outlined),
              title: Text(t.downloadAll),
              subtitle: Text(snapshot.error.toString()),
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: t.refresh,
                onPressed: () => setState(() => _catalog = _loadCatalog()),
              ),
            );
          }
          final models = snapshot.data ?? const [];
          return Column(
            children: [
              ListTile(
                leading: const Icon(Icons.memory_outlined),
                title: Text(t.downloadAll),
                subtitle: Text(t.useBuiltInEngineDesc),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: t.refresh,
                  onPressed: () => setState(() => _catalog = _loadCatalog()),
                ),
              ),
              for (final model in models)
                ListTile(
                  title: Text('${model['id'] ?? ''}'),
                  subtitle: Text(
                    _installedMetadata.containsKey(model['id'])
                        ? t.downloadComplete
                        : '${model['languages'] ?? ''}',
                  ),
                  trailing: IconButton(
                    icon: Icon(
                      _installedMetadata.containsKey(model['id'])
                          ? Icons.delete_outline
                          : Icons.download_outlined,
                    ),
                    tooltip: _installedMetadata.containsKey(model['id'])
                        ? t.remove
                        : t.downloadAll,
                    onPressed: () => _installedMetadata.containsKey(model['id'])
                        ? _remove('${model['id']}')
                        : _install('${model['id']}'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _remove(String modelId) async {
    try {
      await ref
          .read(embeddedConverterProvider)
          .removeTtsModel(modelId: modelId, root: await _modelRoot());
      if (mounted) setState(() => _catalog = _loadCatalog());
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
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
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
