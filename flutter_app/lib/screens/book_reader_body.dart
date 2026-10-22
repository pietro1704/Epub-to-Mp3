part of 'book_open_screen.dart';

class _BookReaderBody extends ConsumerWidget {
  const _BookReaderBody({
    super.key,
    required this.bookId,
    required this.phase,
    required this.errorMessage,
    required this.fulltext,
    required this.localJob,
    required this.resourcePolicy,
    required this.isConverting,
    required this.playableChapters,
    required this.onRetry,
  });

  final String bookId;
  final _Phase phase;
  final String? errorMessage;
  final EbookFulltext? fulltext;
  final LocalConversionJob? localJob;
  final PlaybackFirstResourcePolicy resourcePolicy;
  final bool isConverting;
  final List<ChapterProgress> playableChapters;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = AppLocalizations.of(context)!;
    final library = ref.watch(libraryStoreProvider);
    BookEntity? book;
    for (final candidate in library.books) {
      if (candidate.id == bookId) {
        book = candidate;
        break;
      }
    }
    final bookTitle = book?.resolvedTitle ?? '';

    if (book != null && isPdfFilePath(book.filePath)) {
      return PdfReaderScreen(
        bookId: bookId,
        title: bookTitle,
        filePath: book.filePath,
        prefs: ref.watch(sharedPrefsProvider),
      );
    }

    switch (phase) {
      case _Phase.resolving:
        return Scaffold(
          appBar: AppBar(title: Text(bookTitle)),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(t.parsingBook),
              ],
            ),
          ),
        );

      case _Phase.error:
        return Scaffold(
          appBar: AppBar(title: Text(bookTitle)),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  t.parsingFailed,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      errorMessage!,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: Text(t.retry),
                ),
              ],
            ),
          ),
        );

      case _Phase.ready:
        final coverArt = book?.coverBase64 != null
            ? _decodeCover(book!.coverBase64!)
            : null;
        final player = ref.read(globalAudioPlayerProvider);
        return Scaffold(
          appBar: AppBar(
            title: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(bookTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (localJob?.usedSelections.isNotEmpty == true)
                  Text(
                    t.ttsActualVoices(
                      localJob!.usedSelections
                          .map((selection) => selection.displayName)
                          .join(', '),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            titleTextStyle: Theme.of(context).textTheme.titleMedium,
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          body: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => resourcePolicy.recordReaderInteraction(),
            onPointerMove: (_) => resourcePolicy.recordReaderInteraction(),
            child: Stack(
              children: [
                InstantReaderView(
                  fulltext: fulltext!,
                  bookId: bookId,
                  coverArt: coverArt,
                  player: player,
                  initialChapterIndex: playableChapters.isEmpty
                      ? 0
                      : ResumePositionRouter(
                              playableChapters: List.of(playableChapters),
                            ).queueIndexForSavedValue(
                              ref
                                      .read(resumeStoreProvider)
                                      .loadBookPosition(bookId)
                                      ?.chapter ??
                                  0,
                            ) ??
                            0,
                ),
                if (isConverting)
                  const Positioned(
                    right: 24,
                    bottom: 24,
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
    }
  }

  static Uint8List? _decodeCover(String base64str) {
    try {
      return base64Decode(base64str);
    } catch (_) {
      return null;
    }
  }
}
