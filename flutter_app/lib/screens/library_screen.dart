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

part 'library_book_tile.dart';
part 'library_filter_controls.dart';

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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  void _openInReader(WidgetRef ref, BookEntity book) {
    ref.read(currentlyReadingBookIdProvider.notifier).set(book.id);
    ref.read(rootTabIndexProvider.notifier).state = 0;
  }

  void _showBookActions(
    BuildContext context,
    LibraryStore store,
    BookEntity book,
  ) {
    final t = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.download_for_offline_outlined),
              title: Text(t.downloadAll),
              onTap: () {
                Navigator.pop(context);
                ref.read(manualDownloadRequestProvider.notifier).state =
                    book.filePath;
                ref.read(rootTabIndexProvider.notifier).state = 2;
              },
            ),
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: Text(t.editTags),
              onTap: () {
                Navigator.pop(context);
                showTagEditorSheet(context: context, book: book, store: store);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                t.removeFromLibrary,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
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
    BuildContext context,
    LibraryStore store,
    BookEntity book,
  ) {
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
              ref.read(bookmarkStoreProvider).removeAll(book.id);
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
        base.sort(
          (a, b) => a.resolvedTitle.toLowerCase().compareTo(
            b.resolvedTitle.toLowerCase(),
          ),
        );
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
                LibraryFilterControls(
                  searchQuery: _searchQuery,
                  selectedTag: _selectedTag,
                  allTags: allTags,
                  onSearchChanged: (value) => setState(() => _searchQuery = value),
                  onTagChanged: (value) => setState(() => _selectedTag = value),
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
            Icon(
              Icons.check,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            )
          else
            const SizedBox(width: 18),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }
}
