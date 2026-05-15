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

  @override
  String get pickBookToRead => 'Pick a book to read';

  @override
  String get browseLibrary => 'Browse Library';

  @override
  String get parsingBook => 'Opening book…';

  @override
  String get parsingFailed => 'Could not open this book';

  @override
  String get retry => 'Retry';

  @override
  String get generatingAudio => 'Generating audio';

  @override
  String get nowPlaying => 'Now Playing';

  @override
  String get audioEngineSection => 'Audio engine';

  @override
  String get useBuiltInEngine => 'Use built-in audio engine';

  @override
  String get useBuiltInEngineDesc =>
      'Synthesises chapters on this device. No backend needed.';

  @override
  String get audioEngineFooter =>
      'Reading works offline either way — this only affects audio generation.';

  @override
  String get remoteBackendSection => 'Remote backend';

  @override
  String get backendUrlHint => 'http://localhost:8000';

  @override
  String get backendUrlFooter =>
      'Point to a local server or Hugging Face Space URL.';

  @override
  String get fontLabel => 'Font';

  @override
  String get layoutLabel => 'Layout';

  @override
  String get lineSpacingLabel => 'Line spacing';

  @override
  String get marginLabel => 'Margin';

  @override
  String get autoScrollLabel => 'Auto-scroll';

  @override
  String get autoScrollDesc => 'Scroll text to follow audio playback';

  @override
  String get playbackSection => 'Playback';

  @override
  String get aboutSection => 'About';

  @override
  String get platformLabel => 'Platform';

  @override
  String get projectOnGithub => 'Project on GitHub';

  @override
  String get readerPrefsFooter =>
      'These preferences apply to every book in your library.';

  @override
  String get invalidUrl => 'URL is not valid';

  @override
  String nOfSteps(int n, int total) {
    return '$n of $total';
  }

  @override
  String get sortBy => 'Sort by';

  @override
  String get sortLastOpened => 'Last opened';

  @override
  String get sortTitle => 'Title';

  @override
  String get sortDateAdded => 'Date added';

  @override
  String get libraryEmptyDesc =>
      'Tap + to import an EPUB or PDF, or share one from another app.';

  @override
  String get offlineReady => 'Offline';

  @override
  String get cachingLabel => 'Caching';

  @override
  String get removeFromLibrary => 'Remove from library';
}
