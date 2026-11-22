/// Marker the shared Rust converter embeds when it cannot determine the book language.
const bookLanguageUncertainMarker = 'book_language_uncertain_v1';

/// Whether [error] reports the inconclusive book language failure.
///
/// The Rust message carries a large JSON evidence block between the markers, which
/// is not meant for display; callers show a localized, actionable message instead.
bool isBookLanguageUncertain(Object error) =>
    error.toString().contains('[[$bookLanguageUncertainMarker]]');
