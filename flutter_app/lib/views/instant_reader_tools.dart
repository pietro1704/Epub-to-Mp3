part of 'instant_reader_view.dart';

extension _InstantReaderTools on _InstantReaderViewState {
  /// The recent tool, unless it cannot apply to this chapter (Footnotes without
  /// notes), in which case the text appearance stands in without forgetting it.
  ReaderTool _shownTool(Chapter chapter) {
    final recent = ref.watch(readerRecentToolProvider);
    return _toolApplies(recent, chapter) ? recent : ReaderTool.appearance;
  }

  /// Footnotes need notes in the chapter; Listen needs a way to start listening.
  bool _toolApplies(ReaderTool tool, Chapter chapter) => switch (tool) {
    ReaderTool.footnotes => chapter.hasFootnotes,
    ReaderTool.listen => widget.onListenFrom != null,
    _ => true,
  };

  ({IconData icon, String label, VoidCallback run}) _toolDescriptor(
    ReaderTool tool,
    Chapter chapter,
  ) {
    final t = AppLocalizations.of(context)!;
    return switch (tool) {
      ReaderTool.appearance => (
        icon: Icons.text_format,
        label: t.readerAppearance,
        run: _showReaderSettings,
      ),
      ReaderTool.contents => (
        icon: Icons.list,
        label: t.tableOfContents,
        run: _showContents,
      ),
      ReaderTool.search => (
        icon: Icons.search,
        label: t.searchInBook,
        run: _showSearch,
      ),
      ReaderTool.bookmarks => (
        icon: Icons.bookmark_outline,
        label: t.bookmarksTitle,
        run: _showBookmarks,
      ),
      ReaderTool.footnotes => (
        icon: Icons.notes,
        label: t.readerFootnotes,
        run: () => _showFootnotes(chapter),
      ),
      ReaderTool.listen => (
        icon: Icons.play_arrow,
        label: t.play,
        run: () => _playFromHere(chapter, _visibleTextOffset),
      ),
      ReaderTool.voiceModels => (
        icon: Icons.record_voice_over,
        label: t.modelsTitle,
        run: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ModelsScreen()),
        ),
      ),
    };
  }

  List<Widget> _chromeTools(Chapter chapter, Color color) {
    final tool = _shownTool(chapter);
    final descriptor = _toolDescriptor(tool, chapter);
    return [
      IconButton(
        key: const ValueKey('reader-recent-tool'),
        icon: Icon(descriptor.icon, color: color),
        tooltip: descriptor.label,
        onPressed: descriptor.run,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      ),
    ];
  }

  /// Every tool except the one already beside More, plus Add bookmark.
  List<ReaderMenuEntry> _menuEntries(Chapter chapter) {
    final t = AppLocalizations.of(context)!;
    final shown = _shownTool(chapter);
    return [
      for (final tool in ReaderTool.values)
        if (tool != shown && _toolApplies(tool, chapter))
          () {
            final descriptor = _toolDescriptor(tool, chapter);
            return ReaderMenuEntry(
              keyName: tool.name,
              icon: descriptor.icon,
              label: descriptor.label,
              tool: tool,
              onSelected: descriptor.run,
            );
          }(),
      ReaderMenuEntry(
        keyName: 'add-bookmark',
        icon: Icons.bookmark_add_outlined,
        label: t.addBookmark,
        onSelected: _addBookmark,
      ),
    ];
  }

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

  /// "Play from here": the selection start becomes the listening start. The
  /// reader's offsets are UTF-16 into the chapter text; listening starts count
  /// Unicode scalars, so the position is converted exactly.
  void _playFromHere(Chapter chapter, int utf16Offset) {
    final position = widget.fulltext.chapters.indexOf(chapter);
    if (position < 0) return;
    try {
      unawaited(
        widget.onListenFrom!(
          ReaderListeningPosition.fromUtf16(position, chapter.text, utf16Offset),
        ),
      );
    } on FormatException {
      // A selection outside the chapter text starts nothing.
    }
  }

  /// Moves to the playing chapter named by a pending player request for this
  /// book. The request carries the chapter's place in the book, the axis of
  /// the audio queue, which is also the reader's own chapter axis.
  void _applyPlaybackJump(({String bookId, int chapterIndex})? request) {
    if (request == null || request.bookId != widget.bookId) return;
    ref.read(readerPlaybackJumpProvider.notifier).state = null;
    _jumpToChapter(request.chapterIndex);
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

  Future<void> _showContents() async {
    final t = AppLocalizations.of(context)!;
    final rows = readerTocRows(widget.fulltext);
    final bookId = widget.bookId;
    final job = bookId == null
        ? null
        : await ref.read(localConversionJobStoreProvider).load(bookId, 'local-$bookId');
    if (!mounted) return;
    final audio = chapterAudioStates(job);
    _showPanel(
      Material(
        child: SafeArea(
          child: Column(
            children: [
              ListTile(
                title: Text(t.tableOfContents),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.downloadActions != null)
                      _downloadMenu(audio),
                    if (audio.isNotEmpty && bookId != null)
                      IconButton(
                        tooltip: t.tocRemoveDownloads,
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _confirmRemoveAudio(bookId),
                      ),
                    IconButton(
                      tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, position) {
                    final row = rows[position];
                    final index = row.chapterIndex;
                    return ListTile(
                      contentPadding: EdgeInsetsDirectional.only(
                        start: 16.0 + 16 * row.level,
                        end: 16,
                      ),
                      selected: index == _currentChapterIndex,
                      enabled: index != null,
                      title: Text(row.title),
                      trailing: switch (index == null ? null : audio[index]) {
                        ChapterAudioState.ready => Icon(
                          Icons.check_circle,
                          semanticLabel: t.tocAudioReady,
                        ),
                        ChapterAudioState.converting => Icon(
                          Icons.hourglass_empty,
                          semanticLabel: t.tocAudioConverting,
                        ),
                        ChapterAudioState.failed => Icon(
                          Icons.error_outline,
                          semanticLabel: t.tocAudioFailed,
                        ),
                        null => null,
                      },
                      onTap: index == null
                          ? null
                          : () {
                              Navigator.pop(context);
                              _jumpToChapter(index);
                              final offset = row.anchorOffset;
                              if (offset != null) {
                                _update(() => _requestedSourceOffset = offset);
                              }
                            },
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

  Widget _downloadMenu(Map<int, ChapterAudioState> audio) {
    final t = AppLocalizations.of(context)!;
    final actions = contentsDownloadActions(audio, widget.fulltext.chapters.length);
    if (actions.isEmpty) return const SizedBox.shrink();
    final bulk = widget.downloadActions!;
    return PopupMenuButton<ContentsDownloadAction>(
      key: const ValueKey('contents-download-menu'),
      icon: const Icon(Icons.more_vert),
      onSelected: (action) {
        switch (action) {
          case ContentsDownloadAction.downloadAll:
            unawaited(bulk.downloadAll());
          case ContentsDownloadAction.cancel:
            unawaited(bulk.cancel());
          case ContentsDownloadAction.retryFailed:
            final first = firstFailedChapter(audio);
            if (first != null) unawaited(bulk.retryFrom(first));
          case ContentsDownloadAction.shareAudio:
            unawaited(bulk.shareAudio());
        }
        Navigator.pop(context);
      },
      itemBuilder: (_) => [
        for (final action in actions)
          PopupMenuItem(
            value: action,
            child: Text(switch (action) {
              ContentsDownloadAction.downloadAll => t.tocDownloadAll,
              ContentsDownloadAction.cancel => t.tocCancelDownloads,
              ContentsDownloadAction.retryFailed => t.tocRetryFailed,
              ContentsDownloadAction.shareAudio => t.tocShareAudio,
            }),
          ),
      ],
    );
  }

  Future<void> _confirmRemoveAudio(String bookId) async {
    final t = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(t.tocRemoveDownloads),
        content: Text(t.tocRemoveDownloadsMessage),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(t.cancel)),
          TextButton(onPressed: () => Navigator.pop(dialog, true), child: Text(t.remove)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref
        .read(bookDerivedDataRemoverProvider)
        .removeAudio(bookId, player: ref.read(globalAudioPlayerProvider));
    if (mounted) Navigator.pop(context);
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
        startAtChapter: _currentChapterIndex,
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
