import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
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
    Locale('pt'),
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Epub to MP3'**
  String get appTitle;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @backendUrl.
  ///
  /// In en, this message translates to:
  /// **'Backend URL'**
  String get backendUrl;

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

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @playerTitle.
  ///
  /// In en, this message translates to:
  /// **'Player'**
  String get playerTitle;

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

  /// No description provided for @loadingFulltext.
  ///
  /// In en, this message translates to:
  /// **'Loading text…'**
  String get loadingFulltext;

  /// No description provided for @fulltextEmpty.
  ///
  /// In en, this message translates to:
  /// **'No readable text available'**
  String get fulltextEmpty;

  /// No description provided for @fulltextGone.
  ///
  /// In en, this message translates to:
  /// **'Text no longer available'**
  String get fulltextGone;

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
  /// **'No books yet'**
  String get libraryEmpty;

  /// No description provided for @addBook.
  ///
  /// In en, this message translates to:
  /// **'Add a book'**
  String get addBook;

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

  /// No description provided for @noConversionYet.
  ///
  /// In en, this message translates to:
  /// **'Convert this book first to play audio'**
  String get noConversionYet;

  /// No description provided for @readerEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Open a book from the library to start reading'**
  String get readerEmptyHint;

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

  /// No description provided for @generatingAudio.
  ///
  /// In en, this message translates to:
  /// **'Generating audio'**
  String get generatingAudio;

  /// No description provided for @nowPlaying.
  ///
  /// In en, this message translates to:
  /// **'Now Playing'**
  String get nowPlaying;

  /// No description provided for @audioEngineSection.
  ///
  /// In en, this message translates to:
  /// **'Audio engine'**
  String get audioEngineSection;

  /// No description provided for @useBuiltInEngine.
  ///
  /// In en, this message translates to:
  /// **'Use built-in audio engine'**
  String get useBuiltInEngine;

  /// No description provided for @useBuiltInEngineDesc.
  ///
  /// In en, this message translates to:
  /// **'Synthesises chapters on this device. No backend needed.'**
  String get useBuiltInEngineDesc;

  /// No description provided for @audioEngineFooter.
  ///
  /// In en, this message translates to:
  /// **'Reading works offline either way — this only affects audio generation.'**
  String get audioEngineFooter;

  /// No description provided for @remoteBackendSection.
  ///
  /// In en, this message translates to:
  /// **'Remote backend'**
  String get remoteBackendSection;

  /// No description provided for @backendUrlHint.
  ///
  /// In en, this message translates to:
  /// **'http://localhost:8000'**
  String get backendUrlHint;

  /// No description provided for @backendUrlFooter.
  ///
  /// In en, this message translates to:
  /// **'Point to a local server or Hugging Face Space URL.'**
  String get backendUrlFooter;

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

  /// No description provided for @projectOnGithub.
  ///
  /// In en, this message translates to:
  /// **'Project on GitHub'**
  String get projectOnGithub;

  /// No description provided for @readerPrefsFooter.
  ///
  /// In en, this message translates to:
  /// **'These preferences apply to every book in your library.'**
  String get readerPrefsFooter;

  /// No description provided for @invalidUrl.
  ///
  /// In en, this message translates to:
  /// **'URL is not valid'**
  String get invalidUrl;

  /// No description provided for @nOfSteps.
  ///
  /// In en, this message translates to:
  /// **'{n} of {total}'**
  String nOfSteps(int n, int total);

  /// No description provided for @sortBy.
  ///
  /// In en, this message translates to:
  /// **'Sort by'**
  String get sortBy;

  /// No description provided for @sortLastOpened.
  ///
  /// In en, this message translates to:
  /// **'Last opened'**
  String get sortLastOpened;

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

  /// No description provided for @startingConversion.
  ///
  /// In en, this message translates to:
  /// **'Starting conversion…'**
  String get startingConversion;

  /// No description provided for @conversionFailed.
  ///
  /// In en, this message translates to:
  /// **'Conversion failed'**
  String get conversionFailed;

  /// No description provided for @uploadFailed.
  ///
  /// In en, this message translates to:
  /// **'Upload failed'**
  String get uploadFailed;

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

  /// No description provided for @downloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed'**
  String get downloadFailed;

  /// No description provided for @chaptersConverted.
  ///
  /// In en, this message translates to:
  /// **'{n} of {total} chapters'**
  String chaptersConverted(int n, int total);
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
      <String>['en', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
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
