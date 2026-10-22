class ChapterAdvanceModel {
  int currentChapterIndex;
  final int chapterCount;

  ChapterAdvanceModel({
    required this.currentChapterIndex,
    required this.chapterCount,
  });

  bool advance() {
    if (currentChapterIndex + 1 >= chapterCount) return false;
    currentChapterIndex += 1;
    return true;
  }

  bool retreat() {
    if (currentChapterIndex <= 0) return false;
    currentChapterIndex -= 1;
    return true;
  }
}
