part of 'library_screen.dart';

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
        final tileWidth = (constraints.maxWidth - 48) / 2;
        final textTheme = Theme.of(context).textTheme;
        double labelHeight(String text, TextStyle? style) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          final height = painter.height;
          painter.dispose();
          return height;
        }

        // Reserve two title lines and one author line below a 2:3 cover.
        final tileHeight = (tileWidth - 8) * 1.5 +
            labelHeight('Ag\nAg', textTheme.labelLarge) +
            labelHeight('Ag', textTheme.bodySmall) +
            24;
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            mainAxisExtent: tileHeight,
          ),
          itemCount: books.length,
          itemBuilder: (context, i) {
            final book = books[i];
            return LibraryBookTile(
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

class LibraryBookTile extends StatelessWidget {
  const LibraryBookTile({
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
        return Image.memory(base64Decode(book.coverBase64!), fit: BoxFit.cover);
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
      LibraryStatus.textOnly => (Icons.book, '', Colors.transparent),
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
