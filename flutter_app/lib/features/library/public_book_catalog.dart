import 'public_book_download.dart';

class PublicBook {
  const PublicBook({
    required this.title,
    required this.author,
    required this.language,
    required this.source,
    this.sourcePage,
    this.epub,
    this.pdf,
  }) : assert(epub != null || pdf != null);

  final String title;
  final String author;
  final String language;
  final String source;
  final String? sourcePage;
  final String? epub;
  final String? pdf;

  PublicBookFormat get format =>
      epub != null ? PublicBookFormat.epub : PublicBookFormat.pdf;
  Uri get downloadUri => Uri.parse(epub ?? pdf!);
}

List<PublicBook> searchPublicBooks(String query, String preferredLanguage) {
  final terms = _searchText(query)
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty);
  final results = _publicBooks.where((book) {
    final searchable = _searchText('${book.title} ${book.author}');
    return terms.every(searchable.contains);
  });
  return [
    ...results.where((book) => book.language == preferredLanguage),
    ...results.where((book) => book.language != preferredLanguage),
  ];
}

String _searchText(String text) => text
    .toLowerCase()
    .replaceAll(RegExp('[àáâãä]'), 'a')
    .replaceAll(RegExp('[èéêë]'), 'e')
    .replaceAll(RegExp('[ìíîï]'), 'i')
    .replaceAll(RegExp('[òóôõö]'), 'o')
    .replaceAll(RegExp('[ùúûü]'), 'u')
    .replaceAll('ç', 'c');

const _gutenberg = 'Project Gutenberg';
const _camara = 'Edições Câmara';

// Titles and acquisition links come from the original catalog records.
final _publicBooks = [
  PublicBook(
    title: 'Alice\'s Adventures in Wonderland',
    author: 'Lewis Carroll',
    language: 'en',
    source: _gutenberg,
    sourcePage: 'https://www.gutenberg.org/ebooks/11',
    epub: gutenbergEpubUrls[11],
  ),
  PublicBook(
    title: 'Pride and Prejudice',
    author: 'Jane Austen',
    language: 'en',
    source: _gutenberg,
    sourcePage: 'https://www.gutenberg.org/ebooks/1342',
    epub: gutenbergEpubUrls[1342],
  ),
  PublicBook(
    title: 'Adventures of Huckleberry Finn',
    author: 'Mark Twain',
    language: 'en',
    source: _gutenberg,
    sourcePage: 'https://www.gutenberg.org/ebooks/76',
    epub: gutenbergEpubUrls[76],
  ),
  PublicBook(
    title: 'Papéis Avulsos',
    author: 'Machado de Assis',
    language: 'pt',
    source: _gutenberg,
    sourcePage: 'https://www.gutenberg.org/ebooks/57001',
    epub: gutenbergEpubUrls[57001],
  ),
  const PublicBook(
    title: 'Dom Casmurro',
    author: 'Machado de Assis',
    language: 'pt',
    source: _camara,
    sourcePage: 'https://livraria.camara.leg.br/produto/dom-casmurro/',
    epub: 'https://bd-rest.camara.leg.br/server/api/core/bitstreams/2b30f5a5-5e5f-49fd-9db7-f4a6c31c457f/content',
    pdf: 'https://bd-rest.camara.leg.br/server/api/core/bitstreams/8835c1ee-9566-4465-bc91-ce7003a6d4de/content',
  ),
];
