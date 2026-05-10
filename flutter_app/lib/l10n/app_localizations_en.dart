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
}
