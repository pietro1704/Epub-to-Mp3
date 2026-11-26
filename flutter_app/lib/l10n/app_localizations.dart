import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
    Locale('pt'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Epub to MP3'**
  String get appTitle;

  /// No description provided for @convertTitle.
  ///
  /// In en, this message translates to:
  /// **'Convert'**
  String get convertTitle;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @wpmLabel.
  ///
  /// In en, this message translates to:
  /// **'Words per minute'**
  String get wpmLabel;

  /// No description provided for @audioRateLabel.
  ///
  /// In en, this message translates to:
  /// **'Audio playback rate'**
  String get audioRateLabel;

  /// No description provided for @readingPreferencesTitle.
  ///
  /// In en, this message translates to:
  /// **'Reading preferences'**
  String get readingPreferencesTitle;

  /// No description provided for @readingModeDefault.
  ///
  /// In en, this message translates to:
  /// **'Default for all books'**
  String get readingModeDefault;

  /// No description provided for @readingModeBook.
  ///
  /// In en, this message translates to:
  /// **'Only this book'**
  String get readingModeBook;

  /// No description provided for @readingUseDefault.
  ///
  /// In en, this message translates to:
  /// **'Use the default'**
  String get readingUseDefault;

  /// No description provided for @readingSpeedLabel.
  ///
  /// In en, this message translates to:
  /// **'Narration speed'**
  String get readingSpeedLabel;

  /// No description provided for @readingDefaultHint.
  ///
  /// In en, this message translates to:
  /// **'Changes apply to every book without settings of its own.'**
  String get readingDefaultHint;

  /// No description provided for @readingBookHint.
  ///
  /// In en, this message translates to:
  /// **'Changes apply only to this book. Choose Use the default to go back to the default.'**
  String get readingBookHint;

  /// No description provided for @readerLayoutScrolling.
  ///
  /// In en, this message translates to:
  /// **'Scrolling'**
  String get readerLayoutScrolling;

  /// No description provided for @readerLayoutPaginated.
  ///
  /// In en, this message translates to:
  /// **'Paginated'**
  String get readerLayoutPaginated;

  /// No description provided for @readerThemeAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get readerThemeAuto;

  /// No description provided for @readerThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get readerThemeLight;

  /// No description provided for @readerThemeSepia.
  ///
  /// In en, this message translates to:
  /// **'Sepia'**
  String get readerThemeSepia;

  /// No description provided for @readerThemeParchment.
  ///
  /// In en, this message translates to:
  /// **'Parchment'**
  String get readerThemeParchment;

  /// No description provided for @readerThemePaper.
  ///
  /// In en, this message translates to:
  /// **'Paper'**
  String get readerThemePaper;

  /// No description provided for @readerThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get readerThemeDark;

  /// No description provided for @readerThemeBlack.
  ///
  /// In en, this message translates to:
  /// **'Black'**
  String get readerThemeBlack;

  /// No description provided for @readerThemeCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get readerThemeCustom;

  /// No description provided for @readerFontSerif.
  ///
  /// In en, this message translates to:
  /// **'Serif'**
  String get readerFontSerif;

  /// No description provided for @readerFontSans.
  ///
  /// In en, this message translates to:
  /// **'Sans'**
  String get readerFontSans;

  /// No description provided for @readerFontMono.
  ///
  /// In en, this message translates to:
  /// **'Mono'**
  String get readerFontMono;

  /// No description provided for @fontSizeLabel.
  ///
  /// In en, this message translates to:
  /// **'Reader font size'**
  String get fontSizeLabel;

  /// No description provided for @themeLabel.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get themeLabel;

  /// No description provided for @jobsTitle.
  ///
  /// In en, this message translates to:
  /// **'Jobs'**
  String get jobsTitle;

  /// No description provided for @noJobs.
  ///
  /// In en, this message translates to:
  /// **'No conversions yet'**
  String get noJobs;

  /// No description provided for @conversionLogTitle.
  ///
  /// In en, this message translates to:
  /// **'Conversion log'**
  String get conversionLogTitle;

  /// No description provided for @conversionJobLabel.
  ///
  /// In en, this message translates to:
  /// **'Job'**
  String get conversionJobLabel;

  /// No description provided for @conversionLastRecordedState.
  ///
  /// In en, this message translates to:
  /// **'Last recorded state'**
  String get conversionLastRecordedState;

  /// No description provided for @conversionLastRecordedStateValue.
  ///
  /// In en, this message translates to:
  /// **'Last recorded state: {state}'**
  String conversionLastRecordedStateValue(String state);

  /// No description provided for @conversionLastUpdated.
  ///
  /// In en, this message translates to:
  /// **'Last updated'**
  String get conversionLastUpdated;

  /// No description provided for @conversionRecordedAudioPath.
  ///
  /// In en, this message translates to:
  /// **'Recorded audio path: {path}'**
  String conversionRecordedAudioPath(String path);

  /// No description provided for @conversionUnreadableRecords.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 saved conversion record could not be read.} other{{count} saved conversion records could not be read.}}'**
  String conversionUnreadableRecords(int count);

  /// No description provided for @conversionStatusPending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get conversionStatusPending;

  /// No description provided for @conversionStatusRunning.
  ///
  /// In en, this message translates to:
  /// **'Converting'**
  String get conversionStatusRunning;

  /// No description provided for @conversionStatusCompleted.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get conversionStatusCompleted;

  /// No description provided for @conversionStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get conversionStatusFailed;

  /// No description provided for @conversionStatusCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get conversionStatusCancelled;

  /// No description provided for @conversionStatusUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get conversionStatusUnknown;

  /// No description provided for @conversionHistorySaveWarning.
  ///
  /// In en, this message translates to:
  /// **'Conversion completed, but its history could not be saved: {error}'**
  String conversionHistorySaveWarning(String error);

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @readerTitle.
  ///
  /// In en, this message translates to:
  /// **'Reader'**
  String get readerTitle;

  /// No description provided for @tocTitle.
  ///
  /// In en, this message translates to:
  /// **'Chapters'**
  String get tocTitle;

  /// No description provided for @downloadAll.
  ///
  /// In en, this message translates to:
  /// **'Download all'**
  String get downloadAll;

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @previous.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get previous;

  /// No description provided for @libraryTitle.
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get libraryTitle;

  /// No description provided for @libraryEmpty.
  ///
  /// In en, this message translates to:
  /// **'Your library is empty'**
  String get libraryEmpty;

  /// No description provided for @addBook.
  ///
  /// In en, this message translates to:
  /// **'Add a book'**
  String get addBook;

  /// No description provided for @importBookFile.
  ///
  /// In en, this message translates to:
  /// **'Import an EPUB or PDF file'**
  String get importBookFile;

  /// No description provided for @searchPublicBooks.
  ///
  /// In en, this message translates to:
  /// **'Search classic books'**
  String get searchPublicBooks;

  /// No description provided for @publicBookDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not download or import this book. Try again.'**
  String get publicBookDownloadFailed;

  /// No description provided for @publicBookSourceOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open the publisher’s page.'**
  String get publicBookSourceOpenFailed;

  /// No description provided for @removeBookTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove book'**
  String get removeBookTitle;

  /// No description provided for @removeBookMessage.
  ///
  /// In en, this message translates to:
  /// **'Remove \"{title}\" from your library? The file will not be deleted.'**
  String removeBookMessage(String title);

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @pickBookToRead.
  ///
  /// In en, this message translates to:
  /// **'Pick a book to read'**
  String get pickBookToRead;

  /// No description provided for @browseLibrary.
  ///
  /// In en, this message translates to:
  /// **'Browse Library'**
  String get browseLibrary;

  /// No description provided for @parsingBook.
  ///
  /// In en, this message translates to:
  /// **'Opening book…'**
  String get parsingBook;

  /// No description provided for @parsingFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open this book'**
  String get parsingFailed;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @audioEngineSection.
  ///
  /// In en, this message translates to:
  /// **'Audio engine'**
  String get audioEngineSection;

  /// No description provided for @useBuiltInEngineDesc.
  ///
  /// In en, this message translates to:
  /// **'Synthesises chapters on this device. No backend needed.'**
  String get useBuiltInEngineDesc;

  /// No description provided for @fontLabel.
  ///
  /// In en, this message translates to:
  /// **'Font'**
  String get fontLabel;

  /// No description provided for @layoutLabel.
  ///
  /// In en, this message translates to:
  /// **'Layout'**
  String get layoutLabel;

  /// No description provided for @lineSpacingLabel.
  ///
  /// In en, this message translates to:
  /// **'Line spacing'**
  String get lineSpacingLabel;

  /// No description provided for @marginLabel.
  ///
  /// In en, this message translates to:
  /// **'Margin'**
  String get marginLabel;

  /// No description provided for @readerShowPageNumbers.
  ///
  /// In en, this message translates to:
  /// **'Show page numbers'**
  String get readerShowPageNumbers;

  /// No description provided for @readerPageTurnStyle.
  ///
  /// In en, this message translates to:
  /// **'Page turn'**
  String get readerPageTurnStyle;

  /// No description provided for @pageTurnFlip.
  ///
  /// In en, this message translates to:
  /// **'Flip'**
  String get pageTurnFlip;

  /// No description provided for @pageTurnSlide.
  ///
  /// In en, this message translates to:
  /// **'Slide'**
  String get pageTurnSlide;

  /// No description provided for @pageTurnNone.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get pageTurnNone;

  /// No description provided for @readerAlignmentLabel.
  ///
  /// In en, this message translates to:
  /// **'Alignment'**
  String get readerAlignmentLabel;

  /// No description provided for @readerAlignmentJustified.
  ///
  /// In en, this message translates to:
  /// **'Justified'**
  String get readerAlignmentJustified;

  /// No description provided for @readerAlignmentLeft.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get readerAlignmentLeft;

  /// No description provided for @autoScrollLabel.
  ///
  /// In en, this message translates to:
  /// **'Auto-scroll'**
  String get autoScrollLabel;

  /// No description provided for @autoScrollDesc.
  ///
  /// In en, this message translates to:
  /// **'Scroll text to follow audio playback'**
  String get autoScrollDesc;

  /// No description provided for @playbackSection.
  ///
  /// In en, this message translates to:
  /// **'Playback'**
  String get playbackSection;

  /// No description provided for @aboutSection.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get aboutSection;

  /// No description provided for @platformLabel.
  ///
  /// In en, this message translates to:
  /// **'Platform'**
  String get platformLabel;

  /// No description provided for @readerPrefsFooter.
  ///
  /// In en, this message translates to:
  /// **'These preferences apply to every book in your library.'**
  String get readerPrefsFooter;

  /// No description provided for @nOfSteps.
  ///
  /// In en, this message translates to:
  /// **'{n} of {total}'**
  String nOfSteps(int n, int total);

  /// No description provided for @sortLastPlayed.
  ///
  /// In en, this message translates to:
  /// **'Recently played'**
  String get sortLastPlayed;

  /// No description provided for @sortTitle.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get sortTitle;

  /// No description provided for @sortDateAdded.
  ///
  /// In en, this message translates to:
  /// **'Date added'**
  String get sortDateAdded;

  /// No description provided for @libraryEmptyDesc.
  ///
  /// In en, this message translates to:
  /// **'Tap + to import an EPUB or PDF, or share one from another app.'**
  String get libraryEmptyDesc;

  /// No description provided for @offlineReady.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get offlineReady;

  /// No description provided for @cachingLabel.
  ///
  /// In en, this message translates to:
  /// **'Caching'**
  String get cachingLabel;

  /// No description provided for @removeFromLibrary.
  ///
  /// In en, this message translates to:
  /// **'Remove from library'**
  String get removeFromLibrary;

  /// No description provided for @conversionFailed.
  ///
  /// In en, this message translates to:
  /// **'Conversion failed'**
  String get conversionFailed;

  /// No description provided for @bookLanguageUncertain.
  ///
  /// In en, this message translates to:
  /// **'The book\'s language could not be detected. Choose its language in Convert and try again.'**
  String get bookLanguageUncertain;

  /// No description provided for @downloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading…'**
  String get downloading;

  /// No description provided for @downloadComplete.
  ///
  /// In en, this message translates to:
  /// **'Download complete'**
  String get downloadComplete;

  /// No description provided for @chaptersConverted.
  ///
  /// In en, this message translates to:
  /// **'{n} of {total} chapters'**
  String chaptersConverted(int n, int total);

  /// No description provided for @drmFootnote.
  ///
  /// In en, this message translates to:
  /// **'DRM-protected books (e.g. from Google Play or Kindle) cannot be opened.'**
  String get drmFootnote;

  /// No description provided for @saveForOffline.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get saveForOffline;

  /// No description provided for @searchInBook.
  ///
  /// In en, this message translates to:
  /// **'Search in book'**
  String get searchInBook;

  /// No description provided for @noResults.
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get noResults;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @searchResultsCapped.
  ///
  /// In en, this message translates to:
  /// **'Showing first 100 results'**
  String get searchResultsCapped;

  /// No description provided for @libraryColumns.
  ///
  /// In en, this message translates to:
  /// **'Columns'**
  String get libraryColumns;

  /// No description provided for @bookLanguageTitle.
  ///
  /// In en, this message translates to:
  /// **'Book language'**
  String get bookLanguageTitle;

  /// No description provided for @bookLanguageAutomatic.
  ///
  /// In en, this message translates to:
  /// **'Automatic detection'**
  String get bookLanguageAutomatic;

  /// No description provided for @bookLanguageHelp.
  ///
  /// In en, this message translates to:
  /// **'This choice applies to this book or passage. Choose Automatic detection to remove your correction.'**
  String get bookLanguageHelp;

  /// No description provided for @bookLanguageInconclusive.
  ///
  /// In en, this message translates to:
  /// **'The language could not be identified after analyzing additional passages. Choose the language for this book or passage.'**
  String get bookLanguageInconclusive;

  /// No description provided for @bookLanguageMenu.
  ///
  /// In en, this message translates to:
  /// **'Book language'**
  String get bookLanguageMenu;

  /// No description provided for @bookLanguageAnalyzing.
  ///
  /// In en, this message translates to:
  /// **'Analyzing the book…'**
  String get bookLanguageAnalyzing;

  /// No description provided for @bookLanguageSummaryMain.
  ///
  /// In en, this message translates to:
  /// **'{language} {percent}%'**
  String bookLanguageSummaryMain(String language, int percent);

  /// No description provided for @bookLanguageSummaryMainOnly.
  ///
  /// In en, this message translates to:
  /// **'{language}'**
  String bookLanguageSummaryMainOnly(String language);

  /// No description provided for @bookLanguageSummaryWritten.
  ///
  /// In en, this message translates to:
  /// **'Also written in {languages}'**
  String bookLanguageSummaryWritten(String languages);

  /// No description provided for @bookLanguageSummaryQuoted.
  ///
  /// In en, this message translates to:
  /// **'Quotes in {languages}'**
  String bookLanguageSummaryQuoted(String languages);

  /// No description provided for @bookLanguageConflict.
  ///
  /// In en, this message translates to:
  /// **'The file says {declared}; the text is {detected}.'**
  String bookLanguageConflict(String declared, String detected);

  /// No description provided for @bookLanguageDetectedSection.
  ///
  /// In en, this message translates to:
  /// **'In this book'**
  String get bookLanguageDetectedSection;

  /// No description provided for @sortLibrary.
  ///
  /// In en, this message translates to:
  /// **'Sort library'**
  String get sortLibrary;

  /// No description provided for @playbackPosition.
  ///
  /// In en, this message translates to:
  /// **'Playback position'**
  String get playbackPosition;

  /// No description provided for @playbackSpeed.
  ///
  /// In en, this message translates to:
  /// **'Playback speed'**
  String get playbackSpeed;

  /// No description provided for @sleepTimer.
  ///
  /// In en, this message translates to:
  /// **'Sleep timer'**
  String get sleepTimer;

  /// No description provided for @albumArt.
  ///
  /// In en, this message translates to:
  /// **'Album art'**
  String get albumArt;

  /// No description provided for @closePlayer.
  ///
  /// In en, this message translates to:
  /// **'Close player'**
  String get closePlayer;

  /// No description provided for @tableOfContents.
  ///
  /// In en, this message translates to:
  /// **'Table of contents'**
  String get tableOfContents;

  /// No description provided for @editTags.
  ///
  /// In en, this message translates to:
  /// **'Edit Tags'**
  String get editTags;

  /// No description provided for @tagsSection.
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get tagsSection;

  /// No description provided for @newTagHint.
  ///
  /// In en, this message translates to:
  /// **'New tag'**
  String get newTagHint;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @existingTags.
  ///
  /// In en, this message translates to:
  /// **'Existing tags'**
  String get existingTags;

  /// No description provided for @allFilter.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get allFilter;

  /// No description provided for @searchLibrary.
  ///
  /// In en, this message translates to:
  /// **'Search library'**
  String get searchLibrary;

  /// No description provided for @bookmarksTitle.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks'**
  String get bookmarksTitle;

  /// No description provided for @filterAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get filterAll;

  /// No description provided for @filterBookmarks.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks'**
  String get filterBookmarks;

  /// No description provided for @filterHighlights.
  ///
  /// In en, this message translates to:
  /// **'Highlights'**
  String get filterHighlights;

  /// No description provided for @noBookmarksYet.
  ///
  /// In en, this message translates to:
  /// **'No bookmarks yet'**
  String get noBookmarksYet;

  /// No description provided for @noBookmarksHint.
  ///
  /// In en, this message translates to:
  /// **'Long-press a paragraph in the reader to add a bookmark or highlight.'**
  String get noBookmarksHint;

  /// No description provided for @editNote.
  ///
  /// In en, this message translates to:
  /// **'Edit Note'**
  String get editNote;

  /// No description provided for @addNoteHint.
  ///
  /// In en, this message translates to:
  /// **'Add a note…'**
  String get addNoteHint;

  /// No description provided for @highlightedText.
  ///
  /// In en, this message translates to:
  /// **'Highlighted text'**
  String get highlightedText;

  /// No description provided for @colorLabel.
  ///
  /// In en, this message translates to:
  /// **'Color'**
  String get colorLabel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @removeBookmarkTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove bookmark'**
  String get removeBookmarkTitle;

  /// No description provided for @removeBookmarkMessage.
  ///
  /// In en, this message translates to:
  /// **'Remove this bookmark?'**
  String get removeBookmarkMessage;

  /// No description provided for @addBookmark.
  ///
  /// In en, this message translates to:
  /// **'Add bookmark'**
  String get addBookmark;

  /// No description provided for @bookmarkAdded.
  ///
  /// In en, this message translates to:
  /// **'Bookmark added'**
  String get bookmarkAdded;

  /// No description provided for @sizeLabel.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get sizeLabel;

  /// No description provided for @noContentAvailable.
  ///
  /// In en, this message translates to:
  /// **'No content available'**
  String get noContentAvailable;

  /// No description provided for @errorWithMessage.
  ///
  /// In en, this message translates to:
  /// **'Error: {message}'**
  String errorWithMessage(String message);

  /// No description provided for @platformAndroid.
  ///
  /// In en, this message translates to:
  /// **'Android'**
  String get platformAndroid;

  /// No description provided for @off.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get off;

  /// No description provided for @ttsPrimaryNarration.
  ///
  /// In en, this message translates to:
  /// **'Voice engine'**
  String get ttsPrimaryNarration;

  /// No description provided for @ttsSecondaryNarration.
  ///
  /// In en, this message translates to:
  /// **'Secondary voice'**
  String get ttsSecondaryNarration;

  /// No description provided for @ttsFaberOffline.
  ///
  /// In en, this message translates to:
  /// **'Faber medium · Offline'**
  String get ttsFaberOffline;

  /// No description provided for @ttsAutomaticPiper.
  ///
  /// In en, this message translates to:
  /// **'Piper · Book language'**
  String get ttsAutomaticPiper;

  /// No description provided for @ttsDetectLanguage.
  ///
  /// In en, this message translates to:
  /// **'Detect from book'**
  String get ttsDetectLanguage;

  /// No description provided for @ttsEdgeOnline.
  ///
  /// In en, this message translates to:
  /// **'Edge · Online'**
  String get ttsEdgeOnline;

  /// No description provided for @ttsNoSecondary.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get ttsNoSecondary;

  /// No description provided for @ttsSystemOffline.
  ///
  /// In en, this message translates to:
  /// **'System voice · Offline fallback'**
  String get ttsSystemOffline;

  /// No description provided for @ttsUseRecommendedDefaults.
  ///
  /// In en, this message translates to:
  /// **'Use book-language Piper with system voice fallback'**
  String get ttsUseRecommendedDefaults;

  /// No description provided for @ttsAllowOnlineSecondary.
  ///
  /// In en, this message translates to:
  /// **'Allow online fallback'**
  String get ttsAllowOnlineSecondary;

  /// No description provided for @ttsOnlineSecondaryDescription.
  ///
  /// In en, this message translates to:
  /// **'Send failed segments to Edge only when enabled.'**
  String get ttsOnlineSecondaryDescription;

  /// No description provided for @ttsAutomaticSystemFallback.
  ///
  /// In en, this message translates to:
  /// **'Automatic system voice fallback'**
  String get ttsAutomaticSystemFallback;

  /// No description provided for @ttsAutomaticSystemFallbackDescription.
  ///
  /// In en, this message translates to:
  /// **'If selected voices fail, try an installed system voice. Turn off to use only your selected voices.'**
  String get ttsAutomaticSystemFallbackDescription;

  /// No description provided for @ttsFootnoteNarration.
  ///
  /// In en, this message translates to:
  /// **'Read footnotes in the text'**
  String get ttsFootnoteNarration;

  /// No description provided for @ttsFootnoteNarrationDescription.
  ///
  /// In en, this message translates to:
  /// **'Each note is read where it is referenced, between \"Footnote N\" markers. Turn off to skip the notes.'**
  String get ttsFootnoteNarrationDescription;

  /// No description provided for @ttsEngineSystem.
  ///
  /// In en, this message translates to:
  /// **'System voice'**
  String get ttsEngineSystem;

  /// No description provided for @ttsEnginePiper.
  ///
  /// In en, this message translates to:
  /// **'Piper'**
  String get ttsEnginePiper;

  /// No description provided for @ttsEngineEdge.
  ///
  /// In en, this message translates to:
  /// **'Edge (online)'**
  String get ttsEngineEdge;

  /// No description provided for @ttsVoiceBookLanguage.
  ///
  /// In en, this message translates to:
  /// **'Book language'**
  String get ttsVoiceBookLanguage;

  /// No description provided for @ttsVoiceSystem.
  ///
  /// In en, this message translates to:
  /// **'Installed system voice'**
  String get ttsVoiceSystem;

  /// No description provided for @ttsVoiceEdge.
  ///
  /// In en, this message translates to:
  /// **'Online speech'**
  String get ttsVoiceEdge;

  /// No description provided for @ttsUsePreferences.
  ///
  /// In en, this message translates to:
  /// **'Use audio preferences'**
  String get ttsUsePreferences;

  /// No description provided for @ttsAllowJobSecondary.
  ///
  /// In en, this message translates to:
  /// **'Allow configured secondary for this conversion'**
  String get ttsAllowJobSecondary;

  /// No description provided for @ttsActualVoices.
  ///
  /// In en, this message translates to:
  /// **'Used voice: {voices}'**
  String ttsActualVoices(String voices);

  /// No description provided for @ttsSecondaryUsedNotice.
  ///
  /// In en, this message translates to:
  /// **'Using the secondary voice. The primary voice will be retried periodically.'**
  String get ttsSecondaryUsedNotice;

  /// No description provided for @platformVoiceNotice.
  ///
  /// In en, this message translates to:
  /// **'Using the system voice for this segment.'**
  String get platformVoiceNotice;

  /// No description provided for @localAudioStorage.
  ///
  /// In en, this message translates to:
  /// **'Local audio downloads'**
  String get localAudioStorage;

  /// No description provided for @localAudioStorageHint.
  ///
  /// In en, this message translates to:
  /// **'Downloaded and listened audio is kept until you remove it.'**
  String get localAudioStorageHint;

  /// No description provided for @removeAudioTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove downloaded audio?'**
  String get removeAudioTitle;

  /// No description provided for @removeAudioMessage.
  ///
  /// In en, this message translates to:
  /// **'The book, reading position and annotations will be kept.'**
  String get removeAudioMessage;

  /// No description provided for @originalTypography.
  ///
  /// In en, this message translates to:
  /// **'Original book typography'**
  String get originalTypography;

  /// No description provided for @seekForwardInterval.
  ///
  /// In en, this message translates to:
  /// **'Skip forward'**
  String get seekForwardInterval;

  /// No description provided for @seekBackwardInterval.
  ///
  /// In en, this message translates to:
  /// **'Skip backward'**
  String get seekBackwardInterval;

  /// No description provided for @remoteButtonModeTitle.
  ///
  /// In en, this message translates to:
  /// **'Next and previous buttons'**
  String get remoteButtonModeTitle;

  /// No description provided for @remoteButtonModeDescription.
  ///
  /// In en, this message translates to:
  /// **'What the buttons of your car, headphones and lock screen do.'**
  String get remoteButtonModeDescription;

  /// No description provided for @remoteButtonModeChapter.
  ///
  /// In en, this message translates to:
  /// **'Chapter'**
  String get remoteButtonModeChapter;

  /// No description provided for @remoteButtonModeSeconds.
  ///
  /// In en, this message translates to:
  /// **'Skip seconds'**
  String get remoteButtonModeSeconds;

  /// No description provided for @fallbackChapterName.
  ///
  /// In en, this message translates to:
  /// **'Chapter {number}'**
  String fallbackChapterName(int number);

  /// No description provided for @ttsShowLowQuality.
  ///
  /// In en, this message translates to:
  /// **'Show low-quality models'**
  String get ttsShowLowQuality;

  /// No description provided for @ttsManualModelUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Could not prepare this narration model.'**
  String get ttsManualModelUnavailable;

  /// No description provided for @readerBookVoiceTitle.
  ///
  /// In en, this message translates to:
  /// **'Voice for this book'**
  String get readerBookVoiceTitle;

  /// No description provided for @readerNarrationModel.
  ///
  /// In en, this message translates to:
  /// **'Narration model'**
  String get readerNarrationModel;

  /// No description provided for @readerFootnotes.
  ///
  /// In en, this message translates to:
  /// **'Footnotes'**
  String get readerFootnotes;

  /// No description provided for @openReaderAtPlayback.
  ///
  /// In en, this message translates to:
  /// **'Open in reader'**
  String get openReaderAtPlayback;

  /// No description provided for @goToNarratedPage.
  ///
  /// In en, this message translates to:
  /// **'Go to reading'**
  String get goToNarratedPage;

  /// No description provided for @readerAppearance.
  ///
  /// In en, this message translates to:
  /// **'Text appearance'**
  String get readerAppearance;

  /// No description provided for @readerPlayFromHere.
  ///
  /// In en, this message translates to:
  /// **'Play from here'**
  String get readerPlayFromHere;

  /// No description provided for @errorPdfOcrRequired.
  ///
  /// In en, this message translates to:
  /// **'This PDF has a page with only an image and no selectable text (often the cover). It cannot be narrated until that text is recognized (OCR).'**
  String get errorPdfOcrRequired;

  /// No description provided for @errorNoReadableText.
  ///
  /// In en, this message translates to:
  /// **'No readable text could be extracted from this book.'**
  String get errorNoReadableText;

  /// No description provided for @errorEngineUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The speech converter is unavailable. Please reinstall the app or try again.'**
  String get errorEngineUnavailable;

  /// No description provided for @errorModelMissing.
  ///
  /// In en, this message translates to:
  /// **'The selected narration model is not installed. Install it in Settings.'**
  String get errorModelMissing;

  /// No description provided for @errorNoOfflineVoice.
  ///
  /// In en, this message translates to:
  /// **'No offline voice for this book\'s language is installed on this device. Install a voice model in Settings, or add an offline system voice.'**
  String get errorNoOfflineVoice;

  /// No description provided for @errorModelLanguage.
  ///
  /// In en, this message translates to:
  /// **'This model does not support the language of this book. Choose a compatible model.'**
  String get errorModelLanguage;

  /// No description provided for @errorUnsupportedEngine.
  ///
  /// In en, this message translates to:
  /// **'The selected speech engine is not supported.'**
  String get errorUnsupportedEngine;

  /// No description provided for @errorSpeechTimeout.
  ///
  /// In en, this message translates to:
  /// **'The voice took too long to respond. Please try again.'**
  String get errorSpeechTimeout;

  /// No description provided for @errorNetwork.
  ///
  /// In en, this message translates to:
  /// **'Could not connect. Check your connection and try again.'**
  String get errorNetwork;

  /// No description provided for @errorRateLimited.
  ///
  /// In en, this message translates to:
  /// **'The voice service is busy. Please try again in a moment.'**
  String get errorRateLimited;

  /// No description provided for @errorInputUnreadable.
  ///
  /// In en, this message translates to:
  /// **'This book could not be read. The file may be damaged.'**
  String get errorInputUnreadable;

  /// No description provided for @errorUnsupportedInput.
  ///
  /// In en, this message translates to:
  /// **'This kind of file is not supported.'**
  String get errorUnsupportedInput;

  /// No description provided for @errorConversionGeneric.
  ///
  /// In en, this message translates to:
  /// **'The book could not be converted to audio. Please try again. Technical details are available in the logs.'**
  String get errorConversionGeneric;

  /// No description provided for @errorEdgeConsentRequired.
  ///
  /// In en, this message translates to:
  /// **'Online Edge voices need your permission. Turn on “Allow online fallback” in Settings, or choose a local voice, and try again.'**
  String get errorEdgeConsentRequired;

  /// No description provided for @modelsTitle.
  ///
  /// In en, this message translates to:
  /// **'Models'**
  String get modelsTitle;

  /// No description provided for @modelsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose the narration for each book language'**
  String get modelsSubtitle;

  /// No description provided for @modelsLanguagesTitle.
  ///
  /// In en, this message translates to:
  /// **'Languages'**
  String get modelsLanguagesTitle;

  /// No description provided for @modelsSystemLanguages.
  ///
  /// In en, this message translates to:
  /// **'System languages'**
  String get modelsSystemLanguages;

  /// No description provided for @modelsPopularLanguages.
  ///
  /// In en, this message translates to:
  /// **'Most popular'**
  String get modelsPopularLanguages;

  /// No description provided for @modelsOtherLanguages.
  ///
  /// In en, this message translates to:
  /// **'All languages'**
  String get modelsOtherLanguages;

  /// No description provided for @modelsSystemSection.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get modelsSystemSection;

  /// No description provided for @modelsSystemVoice.
  ///
  /// In en, this message translates to:
  /// **'System voice'**
  String get modelsSystemVoice;

  /// No description provided for @modelsPiperSection.
  ///
  /// In en, this message translates to:
  /// **'Piper (on this device)'**
  String get modelsPiperSection;

  /// No description provided for @modelsEdgeSection.
  ///
  /// In en, this message translates to:
  /// **'Edge (online)'**
  String get modelsEdgeSection;

  /// No description provided for @modelsVoiceForEachLanguage.
  ///
  /// In en, this message translates to:
  /// **'Voice for each language'**
  String get modelsVoiceForEachLanguage;

  /// No description provided for @modelsAllLanguages.
  ///
  /// In en, this message translates to:
  /// **'All languages'**
  String get modelsAllLanguages;

  /// No description provided for @modelsNeedsVoice.
  ///
  /// In en, this message translates to:
  /// **'A book in your library needs a voice for this language'**
  String get modelsNeedsVoice;

  /// No description provided for @modelsSizeMb.
  ///
  /// In en, this message translates to:
  /// **'{size} MB'**
  String modelsSizeMb(int size);

  /// No description provided for @modelsFallbackSection.
  ///
  /// In en, this message translates to:
  /// **'Fallback voices'**
  String get modelsFallbackSection;

  /// No description provided for @modelsLowQualitySection.
  ///
  /// In en, this message translates to:
  /// **'Piper · low quality'**
  String get modelsLowQualitySection;

  /// No description provided for @modelsAutomatic.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get modelsAutomatic;

  /// No description provided for @modelsAutomaticDesc.
  ///
  /// In en, this message translates to:
  /// **'Uses the best installed model for the book'**
  String get modelsAutomaticDesc;

  /// No description provided for @modelsLocalSection.
  ///
  /// In en, this message translates to:
  /// **'On this device'**
  String get modelsLocalSection;

  /// No description provided for @modelsOnlineSection.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get modelsOnlineSection;

  /// No description provided for @modelsOnlineNeedsConsent.
  ///
  /// In en, this message translates to:
  /// **'Turn on “Allow online fallback” in Settings to use online voices'**
  String get modelsOnlineNeedsConsent;

  /// No description provided for @modelsNotInstalled.
  ///
  /// In en, this message translates to:
  /// **'Tap to download and use'**
  String get modelsNotInstalled;

  /// No description provided for @modelsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No models are available for this device'**
  String get modelsEmpty;

  /// No description provided for @modelsLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'The model list could not be loaded'**
  String get modelsLoadFailed;

  /// No description provided for @modelsRowSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 model} other{{count} models}}'**
  String modelsRowSubtitle(int count);

  /// No description provided for @modelsMissingTitle.
  ///
  /// In en, this message translates to:
  /// **'No narration model for {language}'**
  String modelsMissingTitle(String language);

  /// No description provided for @modelsMissingBody.
  ///
  /// In en, this message translates to:
  /// **'Install a narration model for this language, then try again.'**
  String get modelsMissingBody;

  /// No description provided for @modelsMissingAction.
  ///
  /// In en, this message translates to:
  /// **'Open Models'**
  String get modelsMissingAction;

  /// No description provided for @bookLanguagesMissingModels.
  ///
  /// In en, this message translates to:
  /// **'This book also has passages in {languages}. No voice is installed for them, so they are read with the main voice.'**
  String bookLanguagesMissingModels(String languages);

  /// No description provided for @convertChooseFile.
  ///
  /// In en, this message translates to:
  /// **'Choose EPUB or PDF'**
  String get convertChooseFile;

  /// No description provided for @convertEngine.
  ///
  /// In en, this message translates to:
  /// **'Engine'**
  String get convertEngine;

  /// No description provided for @convertVoice.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get convertVoice;

  /// No description provided for @convertLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get convertLanguage;

  /// No description provided for @convertLanguagePortuguese.
  ///
  /// In en, this message translates to:
  /// **'Portuguese'**
  String get convertLanguagePortuguese;

  /// No description provided for @convertLanguageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get convertLanguageEnglish;

  /// No description provided for @convertLanguageSpanish.
  ///
  /// In en, this message translates to:
  /// **'Spanish'**
  String get convertLanguageSpanish;

  /// No description provided for @convertChapterRange.
  ///
  /// In en, this message translates to:
  /// **'Chapter range'**
  String get convertChapterRange;

  /// No description provided for @convertChapterFrom.
  ///
  /// In en, this message translates to:
  /// **'From'**
  String get convertChapterFrom;

  /// No description provided for @convertChapterTo.
  ///
  /// In en, this message translates to:
  /// **'To'**
  String get convertChapterTo;

  /// No description provided for @convertOptions.
  ///
  /// In en, this message translates to:
  /// **'Options'**
  String get convertOptions;

  /// No description provided for @convertOptionsManagedLocally.
  ///
  /// In en, this message translates to:
  /// **'Cover and audio processing options are managed by the local converter.'**
  String get convertOptionsManagedLocally;

  /// No description provided for @convertIncludeCover.
  ///
  /// In en, this message translates to:
  /// **'Include cover'**
  String get convertIncludeCover;

  /// No description provided for @convertNormalizeAudio.
  ///
  /// In en, this message translates to:
  /// **'Normalize audio'**
  String get convertNormalizeAudio;

  /// No description provided for @convertStart.
  ///
  /// In en, this message translates to:
  /// **'Start conversion'**
  String get convertStart;

  /// No description provided for @tocDownloadAll.
  ///
  /// In en, this message translates to:
  /// **'Download for offline'**
  String get tocDownloadAll;

  /// No description provided for @tocCancelDownloads.
  ///
  /// In en, this message translates to:
  /// **'Cancel downloads'**
  String get tocCancelDownloads;

  /// No description provided for @tocRetryFailed.
  ///
  /// In en, this message translates to:
  /// **'Retry failed chapters'**
  String get tocRetryFailed;

  /// No description provided for @tocShareAudio.
  ///
  /// In en, this message translates to:
  /// **'Share available audio'**
  String get tocShareAudio;

  /// No description provided for @tocRemoveDownloads.
  ///
  /// In en, this message translates to:
  /// **'Remove downloads'**
  String get tocRemoveDownloads;

  /// No description provided for @tocRemoveDownloadsMessage.
  ///
  /// In en, this message translates to:
  /// **'All downloaded MP3s of this book will be deleted.'**
  String get tocRemoveDownloadsMessage;

  /// No description provided for @tocAudioReady.
  ///
  /// In en, this message translates to:
  /// **'Audio ready'**
  String get tocAudioReady;

  /// No description provided for @tocAudioConverting.
  ///
  /// In en, this message translates to:
  /// **'Converting audio'**
  String get tocAudioConverting;

  /// No description provided for @tocAudioFailed.
  ///
  /// In en, this message translates to:
  /// **'Audio failed'**
  String get tocAudioFailed;

  /// No description provided for @readerHighlight.
  ///
  /// In en, this message translates to:
  /// **'Highlight'**
  String get readerHighlight;

  /// No description provided for @readerAddNote.
  ///
  /// In en, this message translates to:
  /// **'Add Note'**
  String get readerAddNote;

  /// No description provided for @readerRemoveHighlight.
  ///
  /// In en, this message translates to:
  /// **'Remove highlight'**
  String get readerRemoveHighlight;

  /// No description provided for @readerPassageLanguage.
  ///
  /// In en, this message translates to:
  /// **'Passage language'**
  String get readerPassageLanguage;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'pt':
      return AppLocalizationsPt();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
