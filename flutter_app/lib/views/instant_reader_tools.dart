part of 'instant_reader_view.dart';

extension _InstantReaderTools on _InstantReaderViewState {
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
