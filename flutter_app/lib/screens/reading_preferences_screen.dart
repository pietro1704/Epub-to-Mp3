import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/app_settings.dart';
import '../models/reading_overrides.dart';
import '../state/providers.dart';
import '../views/reader_theme_colors.dart';

/// The single reading preferences screen (appearance and speed). Settings opens
/// it as "Default for all books"; a book's Aa opens it for that book, where the
/// mode is explicit at the top ("Only for this book" with "Use the default").
class ReadingPreferencesScreen extends ConsumerStatefulWidget {
  const ReadingPreferencesScreen({super.key, this.bookId});

  /// The open book, or null when opened from Settings.
  final String? bookId;

  @override
  ConsumerState<ReadingPreferencesScreen> createState() =>
      _ReadingPreferencesScreenState();
}

class _ReadingPreferencesScreenState
    extends ConsumerState<ReadingPreferencesScreen> {
  /// True while editing this book's own preferences.
  late bool _forBook =
      widget.bookId != null &&
      (ref.read(sharedPrefsProvider).getBool(_scopeKey) ?? true);

  /// "Only this book" switch: default on, and once turned off it stays off.
  static const _scopeKey = 'readingPrefsForBook';

  void _setForBook(bool value) {
    ref.read(sharedPrefsProvider).setBool(_scopeKey, value);
    setState(() => _forBook = value);
  }

  String? get _bookId => _forBook ? widget.bookId : null;

  AppSettings get _shown => ref.watch(readerSettingsProvider(_bookId));

  Future<void> _edit({
    required ReadingOverrides Function(ReadingOverrides) forBook,
    required Future<void> Function(SettingsNotifier) forDefault,
  }) async {
    final bookId = _bookId;
    if (bookId != null) {
      await ref
          .read(bookReadingOverridesProvider(bookId).notifier)
          .update(forBook);
    } else {
      await forDefault(ref.read(settingsProvider.notifier));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final settings = _shown;
    final bookId = widget.bookId;
    final overridden =
        bookId != null &&
        !ref.watch(bookReadingOverridesProvider(bookId)).isEmpty;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.readingPreferencesTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (bookId != null)
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  key: const ValueKey('reading-mode-default'),
                  label: Text(t.readingModeDefault),
                  selected: !_forBook,
                  onSelected: (_) => _setForBook(false),
                ),
                ChoiceChip(
                  key: const ValueKey('reading-mode-book'),
                  label: Text(t.readingModeBook),
                  selected: _forBook,
                  onSelected: (_) => _setForBook(true),
                ),
              ],
            )
          else
            Text(t.readingModeDefault, style: theme.textTheme.titleMedium),
          if (bookId != null && !_forBook)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                t.readingDefaultHint,
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (_forBook && bookId != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t.readingBookHint,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (overridden)
                    TextButton(
                      key: const ValueKey('reading-use-default'),
                      onPressed: () => ref
                          .read(bookReadingOverridesProvider(bookId).notifier)
                          .clear(),
                      child: Text(t.readingUseDefault),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Text(t.themeLabel, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.spaceEvenly,
            spacing: 12,
            runSpacing: 8,
            children: [
              for (final option in ReaderTheme.values.where(
                (o) => o != ReaderTheme.custom,
              ))
                _ThemeSwatch(
                  theme: option,
                  selected: settings.readerTheme == option,
                  onTap: () => _edit(
                    forBook: (o) => o.copyWith(theme: option),
                    forDefault: (n) => n.setReaderTheme(option),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(t.fontLabel, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ReaderFontFamily>(
            segments: [
              for (final f in ReaderFontFamily.values)
                ButtonSegment(value: f, label: Text(_fontName(t, f))),
            ],
            selected: {settings.readerFontFamily},
            onSelectionChanged: (s) => _edit(
              forBook: (o) => o.copyWith(fontFamily: s.first),
              forDefault: (n) => n.setReaderFontFamily(s.first),
            ),
            showSelectedIcon: false,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(t.sizeLabel),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.text_decrease),
                onPressed: settings.readerFontSize > 0
                    ? () => _edit(
                        forBook: (o) =>
                            o.copyWith(fontSize: settings.readerFontSize - 1),
                        forDefault: (n) =>
                            n.setReaderFontSize(settings.readerFontSize - 1),
                      )
                    : null,
              ),
              SizedBox(
                width: 56,
                child: Text(
                  '${settings.readerPointSize.toInt()} pt',
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.text_increase),
                onPressed: settings.readerFontSize < AppSettings.maxReaderFontStep
                    ? () => _edit(
                        forBook: (o) =>
                            o.copyWith(fontSize: settings.readerFontSize + 1),
                        forDefault: (n) =>
                            n.setReaderFontSize(settings.readerFontSize + 1),
                      )
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(t.layoutLabel, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ReaderLayout>(
            segments: [
              ButtonSegment(
                value: ReaderLayout.scrolling,
                label: Text(t.readerLayoutScrolling),
              ),
              ButtonSegment(
                value: ReaderLayout.paginated,
                label: Text(t.readerLayoutPaginated),
              ),
            ],
            selected: {settings.readerLayout},
            onSelectionChanged: (s) => _edit(
              forBook: (o) => o.copyWith(layout: s.first),
              forDefault: (n) => n.setReaderLayout(s.first),
            ),
            showSelectedIcon: false,
          ),
          _SliderRow(
            label: t.lineSpacingLabel,
            value: settings.readerLineSpacing,
            min: 0,
            max: 16,
            divisions: 8,
            display: '${settings.readerLineSpacing.toInt()} pt',
            onChanged: (v) => _edit(
              forBook: (o) => o.copyWith(lineSpacing: v),
              forDefault: (n) => n.setReaderLineSpacing(v),
            ),
          ),
          _SliderRow(
            label: t.marginLabel,
            value: settings.readerMargin,
            min: 8,
            max: 80,
            divisions: 18,
            display: '${settings.readerMargin.toInt()} pt',
            onChanged: (v) => _edit(
              forBook: (o) => o.copyWith(margin: v),
              forDefault: (n) => n.setReaderMargin(v),
            ),
          ),
          const SizedBox(height: 4),
          Text(t.readerAlignmentLabel, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ReaderTextAlignment>(
            segments: [
              ButtonSegment(
                value: ReaderTextAlignment.justified,
                label: Text(t.readerAlignmentJustified),
              ),
              ButtonSegment(
                value: ReaderTextAlignment.left,
                label: Text(t.readerAlignmentLeft),
              ),
            ],
            selected: {settings.readerTextAlignment},
            onSelectionChanged: (s) => _edit(
              forBook: (o) => o.copyWith(alignment: s.first),
              forDefault: (n) => n.setReaderTextAlignment(s.first),
            ),
            showSelectedIcon: false,
          ),
          if (settings.readerLayout == ReaderLayout.paginated) ...[
            const SizedBox(height: 8),
            Text(
              t.readerPageTurnStyle,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              key: const ValueKey('reader-page-turn-style'),
              segments: [
                ButtonSegment(value: 'flip', label: Text(t.pageTurnFlip)),
                ButtonSegment(value: 'slide', label: Text(t.pageTurnSlide)),
                ButtonSegment(value: 'none', label: Text(t.pageTurnNone)),
              ],
              selected: {settings.readerPageTurnStyle},
              onSelectionChanged: (s) => ref
                  .read(settingsProvider.notifier)
                  .setReaderPageTurnStyle(s.first),
              showSelectedIcon: false,
            ),
          ],
          if (!_forBook) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.readerShowPageNumbers),
              value: settings.readerShowPageNumbers,
              onChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .setReaderShowPageNumbers(v),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t.originalTypography),
              trailing: const Icon(Icons.restore),
              onTap: ref.read(settingsProvider.notifier).resetReaderTypography,
            ),
          ],
          SwitchListTile(
            key: const ValueKey('reader-follow-audio'),
            contentPadding: EdgeInsets.zero,
            title: Text(t.autoScrollLabel),
            subtitle: Text(t.autoScrollDesc),
            value: settings.readerAutoScroll,
            onChanged: (v) =>
                ref.read(settingsProvider.notifier).setReaderAutoScroll(v),
          ),
          _SliderRow(
            label: t.readingSpeedLabel,
            value: settings.audioRate.clamp(0.5, 3.0).toDouble(),
            min: 0.5,
            max: 3.0,
            divisions: 25,
            display: '${settings.audioRate.toStringAsFixed(2)}x',
            onChanged: (v) => _edit(
              forBook: (o) => o.copyWith(audioRate: v),
              forDefault: (n) => n.setAudioRate(v),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final ReaderTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    key: ValueKey('reading-theme-${theme.rawValue}'),
    onTap: onTap,
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ReaderThemeColors.previewColor(theme),
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey.shade400,
                width: selected ? 3 : 1,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _themeName(AppLocalizations.of(context)!, theme),
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    ),
  );
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      children: [
        SizedBox(width: 120, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 56, child: Text(display, textAlign: TextAlign.end)),
      ],
    ),
  );
}

String _themeName(AppLocalizations t, ReaderTheme theme) => switch (theme) {
  ReaderTheme.auto => t.readerThemeAuto,
  ReaderTheme.light => t.readerThemeLight,
  ReaderTheme.sepia => t.readerThemeSepia,
  ReaderTheme.parchment => t.readerThemeParchment,
  ReaderTheme.paper => t.readerThemePaper,
  ReaderTheme.dark => t.readerThemeDark,
  ReaderTheme.black => t.readerThemeBlack,
  ReaderTheme.custom => t.readerThemeCustom,
};

String _fontName(AppLocalizations t, ReaderFontFamily font) => switch (font) {
  ReaderFontFamily.serif => t.readerFontSerif,
  ReaderFontFamily.sans => t.readerFontSans,
  ReaderFontFamily.mono => t.readerFontMono,
};
