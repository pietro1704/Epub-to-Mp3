part of 'book_open_screen.dart';

mixin BookContentSession on ConsumerState<BookOpenScreen> {
  _Phase _phase = _Phase.resolving;
  EbookFulltext? _fulltext;
  String? _errorMessage;
  final AsyncLoadGuard _loadGuard = AsyncLoadGuard();
  String? _readerJourneyId;

  Future<void> _load() async {
    // didUpdateWidget can fire a new _load while a previous one is
    // still awaiting cache.read / embedded Rust parsing. Tag each load
    // with a generation token so the stale continuation skips its
    // setState and does not flash the previous book's content onto
    // the newly-mounted bookId.
    final gen = _loadGuard.start();
    _readerJourneyId = latencyObservations.begin(
      LatencyJourneyKind.readerOpen,
      LatencyTransition.interactionRequested,
    );
    final loadingForBookId = widget.bookId;
    setState(() {
      _phase = _Phase.resolving;
      _fulltext = null;
      _errorMessage = null;
    });

    final cache = ref.read(localFulltextCacheProvider);

    // 1) Try cached fulltext.
    final cached = await cache.read(loadingForBookId);
    if (!mounted || !_loadGuard.isCurrent(gen)) return;
    if (cached != null) {
      setState(() {
        _fulltext = cached;
        _phase = _Phase.ready;
      });
      _markBookOpened();
      _completeReaderJourney();
      return;
    }

    // 2) Parse through the selected local runtime; no native EPUB is uploaded.
    if (Platform.isAndroid) {
      try {
        final library = ref.read(libraryStoreProvider);
        final book = library.books
            .where((b) => b.id == loadingForBookId)
            .firstOrNull;
        if (book == null) throw StateError('Book is no longer in the library');
        final path = await library.ensureSupportedBookPath(book);
        final fulltext = await ref
            .read(embeddedConverterProvider)
            .parse(inputPath: path, jobId: loadingForBookId);
        if (!mounted || !_loadGuard.isCurrent(gen)) return;
        await cache.save(fulltext, loadingForBookId);
        if (!mounted || !_loadGuard.isCurrent(gen)) return;
        setState(() {
          _fulltext = fulltext;
          _phase = _Phase.ready;
        });
        _markBookOpened();
        _completeReaderJourney();
      } catch (error) {
        if (!mounted || !_loadGuard.isCurrent(gen)) return;
        setState(() {
          _errorMessage = error.toString();
          _phase = _Phase.error;
        });
        _cancelReaderJourney();
      }
      return;
    }

    try {
      final library = ref.read(libraryStoreProvider);
      // Null-safe lookup: the user can remove the book from the library
      // (or the library can fail to load it) between BookOpenScreen
      // mounting and this async path running. firstWhere without
      // orElse would throw StateError and crash the parse flow.
      final book = library.books
          .where((b) => b.id == loadingForBookId)
          .firstOrNull;
      if (book == null) {
        if (!mounted || !_loadGuard.isCurrent(gen)) return;
        setState(() {
          _errorMessage = 'Book is no longer in the library';
          _phase = _Phase.error;
        });
        _cancelReaderJourney();
        return;
      }
      final filePath = await library.ensureSupportedBookPath(book);
      final fulltext = await ref
          .read(embeddedConverterProvider)
          .parse(inputPath: filePath, jobId: loadingForBookId);
      if (!mounted || !_loadGuard.isCurrent(gen)) return;
      await cache.save(fulltext, loadingForBookId);
      if (!mounted || !_loadGuard.isCurrent(gen)) return;
      setState(() {
        _fulltext = fulltext;
        _phase = _Phase.ready;
      });
      _markBookOpened();
      _completeReaderJourney();
    } catch (e) {
      if (!mounted || !_loadGuard.isCurrent(gen)) return;
      setState(() {
        _errorMessage = e.toString();
        _phase = _Phase.error;
      });
      _cancelReaderJourney();
    }
  }

  void _completeReaderJourney() {
    final id = _readerJourneyId;
    if (id == null) return;
    latencyObservations.record(id, LatencyTransition.readerUsable);
    latencyObservations.finish(id);
    _readerJourneyId = null;
  }

  void _cancelReaderJourney() {
    final id = _readerJourneyId;
    if (id == null) return;
    latencyObservations.cancel(id);
    _readerJourneyId = null;
  }

  void _markBookOpened() {
    final library = ref.read(libraryStoreProvider);
    final idx = library.books.indexWhere((b) => b.id == widget.bookId);
    if (idx >= 0) {
      final book = library.books[idx];
      book.lastOpenedAt = DateTime.now();
      library.update(book);
    }
  }

}
