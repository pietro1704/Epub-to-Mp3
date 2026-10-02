/// Language and segmentation policy for platform speech fallbacks.
class SpeechTextPolicy {
  static const defaultChunkChars = 1200;

  static String detectLocale(Iterable<String> texts) {
    final sample = texts
        .map((text) => text.toLowerCase())
        .join(' ')
        .replaceAll(RegExp(r'[^a-záàâãéêíóôõúçüñ\s]'), ' ');
    final words = RegExp(r'\b[\p{L}]+\b', unicode: true)
        .allMatches(sample)
        .map((match) => match.group(0)!)
        .toSet();
    const english = {
      'the', 'and', 'of', 'to', 'in', 'was', 'that', 'with', 'from',
      'this', 'his', 'her', 'they', 'were', 'their', 'not', 'for',
    };
    const portuguese = {
      'o', 'a', 'os', 'as', 'e', 'de', 'do', 'da', 'que', 'não',
      'uma', 'um', 'com', 'para', 'foi', 'seu', 'sua', 'dos', 'das',
    };
    const spanish = {
      'el', 'la', 'los', 'las', 'y', 'de', 'que', 'una', 'con', 'para',
    };
    const french = {
      'le', 'la', 'les', 'et', 'de', 'des', 'que', 'une', 'avec', 'pour',
    };
    final scores = <String, int>{
      'en-US': words.intersection(english).length,
      'pt-BR': words.intersection(portuguese).length,
      'es-ES': words.intersection(spanish).length,
      'fr-FR': words.intersection(french).length,
    };
    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ranked.first.value > 0 ? ranked.first.key : 'en-US';
  }

  static List<String> splitForAndroidTts(
    String input, {
    int maxChars = defaultChunkChars,
  }) {
    var remaining = input.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (remaining.isEmpty) return const [];
    final chunks = <String>[];
    while (remaining.length > maxChars) {
      var cut = remaining.lastIndexOf(RegExp(r'[.!?;:]'), maxChars);
      if (cut < (maxChars * 0.55).round()) {
        cut = remaining.lastIndexOf(' ', maxChars);
      }
      if (cut <= 0) cut = maxChars;
      final includesDelimiter = remaining[cut] != ' ';
      final end = cut + (includesDelimiter ? 1 : 0);
      final chunk = remaining.substring(0, end).trim();
      if (chunk.isNotEmpty) chunks.add(chunk);
      remaining = remaining.substring(end).trimLeft();
    }
    if (remaining.isNotEmpty) chunks.add(remaining);
    return chunks;
  }
}
