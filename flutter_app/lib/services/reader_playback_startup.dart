/// Explicit Listen intent waits for its requested chapter, even if other cached
/// chapters already occupy the queue. A generation owns exactly one startup.
class ReaderPlaybackStartup {
  int? _generation;
  int? _chapter;
  bool _started = false;

  void request(int generation, int chapter) {
    _generation = generation;
    _chapter = chapter;
    _started = false;
  }

  void invalidate() {
    _generation = null;
    _chapter = null;
  }

  bool accepts(int generation) => _generation == generation;

  Future<void> startWhenReady(
    int generation,
    List<int> readyChapters,
    Future<void> Function(int queueIndex) start,
  ) async {
    if (!accepts(generation) || _started) return;
    final index = readyChapters.indexOf(_chapter!);
    if (index < 0) return;
    _started = true;
    await start(index);
  }
}
