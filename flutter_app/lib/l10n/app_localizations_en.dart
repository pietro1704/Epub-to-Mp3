// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Epub to MP3';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get backendUrl => 'Backend URL';

  @override
  String get wpmLabel => 'Words per minute';

  @override
  String get audioRateLabel => 'Audio playback rate';

  @override
  String get fontSizeLabel => 'Reader font size';

  @override
  String get themeLabel => 'Theme';

  @override
  String get jobsTitle => 'Jobs';

  @override
  String get noJobs => 'No conversions yet';

  @override
  String get refresh => 'Refresh';

  @override
  String get playerTitle => 'Player';

  @override
  String get readerTitle => 'Reader';

  @override
  String get tocTitle => 'Chapters';

  @override
  String get loadingFulltext => 'Loading text…';

  @override
  String get fulltextEmpty => 'No readable text available';

  @override
  String get fulltextGone => 'Text no longer available';

  @override
  String get downloadAll => 'Download all';

  @override
  String get play => 'Play';

  @override
  String get pause => 'Pause';

  @override
  String get next => 'Next';

  @override
  String get previous => 'Previous';

  @override
  String get libraryTitle => 'Library';

  @override
  String get libraryEmpty => 'No books yet';

  @override
  String get addBook => 'Add a book';

  @override
  String get removeBookTitle => 'Remove book';

  @override
  String removeBookMessage(String title) {
    return 'Remove \"$title\" from your library? The file will not be deleted.';
  }

  @override
  String get cancel => 'Cancel';

  @override
  String get remove => 'Remove';

  @override
  String get noConversionYet => 'Convert this book first to play audio';

  @override
  String get readerEmptyHint => 'Open a book from the library to start reading';
}
