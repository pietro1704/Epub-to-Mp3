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
  String get settingsTitle => 'Configurações';

  @override
  String get backendUrl => 'URL do servidor';

  @override
  String get wpmLabel => 'Palavras por minuto';

  @override
  String get audioRateLabel => 'Velocidade de reprodução';

  @override
  String get fontSizeLabel => 'Tamanho da fonte';

  @override
  String get themeLabel => 'Tema';

  @override
  String get jobsTitle => 'Conversões';

  @override
  String get noJobs => 'Nenhuma conversão ainda';

  @override
  String get refresh => 'Atualizar';

  @override
  String get playerTitle => 'Reprodutor';

  @override
  String get readerTitle => 'Leitor';

  @override
  String get tocTitle => 'Capítulos';

  @override
  String get loadingFulltext => 'Carregando texto…';

  @override
  String get fulltextEmpty => 'Texto não disponível';

  @override
  String get fulltextGone => 'Texto não está mais disponível';

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
  String get libraryEmpty => 'Nenhum livro ainda';

  @override
  String get addBook => 'Adicionar livro';

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
  String get noConversionYet => 'Converta este livro antes de reproduzir áudio';

  @override
  String get readerEmptyHint =>
      'Abra um livro da biblioteca para começar a ler';

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
  String get generatingAudio => 'Gerando áudio';

  @override
  String get nowPlaying => 'Reproduzindo';

  @override
  String get audioEngineSection => 'Motor de áudio';

  @override
  String get useBuiltInEngine => 'Usar motor de áudio integrado';

  @override
  String get useBuiltInEngineDesc =>
      'Sintetiza capítulos neste dispositivo. Sem servidor necessário.';

  @override
  String get audioEngineFooter =>
      'A leitura funciona offline de qualquer forma — isso afeta apenas a geração de áudio.';

  @override
  String get remoteBackendSection => 'Servidor remoto';

  @override
  String get backendUrlHint => 'http://localhost:8000';

  @override
  String get backendUrlFooter =>
      'Aponte para um servidor local ou URL do Hugging Face Space.';

  @override
  String get fontLabel => 'Fonte';

  @override
  String get layoutLabel => 'Layout';

  @override
  String get lineSpacingLabel => 'Espaçamento';

  @override
  String get marginLabel => 'Margem';

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
  String get projectOnGithub => 'Projeto no GitHub';

  @override
  String get readerPrefsFooter =>
      'Estas preferências se aplicam a todos os livros da biblioteca.';

  @override
  String get invalidUrl => 'URL inválida';

  @override
  String nOfSteps(int n, int total) {
    return '$n de $total';
  }

  @override
  String get sortBy => 'Ordenar por';

  @override
  String get sortLastOpened => 'Último aberto';

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
}
