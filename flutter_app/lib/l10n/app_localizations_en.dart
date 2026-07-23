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
  String get convertTitle => 'Convert';

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
  String get libraryEmpty => 'Your library is empty';

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
  String get readerShowPageNumbers => 'Show page numbers';

  @override
  String get readerAlignmentLabel => 'Alignment';

  @override
  String get readerAlignmentJustified => 'Justified';

  @override
  String get readerAlignmentLeft => 'Left';

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

  @override
  String get startingConversion => 'Starting conversion…';

  @override
  String get conversionFailed => 'Conversion failed';

  @override
  String get uploadFailed => 'Upload failed';

  @override
  String get downloading => 'Downloading…';

  @override
  String get downloadComplete => 'Download complete';

  @override
  String get downloadFailed => 'Download failed';

  @override
  String chaptersConverted(int n, int total) {
    return '$n of $total chapters';
  }

  @override
  String get drmFootnote =>
      'DRM-protected books (e.g. from Google Play or Kindle) cannot be opened.';

  @override
  String get saveForOffline => 'Save';

  @override
  String charsCount(int n) {
    return '$n chars';
  }

  @override
  String get searchInBook => 'Search in book';

  @override
  String get noResults => 'No results';

  @override
  String get done => 'Done';

  @override
  String get searchResultsCapped => 'Showing first 100 results';

  @override
  String get sortLibrary => 'Sort library';

  @override
  String get skipBack15 => 'Skip back 15 seconds';

  @override
  String get skipForward15 => 'Skip forward 15 seconds';

  @override
  String get playbackPosition => 'Playback position';

  @override
  String get playbackSpeed => 'Playback speed';

  @override
  String get sleepTimer => 'Sleep timer';

  @override
  String get albumArt => 'Album art';

  @override
  String get closePlayer => 'Close player';

  @override
  String get tableOfContents => 'Table of contents';

  @override
  String get readerSettings => 'Reader settings';

  @override
  String get audioReady => 'Audio ready';

  @override
  String get currentlyPlaying => 'Currently playing';

  @override
  String get editTags => 'Edit Tags';

  @override
  String get tagsSection => 'Tags';

  @override
  String get newTagHint => 'New tag';

  @override
  String get add => 'Add';

  @override
  String get existingTags => 'Existing tags';

  @override
  String get allFilter => 'All';

  @override
  String get searchLibrary => 'Search library';

  @override
  String get bookmarksTitle => 'Bookmarks';

  @override
  String get filterAll => 'All';

  @override
  String get filterBookmarks => 'Bookmarks';

  @override
  String get filterHighlights => 'Highlights';

  @override
  String get noBookmarksYet => 'No bookmarks yet';

  @override
  String get noBookmarksHint =>
      'Long-press a paragraph in the reader to add a bookmark or highlight.';

  @override
  String get editNote => 'Edit Note';

  @override
  String get addNoteHint => 'Add a note…';

  @override
  String get highlightedText => 'Highlighted text';

  @override
  String get colorLabel => 'Color';

  @override
  String get save => 'Save';

  @override
  String get removeBookmarkTitle => 'Remove bookmark';

  @override
  String get removeBookmarkMessage => 'Remove this bookmark?';

  @override
  String get addBookmark => 'Add bookmark';

  @override
  String get bookmarkAdded => 'Bookmark added';

  @override
  String get bookmarkRemoved => 'Bookmark removed';

  @override
  String get sizeLabel => 'Size';

  @override
  String get noContentAvailable => 'No content available';

  @override
  String errorWithMessage(String message) {
    return 'Error: $message';
  }

  @override
  String get platformAndroid => 'Android';

  @override
  String get chapterListTitle => 'Chapters';

  @override
  String get sleepTimerActive => 'Sleep timer active';

  @override
  String get sleepTimerOff => 'Sleep timer off';

  @override
  String get speedLabel => 'Speed';

  @override
  String sleepMinutes(int n) {
    return '$n min';
  }

  @override
  String get off => 'Off';
}
