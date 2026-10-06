/// Monotonic generation counter for async loads on a `StatefulWidget`
/// whose key (here: `widget.bookId`) can change while a previous
/// load is still awaiting an async result.
///
/// Pre-slice-36 `book_open_screen._load` had this exact race:
///   1. Open Book X. `_load()` starts the slow `bridge.parseEpub`.
///   2. User navigates to Book Y. `didUpdateWidget` fires
///      `_load()` for Y; the cache hit fast-paths to
///      `_fulltext = Y`.
///   3. The X parse finally completes and `setState(_fulltext = X)`
///      lands AFTER Y was shown — the user sees X content on the
///      Y screen.
///
/// Wrap each async load with `final gen = guard.start();` at the
/// top, then after every `await` check `if (!guard.isCurrent(gen))
/// return;` before touching `setState`. A newer `start()` from
/// `didUpdateWidget` invalidates the old generation.
class AsyncLoadGuard {
  int _generation = 0;

  int start() {
    _generation += 1;
    return _generation;
  }

  bool isCurrent(int generation) => generation == _generation;
}
