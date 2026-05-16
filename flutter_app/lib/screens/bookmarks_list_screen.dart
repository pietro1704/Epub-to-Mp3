// Material 3 mirror of ios/EpubToMp3/EpubToMp3/Views/BookmarksListView.swift
//
// SegmentedButton filter (All / Bookmarks / Highlights), Dismissible
// swipe-to-delete, bottom sheet note editor with colour picker.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/bookmark.dart';
import '../services/bookmark_store.dart';
import '../state/providers.dart';

class BookmarksListScreen extends ConsumerStatefulWidget {
  const BookmarksListScreen({
    super.key,
    required this.bookId,
    this.onJumpToChapter,
  });

  final String bookId;
  final void Function(int chapterIndex)? onJumpToChapter;

  @override
  ConsumerState<BookmarksListScreen> createState() =>
      _BookmarksListScreenState();
}

enum _Filter { all, bookmarks, highlights }

class _BookmarksListScreenState extends ConsumerState<BookmarksListScreen> {
  _Filter _filter = _Filter.all;

  List<Bookmark> _filtered(List<Bookmark> all) => switch (_filter) {
        _Filter.all => all,
        _Filter.bookmarks => all.where((b) => !b.isHighlight).toList(),
        _Filter.highlights => all.where((b) => b.isHighlight).toList(),
      };

  void _showNoteEditor(Bookmark bm) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _NoteEditorSheet(
        bookmark: bm,
        bookmarkStore: ref.read(bookmarkStoreProvider),
      ),
    );
  }

  void _confirmDelete(Bookmark bm) {
    final t = AppLocalizations.of(context)!;
    final store = ref.read(bookmarkStoreProvider);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.removeBookmarkTitle),
        content: Text(t.removeBookmarkMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.cancel),
          ),
          TextButton(
            onPressed: () {
              store.remove(bm.id);
              Navigator.pop(ctx);
            },
            child: Text(t.remove),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final store = ref.watch(bookmarkStoreProvider);
    final all = store.bookmarksForBook(widget.bookId);
    final items = _filtered(all);

    return Scaffold(
      appBar: AppBar(
        title: Text(t.bookmarksTitle),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<_Filter>(
              segments: [
                ButtonSegment(value: _Filter.all, label: Text(t.filterAll)),
                ButtonSegment(
                    value: _Filter.bookmarks, label: Text(t.filterBookmarks)),
                ButtonSegment(
                    value: _Filter.highlights,
                    label: Text(t.filterHighlights)),
              ],
              selected: {_filter},
              onSelectionChanged: (v) => setState(() => _filter = v.first),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? _EmptyState(filter: _filter)
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final bm = items[i];
                      return Dismissible(
                        key: ValueKey(bm.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          color: Theme.of(context).colorScheme.error,
                          child: Icon(
                            Icons.delete,
                            color: Theme.of(context).colorScheme.onError,
                          ),
                        ),
                        confirmDismiss: (_) async {
                          _confirmDelete(bm);
                          return false; // dialog handles removal
                        },
                        child: _BookmarkTile(
                          bookmark: bm,
                          onTap: () => widget.onJumpToChapter?.call(bm.chapterIndex),
                          onEdit: () => _showNoteEditor(bm),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bookmark tile
// ---------------------------------------------------------------------------

class _BookmarkTile extends StatelessWidget {
  const _BookmarkTile({
    required this.bookmark,
    this.onTap,
    this.onEdit,
  });

  final Bookmark bookmark;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;

  Color _highlightColor(HighlightColor c) => switch (c) {
        HighlightColor.yellow => Colors.yellow,
        HighlightColor.blue => Colors.blue,
        HighlightColor.green => Colors.green,
        HighlightColor.pink => Colors.pink,
        HighlightColor.orange => Colors.orange,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: bookmark.isHighlight
          ? Container(
              width: 4,
              height: 40,
              decoration: BoxDecoration(
                color: _highlightColor(bookmark.color),
                borderRadius: BorderRadius.circular(2),
              ),
            )
          : const Icon(Icons.bookmark, color: Colors.orange),
      title: Text(
        bookmark.chapterTitle,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (bookmark.isHighlight)
            Text(
              bookmark.selectedText,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          if (bookmark.note != null && bookmark.note!.isNotEmpty)
            Text(
              bookmark.note!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          Text(
            _relativeTime(bookmark.createdAt),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
      onTap: onTap,
      trailing: IconButton(
        icon: const Icon(Icons.edit_note, size: 20),
        onPressed: onEdit,
      ),
    );
  }

  static String _relativeTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filter});
  final _Filter filter;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.bookmark_border,
            size: 48,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            t.noBookmarksYet,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              t.noBookmarksHint,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Note editor bottom sheet
// ---------------------------------------------------------------------------

class _NoteEditorSheet extends StatefulWidget {
  const _NoteEditorSheet({
    required this.bookmark,
    required this.bookmarkStore,
  });

  final Bookmark bookmark;
  final BookmarkStore bookmarkStore;

  @override
  State<_NoteEditorSheet> createState() => _NoteEditorSheetState();
}

class _NoteEditorSheetState extends State<_NoteEditorSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.bookmark.note ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _highlightColor(HighlightColor c) => switch (c) {
        HighlightColor.yellow => Colors.yellow,
        HighlightColor.blue => Colors.blue,
        HighlightColor.green => Colors.green,
        HighlightColor.pink => Colors.pink,
        HighlightColor.orange => Colors.orange,
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t.editNote,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t.cancel),
              ),
              FilledButton(
                onPressed: () {
                  final text = _controller.text.trim();
                  widget.bookmarkStore.updateNote(
                    widget.bookmark.id,
                    text.isEmpty ? null : text,
                  );
                  Navigator.pop(context);
                },
                child: Text(t.save),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: t.addNoteHint,
              border: const OutlineInputBorder(),
            ),
          ),
          if (widget.bookmark.isHighlight) ...[
            const SizedBox(height: 16),
            Text(
              t.highlightedText,
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 4),
            Text(
              widget.bookmark.selectedText,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            Text(
              t.colorLabel,
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: HighlightColor.values.map((c) {
                final isSelected = widget.bookmark.color == c;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () {
                      widget.bookmarkStore.updateColor(widget.bookmark.id, c);
                      setState(() {});
                    },
                    child: CircleAvatar(
                      radius: 16,
                      backgroundColor: _highlightColor(c),
                      child: isSelected
                          ? const Icon(Icons.check, size: 16, color: Colors.white)
                          : null,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
