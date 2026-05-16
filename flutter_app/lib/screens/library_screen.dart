import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/book_entity.dart';
import '../services/epub_metadata_reader.dart';
import '../services/library_store.dart';
import '../state/providers.dart';
import '../views/tag_editor_sheet.dart';

final libraryStoreProvider = ChangeNotifierProvider<LibraryStore>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  return LibraryStore(prefs: prefs, metadataReader: readEpubMetadata);
});

enum _SortMode { lastOpened, title, dateAdded }

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  _SortMode _sortMode = _SortMode.lastOpened;
  String? _selectedTag;
  String _searchQuery = '';

  Future<void> _pickAndImport(BuildContext context, LibraryStore store) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['epub', 'pdf'],
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    for (final file in result.files) {
      final path = file.path;
      if (path == null) continue;
      try {
        await store.importBook(path);
      } on LibraryStoreException catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    }
  }

  void _openInReader(WidgetRef ref, BookEntity book) {
    ref.read(currentlyReadingBookIdProvider.notifier).set(book.id);
    ref.read(rootTabIndexProvider.notifier).state = 0;
  }

  void _showBookActions(
      BuildContext context, LibraryStore store, BookEntity book) {
    final t = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: Text(t.editTags),
              onTap: () {
                Navigator.pop(context);
                showTagEditorSheet(
                  context: context,
                  book: book,
                  store: store,
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: Text(t.removeFromLibrary,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(context);
                _confirmRemove(context, store, book);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmRemove(
      BuildContext context, LibraryStore store, BookEntity book) {
    final t = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text(t.removeBookTitle),
        content: Text(t.removeBookMessage(book.resolvedTitle)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () {
              store.remove(book.id);
              Navigator.pop(context);
            },
            child: Text(t.remove),
          ),
        ],
      ),
    );
  }

  List<BookEntity> _filtered(List<BookEntity> books) {
    var base = _selectedTag != null
        ? books.where((b) => b.tags.contains(_selectedTag)).toList()
        : List<BookEntity>.from(books);
    final q = _searchQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      base = base.where((b) {
        return b.resolvedTitle.toLowerCase().contains(q) ||
            (b.author?.toLowerCase().contains(q) ?? false) ||
            b.tags.any((t) => t.toLowerCase().contains(q));
      }).toList();
    }
    switch (_sortMode) {
      case _SortMode.lastOpened:
        base.sort((a, b) {
          final aDate = a.lastOpenedAt ?? a.addedAt;
          final bDate = b.lastOpenedAt ?? b.addedAt;
          return bDate.compareTo(aDate);
        });
      case _SortMode.title:
        base.sort((a, b) => a.resolvedTitle
            .toLowerCase()
            .compareTo(b.resolvedTitle.toLowerCase()));
      case _SortMode.dateAdded:
        base.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    }
    return base;
  }

  @override
  Widget build(BuildContext context, [WidgetRef? _]) {
    final t = AppLocalizations.of(context)!;
    final store = ref.watch(libraryStoreProvider);
    final books = _filtered(store.books);
    final allTags = store.allTags;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.libraryTitle),
        actions: [
          Semantics(
            label: t.sortLibrary,
            child: PopupMenuButton<_SortMode>(
              icon: const Icon(Icons.sort),
              tooltip: t.sortLibrary,
              onSelected: (mode) => setState(() => _sortMode = mode),
              itemBuilder: (_) => [
                _sortItem(t.sortLastOpened, _SortMode.lastOpened),
                _sortItem(t.sortTitle, _SortMode.title),
                _sortItem(t.sortDateAdded, _SortMode.dateAdded),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: t.addBook,
            onPressed: () => _pickAndImport(context, store),
          ),
        ],
      ),
      body: store.books.isEmpty
          ? _EmptyLibrary(onAdd: () => _pickAndImport(context, store))
          : Column(
              children: [
                // Search bar
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: SearchBar(
                    hintText: t.searchLibrary,
                    leading: const Icon(Icons.search),
                    trailing: _searchQuery.isNotEmpty
                        ? [
                            IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () =>
                                  setState(() => _searchQuery = ''),
                            ),
                          ]
                        : null,
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
                // Tag filter chips
                if (allTags.isNotEmpty)
                  SizedBox(
                    height: 48,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: FilterChip(
                            label: Text(t.allFilter),
                            selected: _selectedTag == null,
                            onSelected: (_) =>
                                setState(() => _selectedTag = null),
                          ),
                        ),
                        for (final tag in allTags)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilterChip(
                              label: Text(tag),
                              selected: _selectedTag == tag,
                              onSelected: (_) => setState(() {
                                _selectedTag =
                                    _selectedTag == tag ? null : tag;
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                // Book grid
                Expanded(
                  child: books.isEmpty
                      ? Center(child: Text(t.noResults))
                      : _BookGrid(
                          books: books,
                          onTap: (book) => _openInReader(ref, book),
                          onLongPress: (book) =>
                              _showBookActions(context, store, book),
                        ),
                ),
              ],
            ),
      floatingActionButton: store.books.isEmpty
          ? null
          : FloatingActionButton(
              onPressed: () => _pickAndImport(context, store),
              child: const Icon(Icons.add),
            ),
    );
  }

  PopupMenuItem<_SortMode> _sortItem(String label, _SortMode mode) {
    return PopupMenuItem(
      value: mode,
      child: Row(
        children: [
          if (_sortMode == mode)
            Icon(Icons.check,
                size: 18, color: Theme.of(context).colorScheme.primary)
          else
            const SizedBox(width: 18),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_outlined, size: 80, color: cs.secondary),
              const SizedBox(height: 24),
              Text(
                t.libraryEmpty,
                style: tt.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                t.libraryEmptyDesc,
                textAlign: TextAlign.center,
                style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: Text(t.addBook),
              ),
              const SizedBox(height: 16),
              Text(
                t.drmFootnote,
                textAlign: TextAlign.center,
                style: tt.bodySmall?.copyWith(color: cs.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookGrid extends StatelessWidget {
  const _BookGrid({
    required this.books,
    required this.onTap,
    required this.onLongPress,
  });
  final List<BookEntity> books;
  final ValueChanged<BookEntity> onTap;
  final ValueChanged<BookEntity> onLongPress;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 0) return const SizedBox.shrink();
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 180,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.6,
          ),
          itemCount: books.length,
          itemBuilder: (context, i) {
            final book = books[i];
            return _BookCard(
              book: book,
              onTap: () => onTap(book),
              onLongPress: () => onLongPress(book),
            );
          },
        );
      },
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.onTap,
    required this.onLongPress,
  });
  final BookEntity book;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: book.resolvedTitle,
      button: true,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ExcludeSemantics(child: _cover(cs)),
                    if (book.status != LibraryStatus.textOnly)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: _StatusBadge(status: book.status),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.resolvedTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  if (book.author != null)
                    Text(
                      book.author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _cover(ColorScheme cs) {
    if (book.coverBase64 != null) {
      try {
        return Image.memory(
          base64Decode(book.coverBase64!),
          fit: BoxFit.cover,
        );
      } catch (_) {
        // Fall through to placeholder
      }
    }
    final isPdf = book.filePath.toLowerCase().endsWith('.pdf');
    return Container(
      color: cs.primaryContainer,
      child: Center(
        child: Icon(
          isPdf ? Icons.picture_as_pdf : Icons.book,
          size: 48,
          color: cs.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final LibraryStatus status;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    final (icon, label, color) = switch (status) {
      LibraryStatus.offlineReady => (
          Icons.check_circle,
          t.offlineReady,
          Colors.green,
        ),
      LibraryStatus.caching => (
          Icons.cloud_download,
          t.cachingLabel,
          Colors.orange,
        ),
      LibraryStatus.textOnly => (
          Icons.book,
          '',
          Colors.transparent,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 10,
                ),
          ),
        ],
      ),
    );
  }
}
