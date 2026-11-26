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
  String get wpmLabel => 'Words per minute';

  @override
  String get audioRateLabel => 'Audio playback rate';

  @override
  String get readingPreferencesTitle => 'Reading preferences';

  @override
  String get readingModeDefault => 'Default for all books';

  @override
  String get readingModeBook => 'Only this book';

  @override
  String get readingUseDefault => 'Use the default';

  @override
  String get readingSpeedLabel => 'Narration speed';

  @override
  String get readingDefaultHint =>
      'Changes apply to every book without settings of its own.';

  @override
  String get readingBookHint =>
      'Changes apply only to this book. Choose Use the default to go back to the default.';

  @override
  String get readerLayoutScrolling => 'Scrolling';

  @override
  String get readerLayoutPaginated => 'Paginated';

  @override
  String get readerThemeAuto => 'Auto';

  @override
  String get readerThemeLight => 'Light';

  @override
  String get readerThemeSepia => 'Sepia';

  @override
  String get readerThemeParchment => 'Parchment';

  @override
  String get readerThemePaper => 'Paper';

  @override
  String get readerThemeDark => 'Dark';

  @override
  String get readerThemeBlack => 'Black';

  @override
  String get readerThemeCustom => 'Custom';

  @override
  String get readerFontSerif => 'Serif';

  @override
  String get readerFontSans => 'Sans';

  @override
  String get readerFontMono => 'Mono';

  @override
  String get fontSizeLabel => 'Reader font size';

  @override
  String get themeLabel => 'Theme';

  @override
  String get jobsTitle => 'Jobs';

  @override
  String get noJobs => 'No conversions yet';

  @override
  String get conversionLogTitle => 'Conversion log';

  @override
  String get conversionJobLabel => 'Job';

  @override
  String get conversionLastRecordedState => 'Last recorded state';

  @override
  String conversionLastRecordedStateValue(String state) {
    return 'Last recorded state: $state';
  }

  @override
  String get conversionLastUpdated => 'Last updated';

  @override
  String conversionRecordedAudioPath(String path) {
    return 'Recorded audio path: $path';
  }

  @override
  String conversionUnreadableRecords(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count saved conversion records could not be read.',
      one: '1 saved conversion record could not be read.',
    );
    return '$_temp0';
  }

  @override
  String get conversionStatusPending => 'Pending';

  @override
  String get conversionStatusRunning => 'Converting';

  @override
  String get conversionStatusCompleted => 'Completed';

  @override
  String get conversionStatusFailed => 'Failed';

  @override
  String get conversionStatusCancelled => 'Cancelled';

  @override
  String get conversionStatusUnknown => 'Unknown';

  @override
  String conversionHistorySaveWarning(String error) {
    return 'Conversion completed, but its history could not be saved: $error';
  }

  @override
  String get refresh => 'Refresh';

  @override
  String get readerTitle => 'Reader';

  @override
  String get tocTitle => 'Chapters';

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
  String get importBookFile => 'Import an EPUB or PDF file';

  @override
  String get searchPublicBooks => 'Search classic books';

  @override
  String get publicBookDownloadFailed =>
      'Could not download or import this book. Try again.';

  @override
  String get publicBookSourceOpenFailed =>
      'Could not open the publisher’s page.';

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
  String get audioEngineSection => 'Audio engine';

  @override
  String get useBuiltInEngineDesc =>
      'Synthesises chapters on this device. No backend needed.';

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
  String get readerPageTurnStyle => 'Page turn';

  @override
  String get pageTurnFlip => 'Flip';

  @override
  String get pageTurnSlide => 'Slide';

  @override
  String get pageTurnNone => 'Normal';

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
  String get readerPrefsFooter =>
      'These preferences apply to every book in your library.';

  @override
  String nOfSteps(int n, int total) {
    return '$n of $total';
  }

  @override
  String get sortLastPlayed => 'Recently played';

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
  String get conversionFailed => 'Conversion failed';

  @override
  String get bookLanguageUncertain =>
      'The book\'s language could not be detected. Choose its language in Convert and try again.';

  @override
  String get downloading => 'Downloading…';

  @override
  String get downloadComplete => 'Download complete';

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
  String get searchInBook => 'Search in book';

  @override
  String get noResults => 'No results';

  @override
  String get done => 'Done';

  @override
  String get searchResultsCapped => 'Showing first 100 results';

  @override
  String get libraryColumns => 'Columns';

  @override
  String get bookLanguageTitle => 'Book language';

  @override
  String get bookLanguageAutomatic => 'Automatic detection';

  @override
  String get bookLanguageHelp =>
      'This choice applies to this book or passage. Choose Automatic detection to remove your correction.';

  @override
  String get bookLanguageInconclusive =>
      'The language could not be identified after analyzing additional passages. Choose the language for this book or passage.';

  @override
  String get bookLanguageMenu => 'Book language';

  @override
  String get bookLanguageAnalyzing => 'Analyzing the book…';

  @override
  String bookLanguageSummaryMain(String language, int percent) {
    return '$language $percent%';
  }

  @override
  String bookLanguageSummaryMainOnly(String language) {
    return '$language';
  }

  @override
  String bookLanguageSummaryWritten(String languages) {
    return 'Also written in $languages';
  }

  @override
  String bookLanguageSummaryQuoted(String languages) {
    return 'Quotes in $languages';
  }

  @override
  String bookLanguageConflict(String declared, String detected) {
    return 'The file says $declared; the text is $detected.';
  }

  @override
  String get bookLanguageDetectedSection => 'In this book';

  @override
  String get sortLibrary => 'Sort library';

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
  String get off => 'Off';

  @override
  String get ttsPrimaryNarration => 'Voice engine';

  @override
  String get ttsSecondaryNarration => 'Secondary voice';

  @override
  String get ttsFaberOffline => 'Faber medium · Offline';

  @override
  String get ttsAutomaticPiper => 'Piper · Book language';

  @override
  String get ttsDetectLanguage => 'Detect from book';

  @override
  String get ttsEdgeOnline => 'Edge · Online';

  @override
  String get ttsNoSecondary => 'None';

  @override
  String get ttsSystemOffline => 'System voice · Offline fallback';

  @override
  String get ttsUseRecommendedDefaults =>
      'Use book-language Piper with system voice fallback';

  @override
  String get ttsAllowOnlineSecondary => 'Allow online fallback';

  @override
  String get ttsOnlineSecondaryDescription =>
      'Send failed segments to Edge only when enabled.';

  @override
  String get ttsAutomaticSystemFallback => 'Automatic system voice fallback';

  @override
  String get ttsAutomaticSystemFallbackDescription =>
      'If selected voices fail, try an installed system voice. Turn off to use only your selected voices.';

  @override
  String get ttsFootnoteNarration => 'Read footnotes in the text';

  @override
  String get ttsFootnoteNarrationDescription =>
      'Each note is read where it is referenced, between \"Footnote N\" markers. Turn off to skip the notes.';

  @override
  String get ttsEngineSystem => 'System voice';

  @override
  String get ttsEnginePiper => 'Piper';

  @override
  String get ttsEngineEdge => 'Edge (online)';

  @override
  String get ttsVoiceBookLanguage => 'Book language';

  @override
  String get ttsVoiceSystem => 'Installed system voice';

  @override
  String get ttsVoiceEdge => 'Online speech';

  @override
  String get ttsUsePreferences => 'Use audio preferences';

  @override
  String get ttsAllowJobSecondary =>
      'Allow configured secondary for this conversion';

  @override
  String ttsActualVoices(String voices) {
    return 'Used voice: $voices';
  }

  @override
  String get ttsSecondaryUsedNotice =>
      'Using the secondary voice. The primary voice will be retried periodically.';

  @override
  String get platformVoiceNotice => 'Using the system voice for this segment.';

  @override
  String get localAudioStorage => 'Local audio downloads';

  @override
  String get localAudioStorageHint =>
      'Downloaded and listened audio is kept until you remove it.';

  @override
  String get removeAudioTitle => 'Remove downloaded audio?';

  @override
  String get removeAudioMessage =>
      'The book, reading position and annotations will be kept.';

  @override
  String get originalTypography => 'Original book typography';

  @override
  String get seekForwardInterval => 'Skip forward';

  @override
  String get seekBackwardInterval => 'Skip backward';

  @override
  String get remoteButtonModeTitle => 'Next and previous buttons';

  @override
  String get remoteButtonModeDescription =>
      'What the buttons of your car, headphones and lock screen do.';

  @override
  String get remoteButtonModeChapter => 'Chapter';

  @override
  String get remoteButtonModeSeconds => 'Skip seconds';

  @override
  String fallbackChapterName(int number) {
    return 'Chapter $number';
  }

  @override
  String get ttsShowLowQuality => 'Show low-quality models';

  @override
  String get ttsManualModelUnavailable =>
      'Could not prepare this narration model.';

  @override
  String get readerBookVoiceTitle => 'Voice for this book';

  @override
  String get readerNarrationModel => 'Narration model';

  @override
  String get readerFootnotes => 'Footnotes';

  @override
  String get openReaderAtPlayback => 'Open in reader';

  @override
  String get goToNarratedPage => 'Go to reading';

  @override
  String get readerAppearance => 'Text appearance';

  @override
  String get readerPlayFromHere => 'Play from here';

  @override
  String get errorPdfOcrRequired =>
      'This PDF has a page with only an image and no selectable text (often the cover). It cannot be narrated until that text is recognized (OCR).';

  @override
  String get errorNoReadableText =>
      'No readable text could be extracted from this book.';

  @override
  String get errorEngineUnavailable =>
      'The speech converter is unavailable. Please reinstall the app or try again.';

  @override
  String get errorModelMissing =>
      'The selected narration model is not installed. Install it in Settings.';

  @override
  String get errorNoOfflineVoice =>
      'No offline voice for this book\'s language is installed on this device. Install a voice model in Settings, or add an offline system voice.';

  @override
  String get errorModelLanguage =>
      'This model does not support the language of this book. Choose a compatible model.';

  @override
  String get errorUnsupportedEngine =>
      'The selected speech engine is not supported.';

  @override
  String get errorSpeechTimeout =>
      'The voice took too long to respond. Please try again.';

  @override
  String get errorNetwork =>
      'Could not connect. Check your connection and try again.';

  @override
  String get errorRateLimited =>
      'The voice service is busy. Please try again in a moment.';

  @override
  String get errorInputUnreadable =>
      'This book could not be read. The file may be damaged.';

  @override
  String get errorUnsupportedInput => 'This kind of file is not supported.';

  @override
  String get errorConversionGeneric =>
      'The book could not be converted to audio. Please try again. Technical details are available in the logs.';

  @override
  String get errorEdgeConsentRequired =>
      'Online Edge voices need your permission. Turn on “Allow online fallback” in Settings, or choose a local voice, and try again.';

  @override
  String get modelsTitle => 'Models';

  @override
  String get modelsSubtitle => 'Choose the narration for each book language';

  @override
  String get modelsLanguagesTitle => 'Languages';

  @override
  String get modelsSystemLanguages => 'System languages';

  @override
  String get modelsPopularLanguages => 'Most popular';

  @override
  String get modelsOtherLanguages => 'All languages';

  @override
  String get modelsSystemSection => 'System';

  @override
  String get modelsSystemVoice => 'System voice';

  @override
  String get modelsPiperSection => 'Piper (on this device)';

  @override
  String get modelsEdgeSection => 'Edge (online)';

  @override
  String get modelsVoiceForEachLanguage => 'Voice for each language';

  @override
  String get modelsAllLanguages => 'All languages';

  @override
  String get modelsNeedsVoice =>
      'A book in your library needs a voice for this language';

  @override
  String modelsSizeMb(int size) {
    return '$size MB';
  }

  @override
  String get modelsFallbackSection => 'Fallback voices';

  @override
  String get modelsLowQualitySection => 'Piper · low quality';

  @override
  String get modelsAutomatic => 'Automatic';

  @override
  String get modelsAutomaticDesc =>
      'Uses the best installed model for the book';

  @override
  String get modelsLocalSection => 'On this device';

  @override
  String get modelsOnlineSection => 'Online';

  @override
  String get modelsOnlineNeedsConsent =>
      'Turn on “Allow online fallback” in Settings to use online voices';

  @override
  String get modelsNotInstalled => 'Tap to download and use';

  @override
  String get modelsEmpty => 'No models are available for this device';

  @override
  String get modelsLoadFailed => 'The model list could not be loaded';

  @override
  String modelsRowSubtitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count models',
      one: '1 model',
    );
    return '$_temp0';
  }

  @override
  String modelsMissingTitle(String language) {
    return 'No narration model for $language';
  }

  @override
  String get modelsMissingBody =>
      'Install a narration model for this language, then try again.';

  @override
  String get modelsMissingAction => 'Open Models';

  @override
  String bookLanguagesMissingModels(String languages) {
    return 'This book also has passages in $languages. No voice is installed for them, so they are read with the main voice.';
  }

  @override
  String get convertChooseFile => 'Choose EPUB or PDF';

  @override
  String get convertEngine => 'Engine';

  @override
  String get convertVoice => 'Voice';

  @override
  String get convertLanguage => 'Language';

  @override
  String get convertLanguagePortuguese => 'Portuguese';

  @override
  String get convertLanguageEnglish => 'English';

  @override
  String get convertLanguageSpanish => 'Spanish';

  @override
  String get convertChapterRange => 'Chapter range';

  @override
  String get convertChapterFrom => 'From';

  @override
  String get convertChapterTo => 'To';

  @override
  String get convertOptions => 'Options';

  @override
  String get convertOptionsManagedLocally =>
      'Cover and audio processing options are managed by the local converter.';

  @override
  String get convertIncludeCover => 'Include cover';

  @override
  String get convertNormalizeAudio => 'Normalize audio';

  @override
  String get convertStart => 'Start conversion';

  @override
  String get tocDownloadAll => 'Download for offline';

  @override
  String get tocCancelDownloads => 'Cancel downloads';

  @override
  String get tocRetryFailed => 'Retry failed chapters';

  @override
  String get tocShareAudio => 'Share available audio';

  @override
  String get tocRemoveDownloads => 'Remove downloads';

  @override
  String get tocRemoveDownloadsMessage =>
      'All downloaded MP3s of this book will be deleted.';

  @override
  String get tocAudioReady => 'Audio ready';

  @override
  String get tocAudioConverting => 'Converting audio';

  @override
  String get tocAudioFailed => 'Audio failed';

  @override
  String get readerHighlight => 'Highlight';

  @override
  String get readerAddNote => 'Add Note';

  @override
  String get readerRemoveHighlight => 'Remove highlight';

  @override
  String get readerPassageLanguage => 'Passage language';
}
