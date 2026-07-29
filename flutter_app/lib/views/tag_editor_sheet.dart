// Material 3 bottom sheet for editing tags on a BookEntity.
// Mirrors ios/EpubToMp3/EpubToMp3/Views/TagEditorSheet.swift using
// Material 3 patterns: InputChip (current tags), ActionChip (suggestions),
// Wrap instead of FlowLayout, showModalBottomSheet instead of .sheet.

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/book_entity.dart';
import '../services/library_store.dart';

/// Show the tag editor as a Material 3 modal bottom sheet.
/// Returns when the user dismisses the sheet.
Future<void> showTagEditorSheet({
  required BuildContext context,
  required BookEntity book,
  required LibraryStore store,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _TagEditorContent(book: book, store: store),
  );
}

class _TagEditorContent extends StatefulWidget {
  const _TagEditorContent({required this.book, required this.store});
  final BookEntity book;
  final LibraryStore store;

  @override
  State<_TagEditorContent> createState() => _TagEditorContentState();
}

class _TagEditorContentState extends State<_TagEditorContent> {
  final _controller = TextEditingController();

  LibraryStore get _store => widget.store;
  String get _bookId => widget.book.id;

  List<String> get _currentTags {
    final b = _store.books.where((b) => b.id == _bookId);
    return b.isEmpty ? [] : b.first.tags;
  }

  List<String> get _suggestions {
    final current = _currentTags.toSet();
    return _store.allTags.where((t) => !current.contains(t)).toList();
  }

  void _addTag() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _store.addTag(text, bookId: _bookId);
    _controller.clear();
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _store.addListener(_onStoreChanged);
  }

  @override
  void dispose() {
    _store.removeListener(_onStoreChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final tags = _currentTags;
    final suggestions = _suggestions;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      builder: (context, scrollController) => Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: ListView(
          controller: scrollController,
          children: [
            // Header
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.editTags,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(t.done),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Current tags section
            Text(t.tagsSection, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (tags.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final tag in tags)
                    InputChip(
                      label: Text(tag),
                      onDeleted: () {
                        _store.removeTag(tag, bookId: _bookId);
                      },
                    ),
                ],
              ),
            const SizedBox(height: 12),

            // New tag input
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: t.newTagHint,
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _addTag(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(onPressed: _addTag, child: Text(t.add)),
              ],
            ),

            // Suggestions
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(
                t.existingTags,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final tag in suggestions)
                    ActionChip(
                      label: Text(tag),
                      onPressed: () {
                        _store.addTag(tag, bookId: _bookId);
                      },
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
