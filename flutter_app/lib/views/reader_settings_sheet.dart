import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/app_settings.dart';
import '../state/providers.dart';
import 'reader_theme_colors.dart';

class ReaderSettingsSheet extends ConsumerWidget {
  const ReaderSettingsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Theme
            Text('Theme',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _ThemeGrid(
              selected: settings.readerTheme,
              onSelect: (t) => notifier.setReaderTheme(t),
            ),
            const SizedBox(height: 16),

            // Font family
            Text('Font',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<ReaderFontFamily>(
              segments: ReaderFontFamily.values.map((f) {
                return ButtonSegment(
                  value: f,
                  label: Text(f.displayName),
                );
              }).toList(),
              selected: {settings.readerFontFamily},
              onSelectionChanged: (s) =>
                  notifier.setReaderFontFamily(s.first),
              showSelectedIcon: false,
            ),
            const SizedBox(height: 12),

            // Font size
            Row(
              children: [
                const Text('Size'),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.text_decrease),
                  onPressed: settings.readerFontSize > 0
                      ? () => notifier.setReaderFontSize(
                            settings.readerFontSize - 1)
                      : null,
                ),
                SizedBox(
                  width: 50,
                  child: Text(
                    '${settings.readerPointSize.toInt()}pt',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.text_increase),
                  onPressed: settings.readerFontSize < 4
                      ? () => notifier.setReaderFontSize(
                            settings.readerFontSize + 1)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Layout
            Text('Layout',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<ReaderLayout>(
              segments: ReaderLayout.values.map((l) {
                return ButtonSegment(
                  value: l,
                  label: Text(l.displayName),
                );
              }).toList(),
              selected: {settings.readerLayout},
              onSelectionChanged: (s) =>
                  notifier.setReaderLayout(s.first),
              showSelectedIcon: false,
            ),
            const SizedBox(height: 12),

            // Line spacing
            Row(
              children: [
                const Text('Line spacing'),
                const Spacer(),
                SizedBox(
                  width: 160,
                  child: Slider(
                    value: settings.readerLineSpacing,
                    min: 0,
                    max: 16,
                    divisions: 8,
                    onChanged: (v) => notifier.setReaderLineSpacing(v),
                  ),
                ),
              ],
            ),

            // Margin
            Row(
              children: [
                const Text('Margin'),
                const Spacer(),
                SizedBox(
                  width: 160,
                  child: Slider(
                    value: settings.readerMargin,
                    min: 16,
                    max: 80,
                    divisions: 16,
                    onChanged: (v) => notifier.setReaderMargin(v),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeGrid extends StatelessWidget {
  final ReaderTheme selected;
  final ValueChanged<ReaderTheme> onSelect;

  const _ThemeGrid({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final themes = ReaderTheme.values
        .where((t) => t != ReaderTheme.custom)
        .toList();
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: themes.map((t) => _themeCircle(t)).toList(),
    );
  }

  Widget _themeCircle(ReaderTheme theme) {
    final isSelected = selected == theme;
    final color = ReaderThemeColors.previewColor(theme);
    return GestureDetector(
      onTap: () => onSelect(theme),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: Border.all(
                color: isSelected ? Colors.blue : Colors.grey[300]!,
                width: isSelected ? 2.5 : 1,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            theme.displayName,
            style: TextStyle(
              fontSize: 10,
              color: isSelected ? null : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }
}
