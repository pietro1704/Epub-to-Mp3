/// Exact Unicode scalar position in one normalized source chapter.
class ReaderListeningPosition {
  const ReaderListeningPosition(this.chapterIndex, this.textOffset);
  final int chapterIndex;
  final int textOffset;

  /// SentenceSpan coordinates count scalars after collapseHardWraps. Retain a
  /// positional map, so repeated text never requires substring matching.
  factory ReaderListeningPosition.fromDisplayScalar(int chapter, String source, int offset) {
    final raw = source.runes.toList();
    final positions = <int>[];
    for (var index = 0; index < raw.length; index++) {
      if (raw[index] == 0x0D && index + 1 < raw.length && raw[index + 1] == 0x0A) continue;
      positions.add(index);
      if (raw[index] == 0xFFFE) positions.add(index);
    }
    if (chapter < 0 || offset < 0 || offset >= positions.length) {
      throw const FormatException('Displayed anchor is outside source text');
    }
    return ReaderListeningPosition(chapter, positions[offset]);
  }

  factory ReaderListeningPosition.fromUtf16(int chapter, String source, int offset) {
    if (chapter < 0 || offset < 0 || offset >= source.length ||
        (offset > 0 && source.codeUnitAt(offset) >= 0xDC00 && source.codeUnitAt(offset) <= 0xDFFF)) {
      throw const FormatException('Reader position must identify a complete source character');
    }
    return ReaderListeningPosition(chapter, source.substring(0, offset).runes.length);
  }
}
