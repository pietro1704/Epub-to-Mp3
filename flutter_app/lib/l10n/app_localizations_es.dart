// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'Epub a MP3';

  @override
  String get convertTitle => 'Convertir';

  @override
  String get settingsTitle => 'Configuración';

  @override
  String get wpmLabel => 'Palabras por minuto';

  @override
  String get audioRateLabel => 'Velocidad de reproducción';

  @override
  String get readingPreferencesTitle => 'Preferencias de lectura';

  @override
  String get readingModeDefault => 'Predeterminado para todos los libros';

  @override
  String get readingModeBook => 'Solo este libro';

  @override
  String get readingUseDefault => 'Usar el valor predeterminado';

  @override
  String get readingSpeedLabel => 'Velocidad de la narración';

  @override
  String get readingDefaultHint =>
      'Los cambios valen para todo libro sin ajustes propios.';

  @override
  String get readingBookHint =>
      'Los cambios valen solo para este libro. Toca Usar el valor predeterminado para volver al predeterminado.';

  @override
  String get readerLayoutScrolling => 'Desplazamiento';

  @override
  String get readerLayoutPaginated => 'Paginado';

  @override
  String get readerThemeAuto => 'Automático';

  @override
  String get readerThemeLight => 'Claro';

  @override
  String get readerThemeSepia => 'Sepia';

  @override
  String get readerThemeParchment => 'Pergamino';

  @override
  String get readerThemePaper => 'Papel';

  @override
  String get readerThemeDark => 'Oscuro';

  @override
  String get readerThemeBlack => 'Negro';

  @override
  String get readerThemeCustom => 'Personalizado';

  @override
  String get readerFontSerif => 'Serif';

  @override
  String get readerFontSans => 'Sans';

  @override
  String get readerFontMono => 'Mono';

  @override
  String get fontSizeLabel => 'Tamaño de fuente';

  @override
  String get themeLabel => 'Tema';

  @override
  String get jobsTitle => 'Conversiones';

  @override
  String get noJobs => 'Ninguna conversión aún';

  @override
  String get conversionLogTitle => 'Registro de conversión';

  @override
  String get conversionJobLabel => 'Conversión';

  @override
  String get conversionLastRecordedState => 'Último estado registrado';

  @override
  String conversionLastRecordedStateValue(String state) {
    return 'Último estado registrado: $state';
  }

  @override
  String get conversionLastUpdated => 'Última actualización';

  @override
  String conversionRecordedAudioPath(String path) {
    return 'Ruta registrada del audio: $path';
  }

  @override
  String conversionUnreadableRecords(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'No se pudieron leer $count registros de conversión guardados.',
      one: 'No se pudo leer 1 registro de conversión guardado.',
    );
    return '$_temp0';
  }

  @override
  String get conversionStatusPending => 'Pendiente';

  @override
  String get conversionStatusRunning => 'Convirtiendo';

  @override
  String get conversionStatusCompleted => 'Completada';

  @override
  String get conversionStatusFailed => 'Fallida';

  @override
  String get conversionStatusCancelled => 'Cancelada';

  @override
  String get conversionStatusUnknown => 'Desconocido';

  @override
  String conversionHistorySaveWarning(String error) {
    return 'Conversión completada, pero no se pudo guardar el historial: $error';
  }

  @override
  String get refresh => 'Actualizar';

  @override
  String get readerTitle => 'Lector';

  @override
  String get tocTitle => 'Capítulos';

  @override
  String get downloadAll => 'Descargar todo';

  @override
  String get play => 'Reproducir';

  @override
  String get pause => 'Pausar';

  @override
  String get next => 'Siguiente';

  @override
  String get previous => 'Anterior';

  @override
  String get libraryTitle => 'Biblioteca';

  @override
  String get libraryEmpty => 'Tu biblioteca está vacía';

  @override
  String get addBook => 'Agregar libro';

  @override
  String get importBookFile => 'Importar archivo EPUB o PDF';

  @override
  String get searchPublicBooks => 'Buscar libros clásicos';

  @override
  String get publicBookDownloadFailed =>
      'No se pudo descargar o importar este libro. Inténtalo de nuevo.';

  @override
  String get publicBookSourceOpenFailed =>
      'No se pudo abrir la página de la editorial.';

  @override
  String get removeBookTitle => 'Eliminar libro';

  @override
  String removeBookMessage(String title) {
    return '¿Eliminar \"$title\" de la biblioteca? El archivo no se borrará.';
  }

  @override
  String get cancel => 'Cancelar';

  @override
  String get remove => 'Eliminar';

  @override
  String get pickBookToRead => 'Elige un libro para leer';

  @override
  String get browseLibrary => 'Ver Biblioteca';

  @override
  String get parsingBook => 'Abriendo libro…';

  @override
  String get parsingFailed => 'No se pudo abrir este libro';

  @override
  String get retry => 'Reintentar';

  @override
  String get audioEngineSection => 'Motor de audio';

  @override
  String get useBuiltInEngineDesc =>
      'Sintetiza capítulos en este dispositivo. Sin servidor necesario.';

  @override
  String get fontLabel => 'Fuente';

  @override
  String get layoutLabel => 'Diseño';

  @override
  String get lineSpacingLabel => 'Interlineado';

  @override
  String get marginLabel => 'Margen';

  @override
  String get readerShowPageNumbers => 'Mostrar números de página';

  @override
  String get readerPageTurnStyle => 'Paso de página';

  @override
  String get pageTurnFlip => 'Voltear';

  @override
  String get pageTurnSlide => 'Deslizar';

  @override
  String get pageTurnNone => 'Ninguna';

  @override
  String get readerAlignmentLabel => 'Alineación';

  @override
  String get readerAlignmentJustified => 'Justificado';

  @override
  String get readerAlignmentLeft => 'Izquierda';

  @override
  String get autoScrollLabel => 'Desplazamiento automático';

  @override
  String get autoScrollDesc => 'Desplazar texto para seguir la reproducción';

  @override
  String get playbackSection => 'Reproducción';

  @override
  String get aboutSection => 'Acerca de';

  @override
  String get platformLabel => 'Plataforma';

  @override
  String get readerPrefsFooter =>
      'Estas preferencias se aplican a todos los libros de tu biblioteca.';

  @override
  String nOfSteps(int n, int total) {
    return '$n de $total';
  }

  @override
  String get sortLastPlayed => 'Reproducidos recientemente';

  @override
  String get sortTitle => 'Título';

  @override
  String get sortDateAdded => 'Fecha de adición';

  @override
  String get libraryEmptyDesc =>
      'Toca + para importar un EPUB o PDF, o comparte uno desde otra app.';

  @override
  String get offlineReady => 'Sin conexión';

  @override
  String get cachingLabel => 'Cacheando';

  @override
  String get removeFromLibrary => 'Eliminar de la biblioteca';

  @override
  String get conversionFailed => 'Falló la conversión';

  @override
  String get bookLanguageUncertain =>
      'No se pudo detectar el idioma del libro. Elige el idioma en Convertir e inténtalo de nuevo.';

  @override
  String get downloading => 'Descargando…';

  @override
  String get downloadComplete => 'Descarga completa';

  @override
  String chaptersConverted(int n, int total) {
    return '$n de $total capítulos';
  }

  @override
  String get drmFootnote =>
      'Los libros con DRM (ej: Google Play o Kindle) no se pueden abrir.';

  @override
  String get saveForOffline => 'Guardar';

  @override
  String get searchInBook => 'Buscar en el libro';

  @override
  String get noResults => 'Sin resultados';

  @override
  String get done => 'Listo';

  @override
  String get searchResultsCapped => 'Mostrando los primeros 100 resultados';

  @override
  String get libraryColumns => 'Columnas';

  @override
  String get bookLanguageTitle => 'Idioma del libro';

  @override
  String get bookLanguageAutomatic => 'Detección automática';

  @override
  String get bookLanguageHelp =>
      'Esta elección vale para este libro o fragmento. Elige Detección automática para quitar tu corrección.';

  @override
  String get bookLanguageInconclusive =>
      'No se pudo identificar el idioma tras analizar otros fragmentos. Elige el idioma de este libro o fragmento.';

  @override
  String get bookLanguageMenu => 'Idioma del libro';

  @override
  String get bookLanguageAnalyzing => 'Analizando el libro…';

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
    return 'También escrito en $languages';
  }

  @override
  String bookLanguageSummaryQuoted(String languages) {
    return 'Citas en $languages';
  }

  @override
  String bookLanguageConflict(String declared, String detected) {
    return 'El archivo dice $declared; el texto está en $detected.';
  }

  @override
  String get bookLanguageDetectedSection => 'En este libro';

  @override
  String get sortLibrary => 'Ordenar biblioteca';

  @override
  String get playbackPosition => 'Posición de reproducción';

  @override
  String get playbackSpeed => 'Velocidad de reproducción';

  @override
  String get sleepTimer => 'Temporizador de sueño';

  @override
  String get albumArt => 'Portada del álbum';

  @override
  String get closePlayer => 'Cerrar reproductor';

  @override
  String get tableOfContents => 'Tabla de contenidos';

  @override
  String get editTags => 'Editar Etiquetas';

  @override
  String get tagsSection => 'Etiquetas';

  @override
  String get newTagHint => 'Nueva etiqueta';

  @override
  String get add => 'Agregar';

  @override
  String get existingTags => 'Etiquetas existentes';

  @override
  String get allFilter => 'Todas';

  @override
  String get searchLibrary => 'Buscar en la biblioteca';

  @override
  String get bookmarksTitle => 'Marcadores';

  @override
  String get filterAll => 'Todos';

  @override
  String get filterBookmarks => 'Marcadores';

  @override
  String get filterHighlights => 'Destacados';

  @override
  String get noBookmarksYet => 'Sin marcadores aún';

  @override
  String get noBookmarksHint =>
      'Mantén presionado un párrafo en el lector para agregar un marcador o destacado.';

  @override
  String get editNote => 'Editar Nota';

  @override
  String get addNoteHint => 'Agregar nota…';

  @override
  String get highlightedText => 'Texto destacado';

  @override
  String get colorLabel => 'Color';

  @override
  String get save => 'Guardar';

  @override
  String get removeBookmarkTitle => 'Eliminar marcador';

  @override
  String get removeBookmarkMessage => '¿Eliminar este marcador?';

  @override
  String get addBookmark => 'Agregar marcador';

  @override
  String get bookmarkAdded => 'Marcador agregado';

  @override
  String get sizeLabel => 'Tamaño';

  @override
  String get noContentAvailable => 'Sin contenido disponible';

  @override
  String errorWithMessage(String message) {
    return 'Error: $message';
  }

  @override
  String get platformAndroid => 'Android';

  @override
  String get off => 'Apagado';

  @override
  String get ttsPrimaryNarration => 'Narración principal';

  @override
  String get ttsSecondaryNarration => 'Narración secundaria';

  @override
  String get ttsFaberOffline => 'Faber medium · Sin conexión';

  @override
  String get ttsAutomaticPiper => 'Piper · Idioma del libro';

  @override
  String get ttsDetectLanguage => 'Detectar según el libro';

  @override
  String get ttsEdgeOnline => 'Edge · En línea';

  @override
  String get ttsNoSecondary => 'Ninguna';

  @override
  String get ttsSystemOffline => 'Voz del sistema · Alternativa sin conexión';

  @override
  String get ttsUseRecommendedDefaults =>
      'Usar Piper según el idioma del libro con voz del sistema como alternativa';

  @override
  String get ttsAllowOnlineSecondary => 'Permitir respaldo en línea';

  @override
  String get ttsOnlineSecondaryDescription =>
      'Envía los fragmentos que fallen a Edge solo cuando esta opción esté activada.';

  @override
  String get ttsAutomaticSystemFallback =>
      'Voz del sistema como alternativa automática';

  @override
  String get ttsAutomaticSystemFallbackDescription =>
      'Si fallan las voces seleccionadas, intenta una voz instalada del sistema. Desactiva para usar solo las voces seleccionadas.';

  @override
  String get ttsFootnoteNarration => 'Leer las notas al pie en el texto';

  @override
  String get ttsFootnoteNarrationDescription =>
      'Cada nota se lee donde se cita, entre los avisos \"Nota al pie N\". Desactiva para omitir las notas.';

  @override
  String get ttsEngineSystem => 'Voz del sistema';

  @override
  String get ttsEnginePiper => 'Piper';

  @override
  String get ttsEngineEdge => 'Edge (en línea)';

  @override
  String get ttsVoiceBookLanguage => 'Idioma del libro';

  @override
  String get ttsVoiceSystem => 'Voz instalada en el sistema';

  @override
  String get ttsVoiceEdge => 'Voz en línea';

  @override
  String get ttsUsePreferences => 'Usar preferencias de audio';

  @override
  String get ttsAllowJobSecondary =>
      'Permitir la voz secundaria configurada en esta conversión';

  @override
  String ttsActualVoices(String voices) {
    return 'Voz utilizada: $voices';
  }

  @override
  String get ttsSecondaryUsedNotice =>
      'Usando la voz secundaria. Se volverá a intentar la voz principal periódicamente.';

  @override
  String get platformVoiceNotice =>
      'Usando la voz del sistema en este fragmento.';

  @override
  String platformVoiceNoticeEngine(String engine) {
    return 'Usando la voz del sistema ($engine) en este fragmento.';
  }

  @override
  String get localAudioStorage => 'Audio descargado en el dispositivo';

  @override
  String get localAudioStorageHint =>
      'El audio descargado y escuchado se conserva hasta que lo elimines.';

  @override
  String get removeAudioTitle => '¿Eliminar el audio descargado?';

  @override
  String get removeAudioMessage =>
      'Se conservarán el libro, la posición de lectura y las anotaciones.';

  @override
  String get originalTypography => 'Tipografía original del libro';

  @override
  String get seekForwardInterval => 'Avanzar';

  @override
  String get seekBackwardInterval => 'Retroceder';

  @override
  String get remoteButtonModeTitle => 'Botones siguiente y anterior';

  @override
  String get remoteButtonModeDescription =>
      'Qué hacen los botones del coche, los auriculares y la pantalla de bloqueo.';

  @override
  String get remoteButtonModeChapter => 'Capítulo';

  @override
  String get remoteButtonModeSeconds => 'Saltar segundos';

  @override
  String fallbackChapterName(int number) {
    return 'Capítulo $number';
  }

  @override
  String get ttsShowLowQuality => 'Mostrar modelos de calidad baja';

  @override
  String get ttsManualModelUnavailable =>
      'No se pudo preparar este modelo de narración.';

  @override
  String get readerBookVoiceTitle => 'Voz para este libro';

  @override
  String get readerNarrationModel => 'Modelo de narración';

  @override
  String get readerFootnotes => 'Notas al pie';

  @override
  String get openReaderAtPlayback => 'Abrir en el lector';

  @override
  String get goToNarratedPage => 'Ir a la lectura';

  @override
  String get readerAppearance => 'Apariencia del texto';

  @override
  String get readerPlayFromHere => 'Reproducir desde aquí';

  @override
  String get errorPdfOcrRequired =>
      'Este PDF no tiene texto seleccionable en ninguna página (parece escaneado). No se puede narrar hasta que ese texto se reconozca (OCR).';

  @override
  String pdfPagesSkipped(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Omitimos $count páginas del PDF sin texto seleccionable (portada, imágenes o páginas en blanco). Narramos el resto del libro.',
      one: 'Omitimos 1 página del PDF sin texto seleccionable (portada, imagen o página en blanco). Narramos el resto del libro.',
    );
    return '$_temp0';
  }

  @override
  String get errorNoReadableText =>
      'No se pudo extraer texto legible de este libro.';

  @override
  String get errorEngineUnavailable =>
      'El conversor de voz no está disponible. Reinstala la app o inténtalo de nuevo.';

  @override
  String get errorModelMissing =>
      'El modelo de narración seleccionado no está instalado. Instálalo en Ajustes.';

  @override
  String get errorNoOfflineVoice =>
      'No hay ninguna voz sin conexión para el idioma de este libro en este dispositivo. Instala un modelo de voz en Ajustes o añade una voz del sistema sin conexión.';

  @override
  String get errorModelLanguage =>
      'Este modelo no admite el idioma de este libro. Elige un modelo compatible.';

  @override
  String get errorUnsupportedEngine =>
      'El motor de voz seleccionado no es compatible.';

  @override
  String get errorSpeechTimeout =>
      'La voz tardó demasiado en responder. Inténtalo de nuevo.';

  @override
  String get errorNetwork =>
      'No se pudo conectar. Revisa tu conexión e inténtalo de nuevo.';

  @override
  String get errorRateLimited =>
      'El servicio de voz está ocupado. Inténtalo de nuevo en un momento.';

  @override
  String get errorInputUnreadable =>
      'No se pudo leer este libro. El archivo puede estar dañado.';

  @override
  String get errorUnsupportedInput => 'Este tipo de archivo no es compatible.';

  @override
  String get errorConversionGeneric =>
      'No se pudo convertir el libro en audio. Inténtalo de nuevo. Los detalles técnicos están en los registros.';

  @override
  String get errorEdgeConsentRequired =>
      'Las voces en línea de Edge necesitan tu permiso. Activa «Permitir respaldo en línea» en Ajustes o elige una voz local e inténtalo de nuevo.';

  @override
  String get modelsTitle => 'Modelos';

  @override
  String get modelsSubtitle => 'Elige la narración para cada idioma de libro';

  @override
  String get modelsLanguagesTitle => 'Idiomas';

  @override
  String get modelsSystemLanguages => 'Idiomas del sistema';

  @override
  String get modelsPopularLanguages => 'Más populares';

  @override
  String get modelsOtherLanguages => 'Todos los idiomas';

  @override
  String get modelsSystemSection => 'Sistema';

  @override
  String get modelsSystemVoice => 'Voz del sistema';

  @override
  String get modelsPiperSection => 'Piper (en este dispositivo)';

  @override
  String get modelsEdgeSection => 'Edge (en línea)';

  @override
  String get modelsVoiceForEachLanguage => 'Voz para cada idioma';

  @override
  String get modelsAllLanguages => 'Todos los idiomas';

  @override
  String get modelsNeedsVoice =>
      'Un libro de tu biblioteca necesita una voz para este idioma';

  @override
  String modelsSizeMb(int size) {
    return '$size MB';
  }

  @override
  String get modelsFallbackSection => 'Voces de reserva';

  @override
  String get modelsLowQualitySection => 'Piper · baja calidad';

  @override
  String get modelsAutomatic => 'Automático';

  @override
  String get modelsAutomaticDesc =>
      'Usa el mejor modelo instalado para el libro';

  @override
  String get modelsLocalSection => 'En este dispositivo';

  @override
  String get modelsOnlineSection => 'En línea';

  @override
  String get modelsOnlineNeedsConsent =>
      'Activa «Permitir respaldo en línea» en Ajustes para usar voces en línea';

  @override
  String get modelsNotInstalled => 'Toca para descargar y usar';

  @override
  String get modelsEmpty => 'No hay modelos disponibles para este dispositivo';

  @override
  String get modelsLoadFailed => 'No se pudo cargar la lista de modelos';

  @override
  String modelsRowSubtitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count modelos',
      one: '1 modelo',
    );
    return '$_temp0';
  }

  @override
  String modelsMissingTitle(String language) {
    return 'Sin modelo de narración para $language';
  }

  @override
  String get modelsMissingBody =>
      'Instala un modelo de narración para este idioma e inténtalo de nuevo.';

  @override
  String get modelsMissingAction => 'Abrir Modelos';

  @override
  String bookLanguagesMissingModels(String languages) {
    return 'Este libro también tiene pasajes en $languages. No hay voz instalada para ellos, así que se leerán con la voz principal.';
  }

  @override
  String get convertChooseFile => 'Elegir EPUB o PDF';

  @override
  String get convertEngine => 'Motor';

  @override
  String get convertVoice => 'Voz';

  @override
  String get convertLanguage => 'Idioma';

  @override
  String get convertLanguagePortuguese => 'Portugués';

  @override
  String get convertLanguageEnglish => 'Inglés';

  @override
  String get convertLanguageSpanish => 'Español';

  @override
  String get convertChapterRange => 'Rango de capítulos';

  @override
  String get convertChapterFrom => 'Desde';

  @override
  String get convertChapterTo => 'Hasta';

  @override
  String get convertOptions => 'Opciones';

  @override
  String get convertOptionsManagedLocally =>
      'Las opciones de portada y de procesamiento de audio las define el conversor local.';

  @override
  String get convertIncludeCover => 'Incluir portada';

  @override
  String get convertNormalizeAudio => 'Normalizar audio';

  @override
  String get convertStart => 'Iniciar conversión';

  @override
  String get tocDownloadAll => 'Descargar sin conexión';

  @override
  String get tocCancelDownloads => 'Cancelar descargas';

  @override
  String get tocRetryFailed => 'Reintentar capítulos fallidos';

  @override
  String get tocShareAudio => 'Compartir audio disponible';

  @override
  String get tocRemoveDownloads => 'Quitar descargas';

  @override
  String get tocRemoveDownloadsMessage =>
      'Se eliminarán todos los MP3 descargados de este libro.';

  @override
  String get tocAudioReady => 'Audio listo';

  @override
  String get tocAudioConverting => 'Convirtiendo audio';

  @override
  String get tocAudioFailed => 'Falló el audio';

  @override
  String get readerHighlight => 'Resaltar';

  @override
  String get readerAddNote => 'Agregar nota';

  @override
  String get readerRemoveHighlight => 'Eliminar resaltado';

  @override
  String get readerPassageLanguage => 'Idioma del pasaje';

  @override
  String libraryMetaProgress(int percent, int current, int total) {
    return '$percent% · cap. $current de $total';
  }

  @override
  String get libraryMetaAudioNone => 'Sin convertir';

  @override
  String libraryMetaAudioPartial(int done, int total) {
    return 'Audio $done de $total';
  }

  @override
  String get libraryMetaAudioComplete => 'Audio completo';

  @override
  String libraryMetaPages(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count páginas',
      one: '1 página',
    );
    return '$_temp0';
  }

  @override
  String libraryMetaChapters(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count capítulos',
      one: '1 capítulo',
    );
    return '$_temp0';
  }

  @override
  String libraryMetaAdded(String date) {
    return 'Añadido $date';
  }

  @override
  String libraryMetaLastRead(String date) {
    return 'Leído $date';
  }
}
