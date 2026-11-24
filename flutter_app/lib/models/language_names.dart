/// Endonyms (a language's own name for itself) for the base languages of the
/// model catalog. They do not depend on the app language, which is how language
/// pickers conventionally list languages. Unknown tags fall back to the tag.
const _endonyms = <String, String>{
  'ur': 'اردو',
  'te': 'తెలుగు',
  'sq': 'Shqip',
  'nb': 'Norsk bokmål',
  'ml': 'മലയാളം',
  'lv': 'Latviešu',
  'ku': 'Kurdî',
  'hy': 'Հայերեն',
  'eu': 'Euskara',
  'ar': 'العربية',
  'bg': 'Български',
  'ca': 'Català',
  'cs': 'Čeština',
  'cy': 'Cymraeg',
  'da': 'Dansk',
  'de': 'Deutsch',
  'el': 'Ελληνικά',
  'en': 'English',
  'es': 'Español',
  'fa': 'فارسی',
  'fi': 'Suomi',
  'fr': 'Français',
  'hi': 'हिन्दी',
  'hu': 'Magyar',
  'id': 'Bahasa Indonesia',
  'is': 'Íslenska',
  'it': 'Italiano',
  'ja': '日本語',
  'ka': 'ქართული',
  'kk': 'Қазақша',
  'ko': '한국어',
  'lb': 'Lëtzebuergesch',
  'ne': 'नेपाली',
  'nl': 'Nederlands',
  'no': 'Norsk',
  'pl': 'Polski',
  'pt': 'Português',
  'ro': 'Română',
  'ru': 'Русский',
  'sk': 'Slovenčina',
  'sl': 'Slovenščina',
  'sr': 'Српски',
  'sv': 'Svenska',
  'sw': 'Kiswahili',
  'tr': 'Türkçe',
  'uk': 'Українська',
  'vi': 'Tiếng Việt',
  'zh': '中文',
};

String languageEndonym(String baseTag) =>
    _endonyms[baseTag.toLowerCase()] ?? baseTag;

const _regionalChoices = <String, String>{
  'pt-BR': 'Português (Brasil)',
  'pt-PT': 'Português (Portugal)',
  'en-US': 'English (United States)',
  'en-GB': 'English (United Kingdom)',
  'es-ES': 'Español (España)',
  'es-MX': 'Español (México)',
};

/// Language tags a user can pick as a book or passage language: every base
/// language of the catalog plus the common regional variants (as Apple's picker).
List<String> get pickableLanguageTags {
  final tags = [..._endonyms.keys, ..._regionalChoices.keys];
  tags.sort(
    (a, b) => languageChoiceLabel(a).toLowerCase().compareTo(
      languageChoiceLabel(b).toLowerCase(),
    ),
  );
  return tags;
}

/// The label of a pickable tag, regional variants included.
String languageChoiceLabel(String tag) =>
    _regionalChoices[tag] ?? languageEndonym(tag);
