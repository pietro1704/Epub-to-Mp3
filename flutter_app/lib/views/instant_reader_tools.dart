part of 'instant_reader_view.dart';

extension _InstantReaderTools on _InstantReaderViewState {
  /// Start of the sentence being spoken, as an exact source position, or null
  /// when nothing audible belongs to this book. The audible chapter can differ
  /// from the shown one, so its measured speech alignment is read on demand.
  Future<ReaderListeningPosition?> _liveSentencePosition() async {
    final player = widget.player;
    final playerIndex = player?.currentIndexValue;
    if (player == null ||
        playerIndex == null ||
        player.currentBookId != widget.bookId) {
      return null;
    }
    final queueIndex = player.chapterIndexForPlayerIndex(playerIndex);
    if (queueIndex < 0 || queueIndex >= player.chapters.length) return null;
    // The audio queue names a chapter by its place in the book, which is not
    // the parser's FulltextChapter.index (that one starts at 1 for Rust books).
    final sourceIndex = player.chapters[queueIndex].index;
    if (sourceIndex < 0 || sourceIndex >= widget.fulltext.chapters.length) {
      return null;
    }
    final chapter = widget.fulltext.chapters[sourceIndex];
    final shown = identical(_resolveChapter(_currentChapterIndex), chapter);
    var measured = shown ? _measuredRange : null;
    final audio = player.currentAudioUri;
    final seconds = player.positionSeconds;
    if (measured == null && audio != null) {
      try {
        measured = (await MeasuredSpeechAlignment.read(
          audio,
        )).rangeAt(seconds, chapter.text);
      } on Object {
        measured = null; // Missing metadata keeps sentence-only resume.
      }
    }
    return liveSentenceStart(
          chapter: chapter,
          position: sourceIndex,
          measured: measured,
          liveSentenceId: shown ? _liveSentenceId : null,
        ) ??
        estimatedSentenceStart(
          chapter: chapter,
          position: sourceIndex,
          seconds: seconds,
          durationSeconds: player.durationSeconds,
        );
  }

  void _jumpToChapter(int index) {
    if (index < 0 || index >= widget.fulltext.chapters.length) return;
    _update(() {
      _currentChapterIndex = index;
      _visibleTextOffset = 0;
    });
    _savePosition();
  }

  void _showPanel(Widget panel) {
    final size = MediaQuery.sizeOf(context);
    if (size.width >= 720) {
      showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          alignment: Alignment.centerRight,
          child: SizedBox(width: 380, height: size.height * .85, child: panel),
        ),
      );
    } else {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => SizedBox(height: size.height * .8, child: panel),
      );
    }
  }

  void _showContents() {
    final t = AppLocalizations.of(context)!;
    _showPanel(
      Material(
        child: SafeArea(
          child: Column(
            children: [
              ListTile(
                title: Text(t.tableOfContents),
                trailing: IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: widget.fulltext.chapters.length,
                  itemBuilder: (context, index) => ListTile(
                    selected: index == _currentChapterIndex,
                    title: Text(widget.fulltext.chapters[index].displayTitle),
                    onTap: () {
                      Navigator.pop(context);
                      _jumpToChapter(index);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFootnotes(Chapter chapter) {
    final t = AppLocalizations.of(context)!;
    final notes = chapter.footnotes ?? const <FulltextFootnote>[];
    _showPanel(
      Material(
        child: SafeArea(
          child: Column(
            children: [
              ListTile(
                title: Text(t.readerFootnotes),
                trailing: IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: notes.length,
                  itemBuilder: (context, index) {
                    final note = notes[index];
                    return ListTile(
                      leading: Text(note.number ?? '${index + 1}'),
                      title: SelectableText(note.text),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSearch() {
    _showPanel(
      ReaderSearchOverlay(
        chapters: widget.fulltext.chapters,
        onJumpToChapter: _jumpToChapter,
        onJumpToPosition: (chapter, offset) {
          _jumpToChapter(chapter);
          _update(() => _requestedSourceOffset = offset);
        },
        onClose: () => Navigator.pop(context),
      ),
    );
  }

  void _showBookmarks() {
    final bookId = widget.bookId;
    if (bookId == null) return;
    _showPanel(
      BookmarksListScreen(bookId: bookId, onJumpToChapter: _jumpToChapter),
    );
  }

  void _addBookmark() {
    final bookId = widget.bookId;
    final chapter = _resolveChapter(_currentChapterIndex);
    if (bookId == null || chapter == null) return;
    ref
        .read(bookmarkStoreProvider)
        .addBookmark(
          bookId: bookId,
          chapterIndex: _currentChapterIndex,
          chapterTitle: chapter.displayTitle,
          startChar: _visibleTextOffset,
        );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppLocalizations.of(context)!.bookmarkAdded)),
    );
  }
}
