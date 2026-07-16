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
  String get settingsTitle => 'Configuración';

  @override
  String get backendUrl => 'URL del servidor';

  @override
  String get wpmLabel => 'Palabras por minuto';

  @override
  String get audioRateLabel => 'Velocidad de reproducción';

  @override
  String get fontSizeLabel => 'Tamaño de fuente';

  @override
  String get themeLabel => 'Tema';

  @override
  String get jobsTitle => 'Conversiones';

  @override
  String get convertTitle => 'Convertir';

  @override
  String get noJobs => 'Ninguna conversión aún';

  @override
  String get refresh => 'Actualizar';

  @override
  String get playerTitle => 'Reproductor';

  @override
  String get readerTitle => 'Lector';

  @override
  String get tocTitle => 'Capítulos';

  @override
  String get loadingFulltext => 'Cargando texto…';

  @override
  String get fulltextEmpty => 'Texto no disponible';

  @override
  String get fulltextGone => 'Texto ya no disponible';

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
  String get noConversionYet =>
      'Convierte este libro primero para reproducir audio';

  @override
  String get readerEmptyHint =>
      'Abre un libro de la biblioteca para empezar a leer';

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
  String get generatingAudio => 'Generando audio';

  @override
  String get nowPlaying => 'Reproduciendo';

  @override
  String get audioEngineSection => 'Motor de audio';

  @override
  String get useBuiltInEngine => 'Usar motor de audio integrado';

  @override
  String get useBuiltInEngineDesc =>
      'Sintetiza capítulos en este dispositivo. Sin servidor necesario.';

  @override
  String get audioEngineFooter =>
      'La lectura funciona sin conexión de cualquier forma — esto solo afecta la generación de audio.';

  @override
  String get remoteBackendSection => 'Servidor remoto';

  @override
  String get backendUrlHint => 'http://localhost:8000';

  @override
  String get backendUrlFooter =>
      'Apunta a un servidor local o URL de Hugging Face Space.';

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
  String get projectOnGithub => 'Proyecto en GitHub';

  @override
  String get readerPrefsFooter =>
      'Estas preferencias se aplican a todos los libros de tu biblioteca.';

  @override
  String get invalidUrl => 'URL no válida';

  @override
  String nOfSteps(int n, int total) {
    return '$n de $total';
  }

  @override
  String get sortBy => 'Ordenar por';

  @override
  String get sortLastOpened => 'Último abierto';

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
  String get startingConversion => 'Iniciando conversión…';

  @override
  String get conversionFailed => 'Falló la conversión';

  @override
  String get uploadFailed => 'Falló la carga';

  @override
  String get downloading => 'Descargando…';

  @override
  String get downloadComplete => 'Descarga completa';

  @override
  String get downloadFailed => 'Falló la descarga';

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
  String charsCount(int n) {
    return '$n caracteres';
  }

  @override
  String get searchInBook => 'Buscar en el libro';

  @override
  String get noResults => 'Sin resultados';

  @override
  String get done => 'Listo';

  @override
  String get searchResultsCapped => 'Mostrando los primeros 100 resultados';

  @override
  String get sortLibrary => 'Ordenar biblioteca';

  @override
  String get skipBack15 => 'Retroceder 15 segundos';

  @override
  String get skipForward15 => 'Adelantar 15 segundos';

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
  String get readerSettings => 'Configuración del lector';

  @override
  String get audioReady => 'Audio listo';

  @override
  String get currentlyPlaying => 'Reproduciendo ahora';

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
  String get bookmarkRemoved => 'Marcador eliminado';

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
  String get chapterListTitle => 'Capítulos';

  @override
  String get sleepTimerActive => 'Temporizador activo';

  @override
  String get sleepTimerOff => 'Temporizador apagado';

  @override
  String get speedLabel => 'Velocidad';

  @override
  String sleepMinutes(int n) {
    return '$n min';
  }

  @override
  String get off => 'Apagado';
}
