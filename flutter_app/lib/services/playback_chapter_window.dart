/// Chapter range kept eligible for on-demand playback conversion.
class PlaybackChapterWindow {
  const PlaybackChapterWindow({this.chaptersAhead = 1});

  final int chaptersAhead;

  bool contains(int currentChapter, int candidateChapter) =>
      candidateChapter >= currentChapter &&
      candidateChapter <= currentChapter + chaptersAhead;
}
