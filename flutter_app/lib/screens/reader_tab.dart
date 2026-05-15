// Reader tab (tab 0). Shows the last-opened book's reader, or an empty
// state CTA to browse the library. Mirrors iOS MainReaderView.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/app_localizations.dart';
import '../state/providers.dart';
import 'book_open_screen.dart';
import 'library_screen.dart';

class ReaderTab extends ConsumerWidget {
  const ReaderTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookId = ref.watch(currentlyReadingBookIdProvider);
    final library = ref.watch(libraryStoreProvider);

    // Auto-clear if the book was removed from library.
    if (bookId != null && !library.books.any((b) => b.id == bookId)) {
      // Schedule the clear for after this build frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(currentlyReadingBookIdProvider.notifier).set(null);
      });
      return _emptyState(context, ref);
    }

    if (bookId == null) {
      return _emptyState(context, ref);
    }

    return BookOpenScreen(bookId: bookId);
  }

  Widget _emptyState(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(t.readerTitle)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.menu_book_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              t.pickBookToRead,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                // Switch to library tab (index 1).
                ref.read(rootTabIndexProvider.notifier).state = 1;
              },
              icon: const Icon(Icons.library_books),
              label: Text(t.browseLibrary),
            ),
          ],
        ),
      ),
    );
  }
}
