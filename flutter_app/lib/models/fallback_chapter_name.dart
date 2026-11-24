import '../l10n/app_localizations.dart';

/// The name of a chapter that has no title, in the app language ("Capítulo 3"). Rust names such a
/// chapter "Chapter N" and the Dart fallbacks did the same, so a Portuguese or Spanish reader saw
/// English. The app binds the language once ([use], from the MaterialApp); models stay context-free.
class FallbackChapterName {
  FallbackChapterName._();

  static String Function(int number) _format = (number) => 'Chapter $number';
  static final _generated = RegExp(r'^Chapter (\d+)$');

  static void use(AppLocalizations t) => _format = t.fallbackChapterName;

  static String of(int number) => _format(number);

  /// The localized name when [name] is exactly the label Rust generates ("Chapter 7"); null for a
  /// real title (including "Chapter 1: The Beginning").
  static String? localizedGenerated(String name) {
    final match = _generated.firstMatch(name.trim());
    return match == null ? null : _format(int.parse(match.group(1)!));
  }
}
