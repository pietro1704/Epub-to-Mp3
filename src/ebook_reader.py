"""
src/ebook_reader.py

Classes para leitura e processamento de arquivos EPUB e PDF.
"""

import re
from pathlib import Path
from typing import List, Tuple, Union, Optional
from abc import ABC, abstractmethod

import ebooklib
from ebooklib import epub
from bs4 import BeautifulSoup

# Importando do config agora que foi corrigido
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
    """Leitor especializado para arquivos EPUB."""
    
    def read(self, file_path: Path) -> Tuple[str, Optional[str], List[Tuple[str, str]]]:
        """Lê arquivo EPUB e extrai metadados e capítulos."""
        print(f"[INFO] Lendo arquivo EPUB: '{file_path.name}'")
        
        try:
            book = epub.read_epub(str(file_path))
        except Exception as e:
            raise RuntimeError(f"Erro ao ler EPUB: {e}")
        
        # Extrai metadados
        title = self._extract_title(book, file_path)
        author = self._extract_author(book)
        
        # Extrai capítulos
        chapters = self._extract_chapters(book)
        
        if not chapters:
            print("[AVISO] Não encontrou capítulos via spine, tentando todos os documentos...")
            chapters = self._extract_all_documents(book)
        
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
        """Extrai título e texto limpo do HTML preservando estrutura hierárquica."""
        soup = BeautifulSoup(html_bytes, "html.parser")
        title = self._extract_html_title(soup)
        
        # Remove scripts e estilos
        for bad in soup(["script", "style"]):
            bad.decompose()
        
        text_elements = []
        self._extract_recursive(soup.body if soup.body else soup, text_elements)
        
        if not text_elements:
            all_text = soup.get_text(" ", strip=True)
            if all_text:
                text_elements = [('text', all_text, 0)]
        
        # Processa elementos para criar texto final
        final_text = self._process_text_elements(text_elements)
        
        return title, final_text
    
    def _extract_html_title(self, soup: BeautifulSoup) -> Optional[str]:
        """Extrai título do HTML."""
        if soup.title and soup.title.string:
            title = soup.title.string.strip()
            if title:
                return title
        
        for tag in ("h1", "h2", "h3"):
            h = soup.find(tag)
            if h and h.get_text(strip=True):
                return h.get_text(strip=True)
        
        return None
    
    def _is_subtitle(self, text: str) -> bool:
        """Detecta se um texto é subtítulo/data."""
        if len(text) > 200:
            return False
        
        text_lower = text.lower()
        for pattern in SUBTITLE_PATTERNS:
            if re.search(pattern, text_lower):
                return True
        
        words = text.split()
        if len(words) <= 6 and not text.endswith('.'):
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