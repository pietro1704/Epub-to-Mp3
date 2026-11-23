// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get appTitle => 'Epub para MP3';

  @override
  String get convertTitle => 'Converter';

  @override
  String get settingsTitle => 'Configurações';

  @override
  String get wpmLabel => 'Palavras por minuto';

  @override
  String get audioRateLabel => 'Velocidade de reprodução';

  @override
  String get readingPreferencesTitle => 'Preferências de leitura';

  @override
  String get readingModeDefault => 'Padrão para todos os livros';

  @override
  String get readingModeBook => 'Só para este livro';

  @override
  String get readingUseDefault => 'Usar o padrão';

  @override
  String get readingSpeedLabel => 'Velocidade da narração';

  @override
  String get readingBookHint => 'Estas escolhas valem só para este livro.';

  @override
  String get readerLayoutScrolling => 'Rolagem';

  @override
  String get readerLayoutPaginated => 'Paginado';

  @override
  String get fontSizeLabel => 'Tamanho da fonte';

  @override
  String get themeLabel => 'Tema';

  @override
  String get jobsTitle => 'Conversões';

  @override
  String get noJobs => 'Nenhuma conversão ainda';

  @override
  String get conversionLogTitle => 'Registro da conversão';

  @override
  String get conversionJobLabel => 'Conversão';

  @override
  String get conversionLastRecordedState => 'Último estado registrado';

  @override
  String conversionLastRecordedStateValue(String state) {
    return 'Último estado registrado: $state';
  }

  @override
  String get conversionLastUpdated => 'Última atualização';

  @override
  String conversionRecordedAudioPath(String path) {
    return 'Caminho registrado do áudio: $path';
  }

  @override
  String conversionUnreadableRecords(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Não foi possível ler $count registros de conversão salvos.',
      one: 'Não foi possível ler 1 registro de conversão salvo.',
    );
    return '$_temp0';
  }

  @override
  String get conversionStatusPending => 'Pendente';

  @override
  String get conversionStatusRunning => 'Convertendo';

  @override
  String get conversionStatusCompleted => 'Concluída';

  @override
  String get conversionStatusFailed => 'Falhou';

  @override
  String get conversionStatusCancelled => 'Cancelada';

  @override
  String get conversionStatusUnknown => 'Desconhecido';

  @override
  String conversionHistorySaveWarning(String error) {
    return 'Conversão concluída, mas não foi possível salvar o histórico: $error';
  }

  @override
  String get refresh => 'Atualizar';

  @override
  String get readerTitle => 'Leitor';

  @override
  String get tocTitle => 'Capítulos';

  @override
  String get downloadAll => 'Baixar tudo';

  @override
  String get play => 'Reproduzir';

  @override
  String get pause => 'Pausar';

  @override
  String get next => 'Próximo';

  @override
  String get previous => 'Anterior';

  @override
  String get libraryTitle => 'Biblioteca';

  @override
  String get libraryEmpty => 'Sua biblioteca está vazia';

  @override
  String get addBook => 'Adicionar livro';

  @override
  String get importBookFile => 'Importar arquivo EPUB ou PDF';

  @override
  String get searchPublicBooks => 'Buscar livros clássicos';

  @override
  String get publicBookDownloadFailed =>
      'Não foi possível baixar ou importar este livro. Tente novamente.';

  @override
  String get publicBookSourceOpenFailed =>
      'Não foi possível abrir a página da editora.';

  @override
  String get removeBookTitle => 'Remover livro';

  @override
  String removeBookMessage(String title) {
    return 'Remover \"$title\" da biblioteca? O arquivo não será excluído.';
  }

  @override
  String get cancel => 'Cancelar';

  @override
  String get remove => 'Remover';

  @override
  String get pickBookToRead => 'Escolha um livro para ler';

  @override
  String get browseLibrary => 'Ver Biblioteca';

  @override
  String get parsingBook => 'Abrindo livro…';

  @override
  String get parsingFailed => 'Não foi possível abrir este livro';

  @override
  String get retry => 'Tentar novamente';

  @override
  String get audioEngineSection => 'Motor de áudio';

  @override
  String get useBuiltInEngineDesc =>
      'Sintetiza capítulos neste dispositivo. Sem servidor necessário.';

  @override
  String get fontLabel => 'Fonte';

  @override
  String get layoutLabel => 'Layout';

  @override
  String get lineSpacingLabel => 'Espaçamento';

  @override
  String get marginLabel => 'Margem';

  @override
  String get readerShowPageNumbers => 'Mostrar números de página';

  @override
  String get readerAlignmentLabel => 'Alinhamento';

  @override
  String get readerAlignmentJustified => 'Justificado';

  @override
  String get readerAlignmentLeft => 'Esquerda';

  @override
  String get autoScrollLabel => 'Rolagem automática';

  @override
  String get autoScrollDesc => 'Rolar texto para acompanhar a reprodução';

  @override
  String get playbackSection => 'Reprodução';

  @override
  String get aboutSection => 'Sobre';

  @override
  String get platformLabel => 'Plataforma';

  @override
  String get readerPrefsFooter =>
      'Estas preferências se aplicam a todos os livros da biblioteca.';

  @override
  String nOfSteps(int n, int total) {
    return '$n de $total';
  }

  @override
  String get sortLastPlayed => 'Tocados recentemente';

  @override
  String get sortTitle => 'Título';

  @override
  String get sortDateAdded => 'Data de adição';

  @override
  String get libraryEmptyDesc =>
      'Toque em + para importar um EPUB ou PDF, ou compartilhe de outro app.';

  @override
  String get offlineReady => 'Offline';

  @override
  String get cachingLabel => 'Cacheando';

  @override
  String get removeFromLibrary => 'Remover da biblioteca';

  @override
  String get conversionFailed => 'Falha na conversão';

  @override
  String get bookLanguageUncertain =>
      'Não foi possível detectar o idioma do livro. Escolha o idioma em Converter e tente novamente.';

  @override
  String get downloading => 'Baixando…';

  @override
  String get downloadComplete => 'Download concluído';

  @override
  String chaptersConverted(int n, int total) {
    return '$n de $total capítulos';
  }

  @override
  String get drmFootnote =>
      'Livros com DRM (ex: Google Play ou Kindle) não podem ser abertos.';

  @override
  String get saveForOffline => 'Salvar';

  @override
  String get searchInBook => 'Buscar no livro';

  @override
  String get noResults => 'Nenhum resultado';

  @override
  String get done => 'Feito';

  @override
  String get searchResultsCapped => 'Mostrando os primeiros 100 resultados';

  @override
  String get sortLibrary => 'Ordenar biblioteca';

  @override
  String get playbackPosition => 'Posição de reprodução';

  @override
  String get playbackSpeed => 'Velocidade de reprodução';

  @override
  String get sleepTimer => 'Timer de sono';

  @override
  String get albumArt => 'Capa do álbum';

  @override
  String get closePlayer => 'Fechar reprodutor';

  @override
  String get tableOfContents => 'Índice';

  @override
  String get editTags => 'Editar Tags';

  @override
  String get tagsSection => 'Tags';

  @override
  String get newTagHint => 'Nova tag';

  @override
  String get add => 'Adicionar';

  @override
  String get existingTags => 'Tags existentes';

  @override
  String get allFilter => 'Todas';

  @override
  String get searchLibrary => 'Buscar na biblioteca';

  @override
  String get bookmarksTitle => 'Marcadores';

  @override
  String get filterAll => 'Todos';

  @override
  String get filterBookmarks => 'Marcadores';

  @override
  String get filterHighlights => 'Destaques';

  @override
  String get noBookmarksYet => 'Nenhum marcador ainda';

  @override
  String get noBookmarksHint =>
      'Pressione e segure um parágrafo no leitor para adicionar um marcador ou destaque.';

  @override
  String get editNote => 'Editar Nota';

  @override
  String get addNoteHint => 'Adicionar nota…';

  @override
  String get highlightedText => 'Texto destacado';

  @override
  String get colorLabel => 'Cor';

  @override
  String get save => 'Salvar';

  @override
  String get removeBookmarkTitle => 'Remover marcador';

  @override
  String get removeBookmarkMessage => 'Remover este marcador?';

  @override
  String get addBookmark => 'Adicionar marcador';

  @override
  String get bookmarkAdded => 'Marcador adicionado';

  @override
  String get sizeLabel => 'Tamanho';

  @override
  String get noContentAvailable => 'Nenhum conteúdo disponível';

  @override
  String errorWithMessage(String message) {
    return 'Erro: $message';
  }

  @override
  String get platformAndroid => 'Android';

  @override
  String get off => 'Desligado';

  @override
  String get ttsPrimaryNarration => 'Modelo de voz';

  @override
  String get ttsSecondaryNarration => 'Voz secundária';

  @override
  String get ttsFaberOffline => 'Faber medium · Sem internet';

  @override
  String get ttsAutomaticPiper => 'Piper · Idioma do livro';

  @override
  String get ttsDetectLanguage => 'Detectar pelo livro';

  @override
  String get ttsEdgeOnline => 'Edge · Online';

  @override
  String get ttsNoSecondary => 'Nenhuma';

  @override
  String get ttsSystemOffline => 'Voz do sistema · Alternativa offline';

  @override
  String get ttsUseRecommendedDefaults =>
      'Usar Piper no idioma do livro com voz do sistema como alternativa';

  @override
  String get ttsAllowOnlineSecondary => 'Permitir reserva online';

  @override
  String get ttsOnlineSecondaryDescription =>
      'Envie os trechos que falharem ao Edge somente quando esta opção estiver ativada.';

  @override
  String get ttsAutomaticSystemFallback =>
      'Voz do sistema como alternativa automática';

  @override
  String get ttsAutomaticSystemFallbackDescription =>
      'Se as vozes selecionadas falharem, tente uma voz instalada do sistema. Desative para usar apenas as vozes selecionadas.';

  @override
  String get ttsEngineSystem => 'Voz do sistema';

  @override
  String get ttsEnginePiper => 'Piper';

  @override
  String get ttsEngineEdge => 'Edge (online)';

  @override
  String get ttsVoiceBookLanguage => 'Idioma do livro';

  @override
  String get ttsVoiceSystem => 'Voz instalada no sistema';

  @override
  String get ttsVoiceEdge => 'Voz online';

  @override
  String get ttsUsePreferences => 'Usar preferências de áudio';

  @override
  String get ttsAllowJobSecondary =>
      'Permitir a voz secundária configurada nesta conversão';

  @override
  String ttsActualVoices(String voices) {
    return 'Voz utilizada: $voices';
  }

  @override
  String get ttsSecondaryUsedNotice =>
      'Usando a voz secundária. A voz principal será tentada novamente periodicamente.';

  @override
  String get platformVoiceNotice => 'Usando a voz do sistema neste trecho.';

  @override
  String get localAudioStorage => 'Áudio baixado no dispositivo';

  @override
  String get localAudioStorageHint =>
      'O áudio baixado e ouvido é mantido até você removê-lo.';

  @override
  String get removeAudioTitle => 'Remover o áudio baixado?';

  @override
  String get removeAudioMessage =>
      'O livro, a posição de leitura e as anotações serão mantidos.';

  @override
  String get originalTypography => 'Tipografia original do livro';

  @override
  String get seekForwardInterval => 'Avançar';

  @override
  String get seekBackwardInterval => 'Retroceder';

  @override
  String get ttsShowLowQuality => 'Mostrar qualidade baixa';

  @override
  String get ttsManualModelUnavailable =>
      'Não foi possível preparar este modelo de narração.';

  @override
  String get readerNarrationModel => 'Modelo de narração';

  @override
  String get readerFootnotes => 'Notas de rodapé';

  @override
  String get openReaderAtPlayback => 'Abrir no leitor';

  @override
  String get readerAppearance => 'Aparência do texto';

  @override
  String get readerPlayFromHere => 'Tocar daqui';

  @override
  String get errorNoReadableText =>
      'Não foi possível extrair texto legível deste livro.';

  @override
  String get errorEngineUnavailable =>
      'O conversor de voz está indisponível. Reinstale o app ou tente novamente.';

  @override
  String get errorModelMissing =>
      'O modelo de narração selecionado não está instalado. Instale-o nos Ajustes.';

  @override
  String get errorModelLanguage =>
      'Este modelo não suporta o idioma deste livro. Escolha um modelo compatível.';

  @override
  String get errorUnsupportedEngine =>
      'O mecanismo de voz selecionado não é compatível.';

  @override
  String get errorSpeechTimeout =>
      'A voz demorou demais para responder. Tente novamente.';

  @override
  String get errorNetwork =>
      'Não foi possível conectar. Verifique a conexão e tente novamente.';

  @override
  String get errorRateLimited =>
      'O serviço de voz está ocupado. Tente novamente em instantes.';

  @override
  String get errorInputUnreadable =>
      'Não foi possível ler este livro. O arquivo pode estar danificado.';

  @override
  String get errorUnsupportedInput => 'Este tipo de arquivo não é compatível.';

  @override
  String get errorConversionGeneric =>
      'Não foi possível converter o livro em áudio. Tente novamente. Os detalhes técnicos estão nos logs.';

  @override
  String get errorEdgeConsentRequired =>
      'As vozes online do Edge precisam da sua permissão. Ative “Permitir reserva online” em Ajustes ou escolha uma voz local e tente novamente.';

  @override
  String get modelsTitle => 'Modelos';

  @override
  String get modelsSubtitle => 'Escolha a narração de cada idioma de livro';

  @override
  String get modelsAutomatic => 'Automático';

  @override
  String get modelsAutomaticDesc =>
      'Usa o melhor modelo instalado para o livro';

  @override
  String get modelsLocalSection => 'Neste dispositivo';

  @override
  String get modelsOnlineSection => 'Online';

  @override
  String get modelsOnlineNeedsConsent =>
      'Ative “Permitir reserva online” em Ajustes para usar vozes online';

  @override
  String get modelsNotInstalled => 'Toque para baixar e usar';

  @override
  String get modelsEmpty => 'Nenhum modelo disponível para este dispositivo';

  @override
  String get modelsLoadFailed => 'Não foi possível carregar a lista de modelos';

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
    return 'Sem modelo de narração para $language';
  }

  @override
  String get modelsMissingBody =>
      'Instale um modelo de narração para este idioma e tente novamente.';

  @override
  String get modelsMissingAction => 'Abrir Modelos';
}
