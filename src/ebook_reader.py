"""
src/ebook_reader.py

Classes para leitura e processamento de arquivos EPUB e PDF.
VERSÃO com leitura de toc.ncx e notas de rodapé inline.
"""

import re
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import List, Tuple, Union, Optional, Dict
from abc import ABC, abstractmethod

import ebooklib
from ebooklib import epub
from bs4 import BeautifulSoup

# Importando do config
from config import CHAPTER_PATTERNS, SUBTITLE_PATTERNS

try:
    import PyPDF2
    from PyPDF2 import PdfReader
except ImportError:
    PyPDF2 = None


class BaseEbookReader(ABC):
    """Interface base para leitores de ebook."""
    
    @abstractmethod
    def read(self, file_path: Path) -> Tuple[str, Optional[str], List[Tuple[str, str]]]:
        """
        Lê um arquivo de ebook.
        
        Returns:
            Tupla com (título, autor, lista_de_capítulos)
        """
        pass


class EPUBReader(BaseEbookReader):
    """Leitor especializado para arquivos EPUB com leitura de toc.ncx e notas inline."""
    
    def __init__(self):
        """Inicializa o leitor EPUB."""
        self.book = None  # Para acessar outros arquivos do EPUB
    
    def read(self, file_path: Path) -> Tuple[str, Optional[str], List[Tuple[str, str]]]:
        """Lê arquivo EPUB e extrai metadados e capítulos."""
        print(f"[INFO] Lendo arquivo EPUB: '{file_path.name}'")
        
        try:
            self.book = epub.read_epub(str(file_path))
        except Exception as e:
            raise RuntimeError(f"Erro ao ler EPUB: {e}")
        
        # Extrai metadados
        title = self._extract_title(self.book, file_path)
        author = self._extract_author(self.book)
        
        # Tenta extrair capítulos do toc.ncx primeiro
        chapters = self._extract_chapters_from_ncx(self.book)
        
        if not chapters:
            print("[INFO] Não encontrou capítulos no toc.ncx, usando spine...")
            chapters = self._extract_chapters(self.book)
        
        if not chapters:
            print("[AVISO] Não encontrou capítulos via spine, tentando todos os documentos...")
            chapters = self._extract_all_documents(self.book)
        
        return title, author, chapters
    
    def _extract_title(self, book, file_path: Path) -> str:
        """Extrai título do EPUB."""
        titles = book.get_metadata('DC', 'title')
        if titles:
            return titles[0][0]
        return file_path.stem
    
    def _extract_author(self, book) -> Optional[str]:
        """Extrai autor do EPUB."""
        creators = book.get_metadata('DC', 'creator')
        if creators:
            return creators[0][0]
        return None
    
    def _extract_chapters_from_ncx(self, book) -> List[Tuple[str, str]]:
        """
        Extrai capítulos usando toc.ncx (índice do EPUB).
        
        Returns:
            Lista de tuplas (título_capítulo, texto) ou lista vazia se falhar
        """
        try:
            # Procura pelo toc.ncx
            ncx_item = None
            for item in book.get_items():
                if item.get_name().endswith('toc.ncx'):
                    ncx_item = item
                    break
            
            if not ncx_item:
                print("[INFO] toc.ncx não encontrado")
                return []
            
            # Parse do XML
            ncx_content = ncx_item.get_content()
            root = ET.fromstring(ncx_content)
            
            # Namespace do NCX
            ns = {'ncx': 'http://www.daisy.org/z3986/2005/ncx/'}
            
            # Extrai navPoints
            nav_points = root.findall('.//ncx:navPoint', ns)
            if not nav_points:
                print("[INFO] Nenhum navPoint encontrado no toc.ncx")
                return []
            
            print(f"[INFO] Encontrados {len(nav_points)} navPoints no toc.ncx")
            
            # Processa navPoints e mapeia para arquivos
            chapters_info = []
            for nav_point in nav_points:
                title, src_file = self._extract_navpoint_info(nav_point, ns)
                if title and src_file:
                    chapters_info.append((title, src_file))
            
            # Filtra capítulos válidos (ignora páginas técnicas)
            valid_chapters = []
            for title, src_file in chapters_info:
                if self._is_valid_chapter_title(title):
                    valid_chapters.append((title, src_file))
            
            print(f"[INFO] {len(valid_chapters)} capítulos válidos encontrados no toc.ncx")
            
            if not valid_chapters:
                print("[INFO] Nenhum capítulo válido no toc.ncx")
                return []
            
            # Se só tem números, não vale a pena usar toc.ncx
            if self._all_numeric_titles(valid_chapters):
                print("[INFO] Títulos do toc.ncx são só números, usando parser HTML")
                return []
            
            # Extrai conteúdo dos arquivos
            chapters = []
            for title, src_file in valid_chapters:
                text = self._extract_text_from_file(book, src_file)
                if text and len(text.strip()) > 50:
                    chapters.append((title, text))
            
            print(f"[INFO] ✅ Usando toc.ncx: {len(chapters)} capítulos extraídos")
            return chapters
            
        except Exception as e:
            print(f"[WARN] Erro ao processar toc.ncx: {e}")
            return []
    
    def _extract_navpoint_info(self, nav_point, ns) -> Tuple[Optional[str], Optional[str]]:
        """Extrai título e arquivo de um navPoint."""
        try:
            # Título
            nav_label = nav_point.find('ncx:navLabel/ncx:text', ns)
            title = nav_label.text.strip() if nav_label is not None else None
            
            # Arquivo
            content_elem = nav_point.find('ncx:content', ns)
            src_file = content_elem.get('src') if content_elem is not None else None
            
            # Remove âncoras (#) do arquivo
            if src_file and '#' in src_file:
                src_file = src_file.split('#')[0]
            
            return title, src_file
            
        except Exception:
            return None, None
    
    def _is_valid_chapter_title(self, title: str) -> bool:
        """Verifica se título é válido para capítulo (não página técnica)."""
        if not title:
            return False
        
        # Ignora páginas técnicas
        technical_pages = [
            'cover', 'title', 'copyright', 'contents', 'toc', 'table of contents',
            'acknowledgments', 'dedication', 'preface', 'introduction',
            'page list', 'plates', 'index', 'bibliography', 'about',
            'capa', 'título', 'direitos', 'sumário', 'índice', 'sobre',
            'página de título', 'folha de rosto', 'agradecimentos'
        ]
        
        title_lower = title.lower().strip()
        for tech in technical_pages:
            if tech in title_lower:
                return False
        
        return True
    
    def _all_numeric_titles(self, chapters_info: List[Tuple[str, str]]) -> bool:
        """Verifica se todos os títulos são só números."""
        numeric_count = 0
        for title, _ in chapters_info:
            if title.strip().isdigit() or re.match(r'^\d+\.?\s*$', title.strip()):
                numeric_count += 1
        
        # Se 80% ou mais são só números, considera como numérico
        return numeric_count >= len(chapters_info) * 0.8
    
    def _extract_text_from_file(self, book, src_file: str) -> Optional[str]:
        """Extrai texto de um arquivo específico do EPUB."""
        try:
            # Procura o item pelo nome do arquivo
            for item in book.get_items():
                if item.get_type() == ebooklib.ITEM_DOCUMENT:
                    item_name = item.get_name()
                    # Compara nome exato ou final do caminho
                    if (item_name == src_file or 
                        item_name.endswith(src_file) or 
                        src_file.endswith(item_name.split('/')[-1])):
                        
                        _, text = self._extract_text_from_html(item.get_content())
                        return text
            
            print(f"[WARN] Arquivo não encontrado: {src_file}")
            return None
            
        except Exception as e:
            print(f"[WARN] Erro ao extrair texto de {src_file}: {e}")
            return None
    
    def _extract_chapters(self, book) -> List[Tuple[str, str]]:
        """Extrai capítulos usando spine do EPUB."""
        chapters = []
        
        for idx, (idref, _) in enumerate(book.spine, start=1):
            item = book.get_item_with_id(idref)
            if item and item.get_type() == ebooklib.ITEM_DOCUMENT:
                title, text = self._extract_text_from_html(item.get_content())
                if text and len(text.strip()) > 50:
                    chapter_title = title or f"Capítulo {idx}"
                    chapters.append((chapter_title, text))
        
        return chapters
    
    def _extract_all_documents(self, book) -> List[Tuple[str, str]]:
        """Extrai todos os documentos como capítulos."""
        chapters = []
        
        for item in book.get_items_of_type(ebooklib.ITEM_DOCUMENT):
            title, text = self._extract_text_from_html(item.get_content())
            if text and len(text.strip()) > 50:
                chapter_title = title or f"Capítulo {len(chapters) + 1}"
                chapters.append((chapter_title, text))
        
        return chapters
    
    def _extract_text_from_html(self, html_bytes: bytes) -> Tuple[Optional[str], str]:
        """Extrai título e texto limpo do HTML com notas de rodapé inline."""
        soup = BeautifulSoup(html_bytes, "html.parser")
        title = self._extract_html_title(soup)
        
        # Remove scripts e estilos
        for bad in soup(["script", "style"]):
            bad.decompose()
        
        # Processa notas de rodapé ANTES de extrair texto
        self._process_footnotes_inline(soup)
        
        text_elements = []
        self._extract_recursive(soup.body if soup.body else soup, text_elements)
        
        if not text_elements:
            all_text = soup.get_text(" ", strip=True)
            if all_text:
                text_elements = [('text', all_text, 0)]
        
        # Processa elementos para criar texto final
        final_text = self._process_text_elements(text_elements)
        
        return title, final_text
    
    def _process_footnotes_inline(self, soup: BeautifulSoup) -> None:
        """
        Processa notas de rodapé e as insere inline no texto.
        """
        footnote_count = 0
        
        # Padrões de links para notas de rodapé
        footnote_patterns = [
            r'footnote-\d+',
            r'note-\d+',
            r'fn\d+',
            r'endnote-\d+',
            r'nota-\d+',
        ]
        
        # Encontra todos os links que parecem ser notas de rodapé
        footnote_links = []
        
        for link in soup.find_all('a', href=True):
            href = link.get('href', '')
            link_text = link.get_text(strip=True)
            
            # Verifica se parece ser uma nota de rodapé
            is_footnote = False
            
            # Por padrão de href
            for pattern in footnote_patterns:
                if re.search(pattern, href):
                    is_footnote = True
                    break
            
            # Por texto do link (números entre colchetes/parênteses ou superscript)
            if not is_footnote and re.match(r'^[\[\(]?\d+[\]\)]?$', link_text):
                is_footnote = True
            
            # Por posição em sup
            if not is_footnote and link.parent and link.parent.name == 'sup':
                is_footnote = True
            
            if is_footnote:
                footnote_links.append(link)
        
        print(f"[INFO] Encontrados {len(footnote_links)} links de notas de rodapé")
        
        # Processa cada link de nota
        for link in footnote_links:
            footnote_count += 1
            self._process_single_footnote(soup, link, footnote_count)
        
        # Remove seções de notas de rodapé para não duplicar
        self._remove_footnote_sections(soup)
    
    def _process_single_footnote(self, soup: BeautifulSoup, link, footnote_number: int) -> None:
        """Processa uma única nota de rodapé."""
        try:
            href = link.get('href', '')
            link_text = link.get_text(strip=True)
            
            # Encontra a nota de rodapé correspondente
            footnote_content = self._find_footnote_content(soup, href, link)
            
            if footnote_content:
                # Cria texto da nota inline
                inline_note = f" -- nota de rodapé número {footnote_number}: {footnote_content} -- fim da nota -- "
                
                # Substitui o link pela nota inline
                new_span = soup.new_tag('span')
                new_span.string = inline_note
                new_span['class'] = 'inline-footnote'
                
                link.replace_with(new_span)
                
            else:
                # Se não encontrou a nota, mantém só o marcador
                link.replace_with(f" [nota {footnote_number}] ")
                
        except Exception as e:
            print(f"[WARN] Erro ao processar nota de rodapé: {e}")
            # Em caso de erro, remove o link mas mantém o texto
            link_text = link.get_text(strip=True)
            link.replace_with(f" [nota {link_text}] ")
    
    def _find_footnote_content(self, soup: BeautifulSoup, href: str, link) -> Optional[str]:
        """
        Encontra o conteúdo da nota de rodapé correspondente.
        
        Args:
            soup: Soup da página atual
            href: Link href da nota
            link: Elemento do link
            
        Returns:
            Texto da nota de rodapé ou None se não encontrar
        """
        try:
            # Remove # do href se presente
            anchor_id = href.split('#')[-1] if '#' in href else href
            
            # Procura por ID exato
            footnote_elem = soup.find(id=anchor_id)
            if footnote_elem:
                content = self._extract_footnote_text(footnote_elem)
                if content:
                    return content
            
            # Procura por classes comuns de notas
            footnote_classes = ['footnote', 'note', 'endnote', 'texto-de-nota-de-rodap', 'footnotes']
            
            for class_name in footnote_classes:
                elements = soup.find_all(class_=lambda x: x and class_name in str(x).lower())
                for elem in elements:
                    # Verifica se tem o ID ou link de volta
                    if anchor_id in str(elem):
                        content = self._extract_footnote_text(elem)
                        if content:
                            return content
            
            # Se for link para outro arquivo, tenta procurar no EPUB
            if self.book and '#' not in href:
                return self._find_footnote_in_other_file(href)
            
            return None
            
        except Exception as e:
            print(f"[WARN] Erro ao buscar conteúdo da nota: {e}")
            return None
    
    def _extract_footnote_text(self, elem) -> Optional[str]:
        """Extrai texto limpo de um elemento de nota de rodapé."""
        if not elem:
            return None
        
        # Remove links de volta (backlinks)
        for backlink in elem.find_all('a'):
            href = backlink.get('href', '')
            if 'backlink' in href or backlink.get_text(strip=True) in ['↩', '←', '▲']:
                backlink.decompose()
        
        # Remove numeração da nota se presente
        text = elem.get_text(strip=True)
        
        # Remove padrões comuns de numeração
        text = re.sub(r'^\[?\d+\]?\s*', '', text)  # [1] ou 1. no início
        text = re.sub(r'^\d+\.\s*', '', text)      # 1. no início
        text = re.sub(r'^\d+\s+', '', text)        # 1 no início
        
        return text.strip() if text.strip() else None
    
    def _find_footnote_in_other_file(self, filename: str) -> Optional[str]:
        """Procura nota de rodapé em outro arquivo do EPUB."""
        try:
            for item in self.book.get_items():
                if (item.get_type() == ebooklib.ITEM_DOCUMENT and 
                    filename in item.get_name()):
                    
                    note_soup = BeautifulSoup(item.get_content(), "html.parser")
                    
                    # Procura primeira nota encontrada (simplificado)
                    for elem in note_soup.find_all(['p', 'div']):
                        if any(cls in str(elem.get('class', '')) 
                               for cls in ['footnote', 'note', 'endnote']):
                            content = self._extract_footnote_text(elem)
                            if content:
                                return content
                    
                    break
            
            return None
            
        except Exception:
            return None
    
    def _remove_footnote_sections(self, soup: BeautifulSoup) -> None:
        """Remove seções de notas de rodapé para evitar duplicação."""
        # Classes e IDs comuns de seções de notas
        footnote_selectors = [
            {'class': 'footnotes'},
            {'class': 'endnotes'},
            {'class': 'notes'},
            {'class': lambda x: x and 'footnote' in str(x).lower()},
            {'id': lambda x: x and 'footnote' in str(x).lower()},
        ]
        
        removed_count = 0
        
        for selector in footnote_selectors:
            elements = soup.find_all(['div', 'section', 'aside'], **selector)
            for elem in elements:
                elem.decompose()
                removed_count += 1
        
        if removed_count > 0:
            print(f"[INFO] Removidas {removed_count} seções de notas de rodapé")
    
    def _extract_html_title(self, soup: BeautifulSoup) -> Optional[str]:
        """Extrai título do HTML com detecção inteligente de padrões."""
        
        # 1. Título tradicional da página
        if soup.title and soup.title.string:
            title = soup.title.string.strip()
            if title and not self._is_generic_title(title):
                return title
        
        # 2. Headers tradicionais (h1-h6)
        for tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
            h = soup.find(tag)
            if h and h.get_text(strip=True):
                title = h.get_text(strip=True)
                if not self._is_generic_title(title):
                    return title
        
        # 3. Spans e divs com classes comuns de título
        title_classes = [
            'title', 'chapter-title', 'chapter-name', 'chapter-header',
            't5', 't1', 't2', 't3', 't4', 't6', 't7', 't8', 't9', 't10',  # Classes numéricas comuns
            'heading', 'header', 'caption', 'chapter', 'book-title',
            'chapter_title', 'chaptertitle', 'titulo', 'cap-title'
        ]
        
        for class_name in title_classes:
            # Procura por class exata
            element = soup.find(['span', 'div', 'p'], class_=class_name)
            if element:
                title = element.get_text(strip=True)
                if title and self._looks_like_title(title):
                    return title
            
            # Procura por class que contém o padrão
            elements = soup.find_all(['span', 'div', 'p'], 
                                   class_=lambda x: x and class_name in str(x).lower())
            for element in elements:
                title = element.get_text(strip=True)
                if title and self._looks_like_title(title):
                    return title
        
        # 4. Primeiro texto em maiúsculo que parece título
        all_elements = soup.find_all(['p', 'div', 'span'])
        for element in all_elements[:10]:  # Verifica primeiros 10 elementos
            text = element.get_text(strip=True)
            if text and self._looks_like_chapter_title(text):
                return text
        
        # 5. Procura por padrões específicos de capítulo
        chapter_patterns = [
            r'^(CAPÍTULO|Capítulo|CHAPTER|Chapter)\s+(.+)$',
            r'^(\d+)\.\s*(.+)$',  # "2. Título"
            r'^([IVX]+)\.\s*(.+)$',  # "II. Título"
            r'^(.{5,50})$'  # Texto curto que pode ser título
        ]
        
        for element in all_elements[:15]:
            text = element.get_text(strip=True)
            if not text:
                continue
                
            for pattern in chapter_patterns:
                match = re.match(pattern, text)
                if match:
                    # Se capturou grupos, usa o último (título sem prefixo)
                    if len(match.groups()) > 1:
                        potential_title = match.group(-1).strip()
                    else:
                        potential_title = text
                        
                    if self._looks_like_title(potential_title):
                        return potential_title
        
        return None
    
    def _looks_like_title(self, text: str) -> bool:
        """Verifica se um texto parece ser um título de capítulo."""
        if not text or len(text) < 3:
            return False
        
        # Muito longo para ser título
        if len(text) > 200:
            return False
        
        # Muito curto e só números
        if len(text) < 5 and text.isdigit():
            return False
        
        # Padrões que indicam título
        title_indicators = [
            text.isupper(),  # TODO EM MAIÚSCULO
            text.istitle(),  # Primeira Letra Maiúscula
            len(text.split()) <= 12,  # Máximo 12 palavras
            not text.endswith('.') or text.count('.') <= 1,  # Não é parágrafo
            not any(word in text.lower() for word in ['disse', 'respondeu', 'perguntou', 'falou', 'continuou'])  # Não é diálogo
        ]
        
        # Pelo menos 2 indicadores devem ser verdadeiros
        return sum(title_indicators) >= 2
    
    def _looks_like_chapter_title(self, text: str) -> bool:
        """Verifica se texto parece especificamente título de capítulo."""
        if not text or len(text) < 5 or len(text) > 100:
            return False
        
        # Padrões específicos de capítulo
        chapter_patterns = [
            r'^(CAPÍTULO|Capítulo|CHAPTER|Chapter)',
            r'^\d+\.',  # Começa com número e ponto
            r'^[IVX]+\.',  # Romano e ponto
            r'^[A-Z]{3,}$',  # TUDO MAIÚSCULO (mínimo 3 chars)
            r'^[A-Z][A-Z\s]{10,}$'  # Maiúsculo com espaços (títulos longos)
        ]
        
        for pattern in chapter_patterns:
            if re.match(pattern, text):
                return True
        
        # Se está em maiúsculo e é curto, provavelmente é título
        if text.isupper() and 5 <= len(text) <= 50:
            return True
        
        return False
    
    def _is_generic_title(self, title: str) -> bool:
        """Verifica se é um título genérico que deve ser ignorado."""
        generic_titles = [
            'untitled', 'chapter', 'capítulo', 'página', 'page',
            'sem título', 'document', 'book', 'livro', 'título',
            'content', 'body', 'main', 'text'
        ]
        
        return title.lower().strip() in generic_titles
    
    def _is_subtitle(self, text: str) -> bool:
        """Detecta se um texto é subtítulo/data (versão melhorada)."""
        if len(text) > 200:  # Textos muito longos não são subtítulos
            return False
        
        # Padrões de data e subtítulos
        subtitle_patterns = [
            r'^\d+\s*de\s+(janeiro|fevereiro|março|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)',
            r'^capítulo\s+[ivx\d]+$',
            r'^diário\s+de',
            r'^\([^)]*\)$',  # Texto entre parênteses
            r'^\d+\s*$',     # Números isolados
            r'^\*{2,}.*\*{2,}$',  # Entre asteriscos
            r'^_{2,}.*_{2,}$',   # Entre underscores
            r'^TAQUIGRAFADO',    # Específico para alguns livros
            r'^PARTE [IVX\d]+$', # "PARTE I", "PARTE 1"
            r'^\d{1,2}[h:]\d{2}',  # Horários
            r'^[A-Z\s]{3,15}$',  # Texto todo maiúsculo curto (datas/locais)
        ]
        
        text_lower = text.lower().strip()
        for pattern in subtitle_patterns:
            if re.search(pattern, text_lower):
                return True
        
        # Se tem poucas palavras, não termina com ponto e não parece título
        words = text.split()
        if (len(words) <= 6 and 
            not text.endswith('.') and 
            not self._looks_like_title(text)):
            return True
        
        return False
    
    def _extract_recursive(self, element, text_elements: list, depth: int = 0):
        """Extrai texto recursivamente preservando estrutura."""
        if hasattr(element, 'name') and element.name:
            if element.name in ['h1', 'h2', 'h3', 'h4', 'h5', 'h6']:
                text = element.get_text(strip=True)
                if text:
                    text_elements.append(('header', text, depth))
                    text_elements.append(('pause', '', depth))
                return
            
            elif element.name in ['p', 'div']:
                has_children = any(
                    child.name in ['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'div'] 
                    for child in element.find_all() 
                    if hasattr(child, 'name')
                )
                
                if has_children:
                    for child in element.children:
                        if hasattr(child, 'name'):
                            self._extract_recursive(child, text_elements, depth + 1)
                        elif child.string and child.string.strip():
                            text_elements.append(('text', child.string.strip(), depth))
                else:
                    text = element.get_text(strip=True)
                    if text:
                        if self._is_subtitle(text):
                            text_elements.append(('pause', '', depth))
                            text_elements.append(('subtitle', text, depth))
                            text_elements.append(('pause', '', depth))
                        else:
                            text_elements.append(('text', text, depth))
                return
            
            elif element.name == 'br':
                text_elements.append(('pause', '', depth))
                return
        
        if hasattr(element, 'children'):
            for child in element.children:
                if hasattr(child, 'name'):
                    self._extract_recursive(child, text_elements, depth)
                elif hasattr(child, 'string') and child.string and child.string.strip():
                    text = child.string.strip()
                    if text:
                        if self._is_subtitle(text):
                            text_elements.append(('pause', '', depth))
                            text_elements.append(('subtitle', text, depth))
                            text_elements.append(('pause', '', depth))
                        else:
                            text_elements.append(('text', text, depth))
    
    def _process_text_elements(self, text_elements: list) -> str:
        """Processa elementos de texto para criar texto final."""
        final_parts = []
        last_type = None
        
        for elem_type, text, depth in text_elements:
            if elem_type == 'pause':
                if last_type != 'pause':
                    final_parts.append('... ...')
            elif elem_type in ['header', 'subtitle']:
                final_parts.append(text)
            elif elem_type == 'text':
                final_parts.append(text)
            
            last_type = elem_type
        
        result_text = ' '.join(final_parts)
        result_text = re.sub(r'(\.\.\. \.\.\.){3,}', '... ... ...', result_text)
        result_text = re.sub(r'\s+', ' ', result_text)
        result_text = result_text.strip()
        
        return result_text


# [... PDFReader permanece igual ...]

class PDFReader(BaseEbookReader):
    """Leitor especializado para arquivos PDF."""
    
    def read(self, file_path: Path) -> Tuple[str, Optional[str], List[Tuple[str, str]]]:
        """Lê PDF e extrai texto organizado por páginas/seções."""
        if not PyPDF2:
            raise RuntimeError("PyPDF2 não instalado. Execute: pip install PyPDF2")
        
        print(f"[INFO] Lendo arquivo PDF: '{file_path.name}'")
        
        try:
            reader = PdfReader(str(file_path))
        except Exception as e:
            raise RuntimeError(f"Erro ao ler PDF: {e}")
        
        # Extrai metadados
        title, author = self._extract_metadata(reader, file_path)
        
        # Extrai capítulos
        chapters = self._extract_chapters_with_detection(reader)
        
        if not chapters:
            print("[INFO] Não detectou capítulos, dividindo por páginas...")
            chapters = self._extract_chapters_by_pages(reader)
        
        return title, author, chapters
    
    def _extract_metadata(self, reader, file_path: Path) -> Tuple[str, Optional[str]]:
        """Extrai metadados do PDF."""
        metadata = reader.metadata if hasattr(reader, 'metadata') else {}
        title = metadata.get('/Title', file_path.stem) if metadata else file_path.stem
        author = metadata.get('/Author', None) if metadata else None
        return title, author
    
    def _extract_chapters_with_detection(self, reader) -> List[Tuple[str, str]]:
        """Extrai capítulos detectando títulos automaticamente."""
        chapters = []
        current_chapter = []
        current_title = None
        chapter_num = 1
        
        print(f"📄 Total de páginas: {len(reader.pages)}")
        
        for page_num, page in enumerate(reader.pages, start=1):
            try:
                text = page.extract_text()
                if not text or len(text.strip()) < 50:
                    continue
                
                # Preserva quebras de linha originais para detectar estrutura
                text = re.sub(r' +', ' ', text)  # Remove espaços múltiplos
                text = re.sub(r'\n\s*\n\s*\n+', '\n\n', text)  # Normaliza quebras múltiplas
                
                # Verifica se é início de capítulo
                is_chapter_start, detected_title = self._detect_chapter_start(text)
                
                if is_chapter_start:
                    # Se já tem capítulo acumulado, salva
                    if current_chapter:
                        chapter_text = self._process_chapter_text(current_chapter)
                        if len(chapter_text.strip()) > 100:
                            chapter_title = current_title or f"Capítulo {chapter_num}"
                            chapters.append((chapter_title, chapter_text))
                            chapter_num += 1
                        current_chapter = []
                    
                    current_title = detected_title
                
                # Adiciona texto processado ao capítulo atual
                processed_text = self._add_pauses_to_text(text)
                current_chapter.append(processed_text)
                
                # A cada 10 páginas sem capítulo, cria um novo
                if len(current_chapter) >= 10 and not is_chapter_start:
                    chapter_text = self._process_chapter_text(current_chapter)
                    if len(chapter_text.strip()) > 100:
                        start_page = page_num - len(current_chapter) + 1
                        chapter_title = f"Páginas {start_page}-{page_num}"
                        chapters.append((chapter_title, chapter_text))
                        chapter_num += 1
                    current_chapter = []
                    current_title = None
                    
            except Exception as e:
                print(f"⚠️ Erro ao processar página {page_num}: {e}")
                continue
        
        # Salva último capítulo
        if current_chapter:
            chapter_text = self._process_chapter_text(current_chapter)
            if len(chapter_text.strip()) > 100:
                chapter_title = current_title or f"Capítulo {chapter_num}"
                chapters.append((chapter_title, chapter_text))
        
        return chapters
    
    def _add_pauses_to_text(self, text: str) -> str:
        """Adiciona pausas baseadas na estrutura do texto."""
        lines = text.split('\n')
        processed_lines = []
        
        for i, line in enumerate(lines):
            line = line.strip()
            
            if not line:  # Linha vazia
                processed_lines.append("... ...")  # Pausa para linha vazia
                continue
            
            # Detecta títulos/seções
            if self._is_section_title(line):
                processed_lines.append("... ...")  # Pausa antes do título
                processed_lines.append(line)
                processed_lines.append("... ...")  # Pausa depois do título
                continue
            
            # Detecta listas com bullets
            if self._is_bullet_point(line):
                processed_lines.append("... ...")  # Pausa antes de item de lista
                processed_lines.append(line)
                continue
            
            # Detecta fim de parágrafo
            if (line.endswith('.') or line.endswith(':') or line.endswith(';')) and i < len(lines) - 1:
                next_line = lines[i + 1].strip() if i + 1 < len(lines) else ""
                # Se próxima linha começa com maiúscula ou é vazia, é fim de parágrafo
                if not next_line or next_line[0].isupper() or self._is_section_title(next_line):
                    processed_lines.append(line)
                    processed_lines.append("... ...")  # Pausa de fim de parágrafo
                    continue
            
            # Detecta exemplos ou citações
            if line.startswith("Exemplos:") or line.startswith("Síntese:"):
                processed_lines.append("... ...")  # Pausa antes de seção especial
                processed_lines.append(line)
                continue
            
            processed_lines.append(line)
        
        return '\n'.join(processed_lines)
    
    def _is_section_title(self, line: str) -> bool:
        """Detecta se uma linha é um título de seção."""
        if len(line) > 100:  # Títulos geralmente são curtos
            return False
        
        # Padrões de títulos
        title_patterns = [
            r'^CASA [IVX]+$',  # "CASA IV"
            r'^[A-Z\s]+$',     # Texto todo em maiúsculas
            r'^\w+\s+na\s+Casa\s+[IVX]+$',  # "Lua na Casa IV"
            r'^Síntese:',      # Início de síntese
            r'^Exemplos:',     # Início de exemplos
            r'^Aporia:',       # Início de aporia
        ]
       
        for pattern in title_patterns:
            if re.match(pattern, line.strip()):
                return True

        # Se linha é curta e parece título
        words = line.split()
        if len(words) <= 5 and line[0].isupper():
            return True

        return False
    
    def _is_bullet_point(self, line: str) -> bool:
        """Detecta se uma linha é um item de lista."""
        bullet_patterns = [
            r'^•\s+',      # Bullet unicode
            r'^\*\s+',     # Asterisco
            r'^-\s+',      # Hífen
            r'^\d+\.\s+',  # Número com ponto
        ]
        
        for pattern in bullet_patterns:
            if re.match(pattern, line.strip()):
                return True
        
        return False
    
    def _process_chapter_text(self, chapter_pages: list) -> str:
        """Processa texto do capítulo unindo páginas."""
        # Une todas as páginas do capítulo
        full_text = '\n\n'.join(chapter_pages)
        
        # Limpa pausas excessivas
        full_text = re.sub(r'(\.\.\. \.\.\.){3,}', '... ... ...', full_text)
        full_text = re.sub(r'\n+', '\n', full_text)
        full_text = full_text.strip()
        
        return full_text
    
    def _detect_chapter_start(self, text: str) -> Tuple[bool, Optional[str]]:
        """Detecta se o texto marca início de um capítulo."""
        lines = text.split('\n')
        
        for line in lines[:5]:  # Verifica primeiras 5 linhas
            line = line.strip()
            if line:
                for pattern in CHAPTER_PATTERNS:
                    if re.match(pattern, line):
                        return True, line
        
        return False, None
    
    def _extract_chapters_by_pages(self, reader) -> List[Tuple[str, str]]:
        """Extrai capítulos dividindo por número fixo de páginas."""
        chapters = []
        pages_per_chapter = 20
        current_chunk = []
        
        for page_num, page in enumerate(reader.pages, start=1):
            try:
                text = page.extract_text()
                if text and len(text.strip()) > 50:
                    current_chunk.append(text)
                
                if len(current_chunk) >= pages_per_chapter or page_num == len(reader.pages):
                    if current_chunk:
                        chapter_text = '\n\n'.join(current_chunk)
                        start_page = page_num - len(current_chunk) + 1
                        chapter_title = f"Páginas {start_page}-{page_num}"
                        chapters.append((chapter_title, chapter_text))
                        current_chunk = []
                        
            except Exception:
                continue
        
        return chapters


class EbookReader:
    """Factory para criar leitores de ebook apropriados."""
    
    def __init__(self):
        self._readers = {
            '.epub': EPUBReader(),
            '.pdf': PDFReader()
        }
    
    def read_ebook(self, file_path: Path) -> Tuple[str, Optional[str], List[Tuple[str, str]]]:
        """
        Lê EPUB ou PDF e retorna título, autor e capítulos.
        
        Args:
            file_path: Caminho para o arquivo
            
        Returns:
            Tupla com (título, autor, lista_de_capítulos)
        """
        ext = file_path.suffix.lower()
        
        if ext not in self._readers:
            raise ValueError(f"Formato não suportado: {ext}. Use .epub ou .pdf")
        
        return self._readers[ext].read(file_path)