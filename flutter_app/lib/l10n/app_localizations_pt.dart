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
}
