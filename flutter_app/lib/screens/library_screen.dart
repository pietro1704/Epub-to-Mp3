import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path_provider/path_provider.dart';

import '../features/library/public_book_catalog.dart';
import '../features/library/public_book_discovery_sheet.dart';
import '../features/library/public_book_download.dart';
import '../l10n/app_localizations.dart';
import '../models/book_entity.dart';
import '../services/conversion/epub_metadata_reader.dart';
import '../services/linux_book_import.dart';
import '../services/storage/library_store.dart';
import '../state/providers.dart';
import '../views/tag_editor_sheet.dart';
import '../services/playback/playback_recency_recorder.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'library_book_tile.dart';
part 'library_filter_controls.dart';

final libraryStoreProvider = ChangeNotifierProvider<LibraryStore>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  return LibraryStore(prefs: prefs, metadataReader: readEpubMetadata);
});

enum _SortMode { lastPlayed, title, dateAdded }

const _sortModePreferenceKey = 'library.sortMode.v1';

_SortMode _savedSortMode(SharedPreferences prefs) {
  final stored = prefs.getString(_sortModePreferenceKey);
  return _SortMode.values.firstWhere(
    (mode) => mode.name == stored,
    orElse: () => _SortMode.lastPlayed,
  );
}

/// Orders the library as Apple does: played books by last audible playback,
/// then the never-played ones by date added. Opening a book never reorders.
List<BookEntity> sortBooksByRecentPlayback(List<BookEntity> books) =>
    List.of(books)..sort((a, b) {
      final aPlayed = a.lastPlayedAt;
      final bPlayed = b.lastPlayedAt;
      if (aPlayed != null && bPlayed != null) {
        final byPlayed = bPlayed.compareTo(aPlayed);
        if (byPlayed != 0) return byPlayed;
      } else if (aPlayed != null) {
        return -1;
      } else if (bPlayed != null) {
        return 1;
      }
      return b.addedAt.compareTo(a.addedAt);
    });

/// Records playback recency for the book whose audio is audible.
final playbackRecencyProvider = Provider<PlaybackRecencyRecorder>((ref) {
  final recorder = PlaybackRecencyRecorder(
    player: ref.watch(globalAudioPlayerProvider),
    bookId: () => ref.read(currentlyPlayingBookIdProvider),
    onPlayed: (bookId) => ref.read(libraryStoreProvider).recordPlayback(bookId),
  );
  ref.onDispose(recorder.dispose);
  return recorder;
});

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  late _SortMode _sortMode = _savedSortMode(ref.read(sharedPrefsProvider));
  String? _selectedTag;
  String _searchQuery = '';

  LinuxBookImport? _linuxImport;

  @override
  void initState() {
    super.initState();
    if (!LinuxBookImport.isAvailable) return;
    final receiver = _linuxImport = LinuxBookImport(
      (paths, {required openInReader}) =>
          _importBooks(paths, openInReader: openInReader, revealLibrary: true),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) receiver.start();
    });
  }

  @override
  void dispose() {
    _linuxImport?.dispose();
    super.dispose();
  }

  Future<void> _showAddBook() async {
    final book = await showModalBottomSheet<BookEntity>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      isDismissible: false,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (sheetContext) => PublicBookDiscoverySheet(
        onPickFile: () {
          Navigator.pop(sheetContext);
          if (mounted) _pickAndImport();
        },
        onDownload: _downloadPublicBook,
      ),
    );
    if (mounted && book != null) _openInReader(ref, book);
  }

  Future<BookEntity> _downloadPublicBook(PublicBook book) async {
    final store = ref.read(libraryStoreProvider);
    final support = await getApplicationSupportDirectory();
    final download = await PublicBookDownload().download(
      uri: book.downloadUri,
      format: book.format,
      directory: Directory.fromUri(support.uri.resolve('library-books/')),
    );
    try {
      final id = await LibraryStore.contentHash(download.path);
      final existing = store.books.where((book) => book.id == id).firstOrNull;
      if (existing != null && await File(existing.filePath).exists()) {
        if (existing.filePath != download.path) await download.delete();
        return existing;
      }
      return await store.importBook(
        download.path,
        displayFilename: '${book.title}.${book.format.name}',
      );
    } on Exception {
      if (await download.exists()) await download.delete();
      rethrow;
    }
  }

  Future<void> _pickAndImport() async {
    final t = AppLocalizations.of(context)!;
    try {
      final paths = LinuxBookImport.isAvailable
          ? await LinuxBookImport.choose(
              title: t.addBook,
              cancel: t.cancel,
              accept: t.addBook,
            )
          : (await FilePicker.pickFiles(
              type: FileType.custom,
              allowedExtensions: ['epub', 'pdf'],
            )).map((file) => file.path).nonNulls;
      await _importBooks(paths);
    } on Exception catch (error) {
      _showImportError(error.toString());
    }
  }

  Future<void> _pasteBooks() async {
    try {
      await _importBooks(await LinuxBookImport.paste());
    } on Exception catch (error) {
      _showImportError(error.toString());
    }
  }

  Future<void> _importBooks(
    Iterable<String> paths, {
    bool openInReader = false,
    bool revealLibrary = false,
  }) async {
    BookEntity? firstBook;
    for (final path in paths.toSet()) {
      if (!mounted) return;
      if (LinuxBookImport.isAvailable &&
          !const ['.epub', '.pdf'].any(path.toLowerCase().endsWith)) {
        continue;
      }
      try {
        final book = await ref.read(libraryStoreProvider).importBook(path);
        firstBook ??= book;
      } on LibraryStoreException catch (error) {
        _showImportError(error.message);
      }
    }
    if (!mounted || firstBook == null) return;
    if (openInReader) {
      _openInReader(ref, firstBook);
    } else if (revealLibrary) {
      ref.read(appDestinationProvider.notifier).state = AppDestination.library;
    }
  }

  void _showImportError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _openInReader(WidgetRef ref, BookEntity book) {
    ref.read(currentlyReadingBookIdProvider.notifier).set(book.id);
    ref.read(appDestinationProvider.notifier).state = AppDestination.reader;
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
                ref.read(appDestinationProvider.notifier).state =
                    AppDestination.conversion;
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
              if (ref.read(currentlyReadingBookIdProvider) == book.id) {
                ref.read(currentlyReadingBookIdProvider.notifier).set(null);
              }
              unawaited(
                ref
                    .read(bookDerivedDataRemoverProvider)
                    .remove(book.id, player: ref.read(globalAudioPlayerProvider)),
              );
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
      case _SortMode.lastPlayed:
        base = sortBooksByRecentPlayback(base);
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

    final library = Scaffold(
      appBar: AppBar(
        title: Text(t.libraryTitle),
        actions: [
          Semantics(
            label: t.sortLibrary,
            child: PopupMenuButton<_SortMode>(
              icon: const Icon(Icons.sort),
              tooltip: t.sortLibrary,
              onSelected: (mode) {
                ref
                    .read(sharedPrefsProvider)
                    .setString(_sortModePreferenceKey, mode.name);
                setState(() => _sortMode = mode);
              },
              itemBuilder: (_) => [
                _sortItem(t.sortLastPlayed, _SortMode.lastPlayed),
                _sortItem(t.sortTitle, _SortMode.title),
                _sortItem(t.sortDateAdded, _SortMode.dateAdded),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: t.addBook,
            onPressed: _showAddBook,
          ),
        ],
      ),
      body: store.books.isEmpty
          ? _EmptyLibrary(onAdd: _showAddBook)
          : Column(
              children: [
                LibraryFilterControls(
                  searchQuery: _searchQuery,
                  selectedTag: _selectedTag,
                  allTags: allTags,
                  onSearchChanged: (value) =>
                      setState(() => _searchQuery = value),
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
    );
    if (!LinuxBookImport.isAvailable) return library;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): () {
          if (ref.read(appDestinationProvider) == AppDestination.library) {
            _pasteBooks();
          }
        },
      },
      child: Focus(autofocus: true, child: library),
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
