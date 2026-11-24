import 'language_model_resolution.dart';

/// What the book's language sheet says about the text: the main language with its share, the
/// languages it is also written in, and the languages it only quotes ("Portuguese 98%, also
/// written in French, quoting Latin"). Derived from Rust's analysis; nothing is decided here.
class BookLanguageSummary {
  const BookLanguageSummary({
    required this.main,
    this.mainPercent,
    this.alsoWritten = const [],
    this.alsoQuoted = const [],
  });

  /// The main language tag; null when nothing was detected.
  final String? main;

  /// The main language's share of the text, in whole percent; null without a profile.
  final int? mainPercent;
  final List<String> alsoWritten;
  final List<String> alsoQuoted;

  factory BookLanguageSummary.from(BookLanguageAnalysis analysis) {
    final profile = analysis.profile;
    if (profile == null) {
      return BookLanguageSummary(main: analysis.confirmed);
    }
    final main = profile.primary ?? analysis.confirmed;
    final mainShare = profile.languages
        .where((share) => share.language == main)
        .firstOrNull;
    return BookLanguageSummary(
      main: main,
      mainPercent: mainShare == null ? null : (mainShare.fraction * 100).round(),
      alsoWritten: [
        for (final share in profile.languages)
          if (share.language != main &&
              (share.role == BookLanguageRole.significant ||
                  share.role == BookLanguageRole.section))
            share.language,
      ],
      alsoQuoted: [
        for (final share in profile.languages)
          if (share.language != main && share.role == BookLanguageRole.incidental)
            share.language,
      ],
    );
  }
}
