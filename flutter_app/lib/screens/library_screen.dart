import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../models/book_entity.dart';
import '../services/library_store.dart';
import '../state/providers.dart';
import 'player_reader_screen.dart';

/// Riverpod provider for [LibraryStore]. Uses ChangeNotifierProvider so
/// the grid rebuilds on every add/remove.
final libraryStoreProvider = ChangeNotifierProvider<LibraryStore>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  return LibraryStore(prefs: prefs);
});

/// Library-first home screen. Grid of imported EPUBs/PDFs.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

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

  void _confirmRemove(
      BuildContext context, LibraryStore store, BookEntity book) {
    final t = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(t.removeBookTitle),
        content: Text(t.removeBookMessage(book.resolvedTitle)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t.cancel),
          ),
          TextButton(
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final store = ref.watch(libraryStoreProvider);
    final books = store.books;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.libraryTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: t.addBook,
            onPressed: () => _pickAndImport(context, store),
          ),
        ],
      ),
      body: books.isEmpty
          ? _EmptyLibrary(onAdd: () => _pickAndImport(context, store))
          : _BookGrid(
              books: books,
              onTap: (book) {
                if (book.lastJobId != null) {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        PlayerReaderScreen(jobId: book.lastJobId!),
                  ));
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(t.noConversionYet)),
                  );
                }
              },
              onLongPress: (book) => _confirmRemove(context, store, book),
            ),
      floatingActionButton: books.isEmpty
          ? null
          : FloatingActionButton(
              onPressed: () => _pickAndImport(context, store),
              child: const Icon(Icons.add),
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.library_books_outlined,
              size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(t.libraryEmpty,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: Text(t.addBook),
          ),
        ],
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
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.65,
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
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _cover(cs)),
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
    return Container(
      color: cs.primaryContainer,
      child: Center(
        child: Icon(Icons.book, size: 48, color: cs.onPrimaryContainer),
      ),
    );
  }
}
