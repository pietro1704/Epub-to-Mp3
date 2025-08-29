# -*- coding: utf-8 -*-
"""
ebook_reader.py
Leitor simples de EPUB (stdlib only), com:
- Extração de metadados (título/autor)
- Extração de capítulos na ordem do spine
- Fallback de nome de capítulo (arquivo ou primeiro heading)
- Inserção de notas de rodapé inline no ponto do link
- Ganchos para pausas/reticências após títulos e parágrafos

Observação:
- Parser HTML/XML feito com xml.etree + re (sem BeautifulSoup/ebooklib).
- Funciona em muitos EPUBs comuns; casos muito exóticos podem precisar de ajustes.
"""

from __future__ import annotations

import io
import os
import re
import zipfile
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple, Union
from pathlib import Path
from xml.etree import ElementTree as ET

try:
    import pypdf
    PDF_AVAILABLE = True
except ImportError:
    PDF_AVAILABLE = False

XML_NS = {
    "ocf": "urn:oasis:names:tc:opendocument:xmlns:container",
    "opf": "http://www.idpf.org/2007/opf",
    "dc": "http://purl.org/dc/elements/1.1/",
    "ncx": "http://www.daisy.org/z3986/2005/ncx/",
    # Alguns EPUBs usam versões/aliases diferentes; adicionamos extras se necessário.
}

# ---------------------------
# Utilidades de texto/HTML
# ---------------------------

TAG_RE = re.compile(r"<[^>]+>")
WHITESPACE_RE = re.compile(r"[ \t\f\v]+")
NBSP_RE = re.compile(r"&nbsp;|\u00A0", flags=re.IGNORECASE)

H_TAG = re.compile(r"<h([1-6])[^>]*>(.*?)</h\1>", flags=re.IGNORECASE | re.DOTALL)
A_TAG = re.compile(
    r"<a\s+[^>]*href=[\"']([^\"'#]+)?#([^\"'#]+)[\"'][^>]*>(.*?)</a>",
    flags=re.IGNORECASE | re.DOTALL,
)
ID_TAG = re.compile(
    r"<([a-z0-9]+)\s+[^>]*id=[\"']([^\"']+)[\"'][^>]*>(.*?)</\1>",
    flags=re.IGNORECASE | re.DOTALL,
)

PARA_BLOCK_RE = re.compile(
    r"</?(p|div|br|li|tr|td|th|blockquote|section|article|hr)[^>]*>",
    flags=re.IGNORECASE,
)

def html_to_plain_text(html: str) -> str:
    """Remove tags e normaliza espaços de um trechinho HTML."""
    if not html:
        return ""
    # Remove title tags to avoid title repetition in text
    text = re.sub(r'<title[^>]*>.*?</title>', '', html, flags=re.IGNORECASE | re.DOTALL)
    text = NBSP_RE.sub(" ", text)
    # Quebras de linha em blocos comuns
    text = PARA_BLOCK_RE.sub("\n", text)
    # Remove o restante das tags
    text = TAG_RE.sub("", text)
    # Normaliza espaços
    text = WHITESPACE_RE.sub(" ", text)
    # Normaliza múltiplas quebras
    text = re.sub(r"\n\s*\n\s*", "\n\n", text.strip())
    return text.strip()

def extract_first_heading(html: str) -> Optional[str]:
    """Retorna o primeiro H1..H6 (texto limpo), se existir."""
    # Generic logic: if first heading is "CAPÍTULO X", look for a more specific second heading
    all_matches = list(H_TAG.finditer(html))
    if not all_matches:
        return None
    
    first_heading = html_to_plain_text(all_matches[0].group(2))
    
    # If first heading is generic "CAPÍTULO X" pattern, prefer a more descriptive second heading
    if (first_heading and first_heading.startswith("CAPÍTULO") and len(all_matches) > 1):
        second_heading = html_to_plain_text(all_matches[1].group(2))
        # If second heading exists and is substantial, use it
        if second_heading and len(second_heading.strip()) > 0:
            return second_heading
    
    return first_heading or None

def find_elements_with_id(html: str) -> Dict[str, str]:
    """
    Indexa blocos marcados com id="..." e devolve um mapa id -> innerHTML.
    Útil para buscar conteúdo de notas (muitas notas vêm como <p id="footnote-x">...</p>).
    """
    out: Dict[str, str] = {}
    for m in ID_TAG.finditer(html):
        elem_id = m.group(2)
        inner = m.group(3)
        # Guarda o HTML interno (a formatação da nota pode importar para o texto final)
        out[elem_id] = inner.strip()
    return out

def resolve_note_inline(
    link_display_html: str,
    target_id: str,
    html_by_path: Dict[str, str],
    id_index_by_path: Dict[str, Dict[str, str]],
) -> Optional[str]:
    """
    Resolve o conteúdo da nota no alvo target_id procurando em todos os arquivos.
    Retorna o texto da nota já limpo, ou None se não achar.
    """
    # Procura em todos os índices por target_id
    for path, idx in id_index_by_path.items():
        if target_id in idx:
            raw_html = idx[target_id]
            txt = html_to_plain_text(raw_html)
            if txt:
                # Se o texto é apenas um número (como "1."), busque o conteúdo completo do elemento pai
                if re.match(r'^\d+\.\s*$', txt.strip()):
                    # Esta nota é apenas um número, vamos buscar o conteúdo completo do parágrafo
                    full_html = html_by_path.get(path, "")
                    if full_html:
                        # Procura pelo parágrafo que contém este id
                        pattern = rf'<p[^>]*>.*?<a[^>]*id=["\']' + re.escape(target_id) + r'["\'][^>]*>.*?</a>(.*?)</p>'
                        match = re.search(pattern, full_html, re.IGNORECASE | re.DOTALL)
                        if match:
                            note_content = match.group(1).strip()
                            note_text = html_to_plain_text(note_content)
                            if note_text:
                                note_num = txt.strip().rstrip('.')  # Remove trailing dot if exists
                                return f"[Nota de rodapé nº {note_num}: {note_text} Fim da nota nº {note_num}.]"
                
                # Formato padrão para outras notas
                return f"[Nota: {txt}]"
    return None

# ---------------------------
# Modelo de dados
# ---------------------------

@dataclass
class Chapter:
    index: int
    name: str
    source_path: str
    text: str  # Texto limpo, com notas inseridas inline


@dataclass
class HierarchicalChapter:
    index: Union[int, str]
    title: str
    level: int
    play_order: int
    src: str
    original_id: str
    char_count: int
    estimated_duration: float
    children: List['HierarchicalChapter'] = None
    text: str = ""  # Adiciona campo text para manter o conteúdo
    
    def __post_init__(self):
        if self.children is None:
            self.children = []


@dataclass
class Book:
    title: str
    author: str
    chapters: List[Chapter]

# ---------------------------
# Leitura do EPUB (ZIP)
# ---------------------------

def _read_zip_text(zf: zipfile.ZipFile, path: str) -> str:
    with zf.open(path, "r") as f:
        data = f.read()
    # Tenta decodificar como UTF-8; se falhar, usa latin-1.
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1", errors="replace")

def _find_opf_path(zf: zipfile.ZipFile) -> str:
    """Encontra o caminho do .opf via META-INF/container.xml."""
    container_xml = _read_zip_text(zf, "META-INF/container.xml")
    root = ET.fromstring(container_xml)
    rootfile = root.find(".//ocf:rootfile", XML_NS)
    if rootfile is None:
        raise RuntimeError("EPUB inválido: rootfile não encontrado em container.xml")
    opf_path = rootfile.get("full-path")
    if not opf_path:
        raise RuntimeError("EPUB inválido: atributo full-path ausente em rootfile")
    return opf_path

def _opf_dir(opf_path: str) -> str:
    if "/" in opf_path:
        return opf_path.rsplit("/", 1)[0]
    return ""

def _join_path(base_dir: str, href: str) -> str:
    if not base_dir:
        return href
    if href.startswith("/"):
        # Em EPUB, href absoluto é raro; tratamos como relativo ao root do zip.
        return href.lstrip("/")
    return f"{base_dir.rstrip('/')}/{href}"

def _parse_opf(zf: zipfile.ZipFile, opf_path: str) -> Tuple[Dict[str, str], List[str], str, str]:
    """
    Retorna:
      - manifest_id_to_href: id -> href
      - spine_order_ids: lista de IDs na ordem
      - book_title
      - book_author
    """
    opf_xml = _read_zip_text(zf, opf_path)
    root = ET.fromstring(opf_xml)

    # Metadados
    title_el = root.find(".//dc:title", XML_NS)
    author_el = root.find(".//dc:creator", XML_NS)
    book_title = (title_el.text or "").strip() if title_el is not None else ""
    book_author = (author_el.text or "").strip() if author_el is not None else ""

    # Manifest
    manifest_id_to_href: Dict[str, str] = {}
    for item in root.findall(".//opf:item", XML_NS):
        iid = item.get("id")
        href = item.get("href")
        if iid and href:
            manifest_id_to_href[iid] = href

    # Spine
    spine_order_ids: List[str] = []
    for itemref in root.findall(".//opf:itemref", XML_NS):
        ref = itemref.get("idref")
        if ref:
            spine_order_ids.append(ref)

    return manifest_id_to_href, spine_order_ids, book_title, book_author

def _is_html_like(path: str) -> bool:
    low = path.lower()
    return low.endswith(".xhtml") or low.endswith(".html") or low.endswith(".htm")

def _build_id_index_for_all_html(zf: zipfile.ZipFile, html_by_path: Dict[str, str]) -> Dict[str, Dict[str, str]]:
    """
    Para cada arquivo HTML/XHTML, cria um índice id->innerHTML para facilitar
    resolução de notas.
    """
    out: Dict[str, Dict[str, str]] = {}
    for p, html in html_by_path.items():
        out[p] = find_elements_with_id(html)
    return out

def _inject_footnotes_inline(
    html: str,
    html_by_path: Dict[str, str],
    id_index_by_path: Dict[str, Dict[str, str]],
    current_path: str,
) -> str:
    """
    Substitui <a href="file#id">...</a> por "texto âncora [Nota: ...]" se achar a nota.
    Se o link não apontar para #id (não for nota), deixa como texto âncora sem link.
    """

    def repl(m: re.Match) -> str:
        href_file = (m.group(1) or "").strip()
        target_id = (m.group(2) or "").strip()
        anchor_html = m.group(3) or ""
        anchor_text = html_to_plain_text(anchor_html)

        # Alguns EPUBs colocam as notas no mesmo arquivo (href só com #id)
        # ou em outro arquivo (e.g., part0004.html#footnote-626-1).
        if not target_id:
            return anchor_text  # Sem id, vira só o texto visível do link

        # Caso tenha arquivo, poderíamos verificar href_file, mas como indexamos por id em todos,
        # basta procurar target_id em todos os arquivos:
        note_text = resolve_note_inline(anchor_html, target_id, html_by_path, id_index_by_path)
        if note_text:
            return f"{anchor_text} {note_text}"
        # Se não achou a nota, remove o link, mantém o texto âncora
        return anchor_text

    return A_TAG.sub(repl, html)

def _detect_page_breaks_and_structure(chapters: List[Chapter]) -> List[HierarchicalChapter]:
    """
    Detecta quebras de página e cria estrutura de capítulos/subcapítulos baseada nelas.
    Lógica agnóstica que funciona com qualquer livro:
    - Cada arquivo HTML separado = potencial quebra de página
    - Se arquivo termina com </div> e próximo começa diferente = quebra confirmada
    - Tenta usar títulos do toc.ncx como estrutura principal
    - Subcapítulos sem nome ganham prévia do texto
    """
    if not chapters:
        return []
    
    hierarchical_chapters = []
    current_chapter_group = []
    chapter_counter = 1
    
    # Agrupa capítulos por padrões de quebra de página
    for i, chapter in enumerate(chapters):
        current_chapter_group.append(chapter)
        
        # Detecta quebra de página:
        # 1. Mudança significativa no nome do arquivo (diferentes base names)
        # 2. Conteúdo termina com tags de fechamento de seção (div, section, etc.)
        # 3. Próximo capítulo começa com título/cabeçalho
        is_page_break = False
        
        # Verifica se é o último capítulo
        if i == len(chapters) - 1:
            is_page_break = True
        else:
            next_chapter = chapters[i + 1]
            
            # Quebra por mudança de arquivo base
            current_base = _extract_base_filename(chapter.source_path)
            next_base = _extract_base_filename(next_chapter.source_path)
            
            if current_base != next_base:
                is_page_break = True
            
            # Quebra por padrões de HTML (div fechado + novo início)
            elif chapter.text.rstrip().endswith(('</div>', '</section>', '</article>')):
                # Verifica se próximo capítulo começa com título ou cabeçalho
                next_text_start = next_chapter.text.strip()[:200]
                if any(pattern in next_text_start.upper() for pattern in 
                      ['CAPÍTULO', 'CHAPTER', 'PARTE', 'LIVRO', 'SEÇÃO']):
                    is_page_break = True
        
        # Se detectou quebra, processa o grupo atual
        if is_page_break and current_chapter_group:
            # Filtra grupos vazios ou de metadados antes de criar
            if _should_include_chapter_group(current_chapter_group):
                hier_chapter = _create_hierarchical_chapter_from_group(
                    current_chapter_group, chapter_counter
                )
                hierarchical_chapters.append(hier_chapter)
                chapter_counter += 1
            current_chapter_group = []
    
    return hierarchical_chapters

def _should_include_chapter_group(chapter_group: List[Chapter]) -> bool:
    """Verifica se um grupo de capítulos deve ser incluído na estrutura final."""
    if not chapter_group:
        return False
    
    # Calcula total de caracteres do grupo
    total_chars = sum(len(ch.text) if ch.text else 0 for ch in chapter_group)
    
    # Filtra grupos muito pequenos
    if total_chars < 200:
        return False
    
    # Verifica se é grupo de metadados
    all_text = " ".join(ch.text if ch.text else "" for ch in chapter_group)
    
    # Padrões de metadados/propaganda (duplicando aqui por enquanto)
    text_lower = all_text.lower()
    metadata_patterns = [
        'compre agora e leia',
        'isbn',
        '978',
        'páginas',
        'gibson william',
        'asimov isaac',
        'superman herói',
        'neuromancer',
        'androides sonham',
        'título original:',
        'copidesque:',
        'revisão:',
        'edição em língua portuguesa',
        'table of contents',
    ]
    
    # Se contém 2 ou mais padrões de metadados, filtra
    metadata_count = sum(1 for pattern in metadata_patterns if pattern in text_lower)
    return metadata_count < 2

def _extract_base_filename(file_path: str) -> str:
    """Extrai nome base do arquivo, preservando numeração para arquivos sequenciais."""
    basename = os.path.basename(file_path)
    
    # Para arquivos como index_split_xxx.html, preserva a numeração para tratamento individual
    if 'index_split_' in basename:
        # Retorna o nome completo sem extensão para tratar cada arquivo como único
        return re.sub(r'\.(html|htm|xhtml).*$', '', basename)
    
    # Para outros padrões, remove numeração split como antes
    base_clean = re.sub(r'_(?:split_)?\d+\.', '.', basename)
    base_clean = re.sub(r'\.(html|htm|xhtml).*$', '', base_clean)
    return base_clean

def _create_hierarchical_chapter_from_group(chapter_group: List[Chapter], chapter_num: int) -> HierarchicalChapter:
    """Cria capítulo hierárquico a partir de um grupo de capítulos sequenciais."""
    if len(chapter_group) == 1:
        # Capítulo simples
        chapter = chapter_group[0]
        title = chapter.name if not chapter.name.endswith('.html') else f"Capítulo {chapter_num}"
        
        return HierarchicalChapter(
            index=chapter_num,
            title=title,
            level=1,
            play_order=chapter_num,
            src=chapter.source_path,
            original_id=f"chapter-{chapter_num}",
            char_count=len(chapter.text),
            estimated_duration=len(chapter.text) / 1000 * 0.6,
            children=[]
        )
    else:
        # Capítulo com subcapítulos
        main_chapter = chapter_group[0]
        total_chars = sum(len(ch.text) for ch in chapter_group)
        
        # Título principal - usa o primeiro capítulo válido ou padrão
        main_title = main_chapter.name
        if main_title.endswith('.html') or not main_title.strip():
            main_title = f"Capítulo {chapter_num}"
        
        children = []
        for i, subchapter in enumerate(chapter_group[1:], 1):
            sub_title = subchapter.name
            
            # Se subcapítulo não tem nome descritivo, adiciona prévia do texto
            if sub_title.endswith('.html') or not sub_title.strip() or len(sub_title) < 5:
                text_preview = _extract_text_preview(subchapter.text, 4)
                sub_title = f"Seção {i}" + (f" - {text_preview}" if text_preview else "")
            
            child = HierarchicalChapter(
                index=f"{chapter_num}.{i}",
                title=sub_title,
                level=2,
                play_order=chapter_num * 100 + i,
                src=subchapter.source_path,
                original_id=f"chapter-{chapter_num}-{i}",
                char_count=len(subchapter.text),
                estimated_duration=len(subchapter.text) / 1000 * 0.6,
                children=[]
            )
            children.append(child)
        
        return HierarchicalChapter(
            index=chapter_num,
            title=main_title,
            level=1,
            play_order=chapter_num,
            src=main_chapter.source_path,
            original_id=f"chapter-{chapter_num}",
            char_count=len(main_chapter.text),  # Só o primeiro
            estimated_duration=len(main_chapter.text) / 1000 * 0.6,
            children=children
        )


def _extract_intelligent_title_with_content(chapter_obj, chapter_number: int) -> str:
    """Extrai título inteligente com numeração sequencial e primeiras palavras do conteúdo."""
    
    # 1. Verifica se há um nome descritivo no capítulo (mas não "Capítulo X")
    if (hasattr(chapter_obj, 'name') and chapter_obj.name and 
        not chapter_obj.name.endswith('.html') and 
        not chapter_obj.name.startswith('index_split') and
        not chapter_obj.name.startswith('Capítulo ') and  # ✅ NOVO: ignora "Capítulo 8", etc.
        not chapter_obj.name.strip().isdigit() and
        len(chapter_obj.name.strip()) > 3):
        return f"{chapter_number}. {chapter_obj.name}"
    
    # 2. SEMPRE tenta usar as primeiras palavras do conteúdo se disponível
    if hasattr(chapter_obj, 'text') and chapter_obj.text and chapter_obj.text.strip():
        content_words = _extract_first_words(chapter_obj.text, max_words=8)
        if content_words:
            return f"{chapter_number}. {content_words}"
    
    # 3. Fallback genérico
    return f"{chapter_number}. Capítulo {chapter_number}"

def _extract_first_words(text: str, max_words: int = 8) -> str:
    """Extrai as primeiras palavras significativas do texto para título."""
    if not text or not text.strip():
        return ""
    
    # Remove quebras de linha e normaliza espaços
    clean_text = re.sub(r'\s+', ' ', text.strip())
    
    # Detecta apêndices especificamente
    appendix_patterns = [
        r'Apêndice ([IVX]+):\s*\.{3}\s*(.+?)(?:\s[A-Z]|$)',
        r'Apêndice ([IVX]+):\s*\.{3}\s*(.+)',
        r'^Apêndice ([IVX]+)[:\s]*(.+)',
    ]
    
    for pattern in appendix_patterns:
        appendix_match = re.search(pattern, clean_text)
        if appendix_match:
            roman_num = appendix_match.group(1)
            title = appendix_match.group(2).strip()
            # Limpa o título removendo pontos extras
            title = re.sub(r'\.{3,}', '', title).strip()
            return f"Apêndice {roman_num} - {title[:40]}"
    
    # Detecta padrões específicos do Duna
    duna_patterns = [
        # Citações e excertos
        (r'–\s*excerto de[^"]*"([^"]+)"', lambda m: m.group(1)),
        (r'excerto de\s*"([^"]+)"', lambda m: m.group(1)), 
        # Divisões do livro
        (r'^(livro (?:primeiro|segundo|terceiro)) - (.+)', lambda m: f"{m.group(1).title()} - {m.group(2)}"),
        # Notas cartográficas
        (r'^Notas cartográficas', lambda m: "Notas Cartográficas"),
        # Sobre o autor
        (r'^Sobre o autor', lambda m: "Sobre o Autor"),
        # Terminologia
        (r'^No estudo do Imperium[^.]*\.([^.]*\.)', lambda m: "Terminologia do Imperium"),
    ]
    
    for pattern, extractor in duna_patterns:
        match = re.search(pattern, clean_text, re.IGNORECASE)
        if match:
            result = extractor(match)
            if result and len(result.strip()) > 3:
                return result[:60]
    
    # Filtra títulos muito genéricos ou técnicos
    generic_patterns = [
        r'^(@?page padding|margin:|body|html|xml|sumário|capa|folha de rosto)',
        r'^(publicado pela primeira vez|copyright|todos os direitos)',
        r'^(índice|bibliografia|notas|referências)',
        r'^(yueh ju\'i wellington|robô asimov isaac|superman herói mais conhecido)',
        r'^(neuromancer gibson william|androides sonham com ovelhas)',
        r'^(table contents|edição em língua portuguesa)',
        r'^(título original|copidesque|revisão|messias de duna herbert)',
        r'^(eu robô asimov|história de joe shuster)',
        r'^\d{13}\s+\d+\s+páginas',  # ISBN + páginas
    ]
    
    for pattern in generic_patterns:
        if re.search(pattern, clean_text.lower()):
            return ""
    
    # Procura por frases mais significativas (prioriza a primeira)
    sentences = re.split(r'[.!?]+', clean_text)
    best_sentence = None
    
    for i, sentence in enumerate(sentences):
        sentence = sentence.strip()
        # Pula frases muito técnicas ou de metadados
        if any(tech in sentence.lower() for tech in ['compre agora', 'páginas', 'isbn', '978']):
            continue
            
        if len(sentence) > 15 and len(sentence) < 120:
            # Prioriza primeira frase se for boa
            if i == 0 and len(sentence) > 25:
                best_sentence = sentence
                break
            elif not best_sentence and len(sentence) > 20:
                best_sentence = sentence
    
    if best_sentence:
        # Pega as primeiras palavras da melhor frase
        words = best_sentence.split()[:max_words]
        clean_words = []
        for word in words:
            # Remove pontuação inicial/final
            clean_word = re.sub(r'^[^\w]+|[^\w]+$', '', word)
            if clean_word and len(clean_word) > 1:
                clean_words.append(clean_word)
        
        if len(clean_words) >= 3:  # Pelo menos 3 palavras significativas
            result = ' '.join(clean_words)
            return result[:60]
    
    # Fallback: primeiras palavras simples se não encontrou frase boa
    words = clean_text.split()[:max_words]
    clean_words = []
    for word in words:
        clean_word = re.sub(r'^[^\w]+|[^\w]+$', '', word)
        if clean_word and len(clean_word) > 2:
            clean_words.append(clean_word)
    
    if len(clean_words) >= 3:
        result = ' '.join(clean_words)
        return result[:60]
    
    return ""

def _extract_intelligent_title(chapter_obj, chapter_number: int) -> str:
    """Extrai título inteligente para subcapítulos baseado no conteúdo."""
    # 1. Usa nome do capítulo se não for genérico
    if (chapter_obj.name and 
        not chapter_obj.name.endswith('.html') and 
        not chapter_obj.name.startswith('index_split') and
        len(chapter_obj.name.strip()) > 3):
        return chapter_obj.name
    
    # 2. Extrai primeira linha significativa do texto
    if chapter_obj.text and chapter_obj.text.strip():
        lines = chapter_obj.text.strip().split('\n')
        for line in lines[:5]:  # Verifica primeiras 5 linhas
            line = line.strip()
            if (len(line) > 10 and len(line) < 100 and 
                not line.lower().startswith(('o ', 'a ', 'uma ', 'um ', 'para ', 'com ', 'de '))):
                # Remove pontuação final
                line = line.rstrip('.,;:!?')
                return line
        
        # 3. Fallback: primeiras palavras do texto
        words = chapter_obj.text.strip().split()[:6]
        meaningful_words = []
        stop_words = {'que', 'com', 'para', 'uma', 'mas', 'por', 'ser', 'ter', 'ele', 'ela', 
                     'seu', 'sua', 'dos', 'das', 'nos', 'nas', 'essa', 'esse', 'está', 
                     'eram', 'teve', 'foi', 'isso', 'isto', 'como', 'mais', 'muito', 'bem'}
        
        for word in words:
            if len(word) > 2 and word.lower() not in stop_words:
                meaningful_words.append(word)
                if len(meaningful_words) >= 4:
                    break
        
        if meaningful_words:
            preview = ' '.join(meaningful_words)[:50]
            return f"Capítulo {chapter_number} - {preview.rstrip('.,;:!?')}"
    
    # 4. Título genérico final
    return f"Capítulo {chapter_number}"

def _extract_text_preview(text: str, max_words: int = 4) -> str:
    """Extrai prévia significativa do texto para usar como nome de subcapítulo."""
    if not text or not text.strip():
        return ""
    
    # Remove quebras de linha e normaliza espaços
    clean_text = re.sub(r'\s+', ' ', text.strip())
    
    # Pega as primeiras palavras significativas
    words = clean_text.split()
    meaningful_words = []
    
    for word in words[:20]:  # Analisa até 20 palavras
        # Filtra palavras muito curtas e comuns
        if (len(word) > 2 and 
            word.lower() not in ['que', 'com', 'para', 'uma', 'mas', 'por', 'ser', 'ter', 
                               'ele', 'ela', 'seu', 'sua', 'dos', 'das', 'nos', 'nas', 
                               'essa', 'esse', 'está', 'eram', 'teve', 'foi', 'isso', 
                               'isto', 'como', 'mais', 'muito', 'bem', 'ainda', 'onde',
                               'quando', 'porque', 'então', 'assim', 'depois', 'antes']):
            meaningful_words.append(word)
            if len(meaningful_words) >= max_words:
                break
    
    if meaningful_words:
        preview = ' '.join(meaningful_words)
        # Remove pontuação final
        preview = preview.rstrip('.,;:!?')
        return preview
    
    return ""

def _extract_dracula_subchapters(zf: zipfile.ZipFile, base_src: str, chapter_title: str, base_index: str) -> List['HierarchicalChapter']:
    """Extrai subcapítulos específicos do Dracula baseado em padrões de data, diário, taquigrafia, cartas."""
    import re
    
    # Encontra todos os arquivos split relacionados ao capítulo
    base_pattern = base_src.replace('_split_000.html', '').replace('.html', '')
    if base_pattern.startswith('text/'):
        base_pattern = base_pattern[5:]
    
    related_files = []
    for file_path in zf.namelist():
        if base_pattern in file_path and file_path.endswith('.html'):
            related_files.append(file_path)
    
    related_files.sort()
    
    subchapters = []
    subchapter_index = 1
    
    for file_path in related_files:
        try:
            content = zf.read(file_path).decode('utf-8')
            plain_text = html_to_plain_text(content)
            
            if len(plain_text.strip()) < 100:  # Skip arquivos muito pequenos
                continue
            
            # Extrai títulos de subcapítulo baseado nos padrões do Dracula
            subchapter_title = _extract_dracula_subchapter_title(content, plain_text)
            
            if subchapter_title:
                subchapter = HierarchicalChapter(
                    index=f"{base_index}.{subchapter_index}",
                    title=subchapter_title,
                    level=2,
                    play_order=subchapter_index,
                    src=file_path,
                    original_id=f"dracula_sub_{subchapter_index}",
                    char_count=len(plain_text),
                    estimated_duration=len(plain_text) / 1000 * 0.6,
                    children=[],
                    text=plain_text
                )
                subchapters.append(subchapter)
                subchapter_index += 1
        
        except Exception as e:
            continue  # Skip arquivos com erro
    
    return subchapters

def _extract_dracula_subchapter_title(html_content: str, plain_text: str) -> str:
    """Extrai título de subcapítulo específico do Dracula baseado nos padrões identificados."""
    import re
    
    # Prioridade 1: Datas (ex: 3 de maio, 15 de agosto)
    date_patterns = [
        r'(\d{1,2}\s+de\s+\w+)',  # "5 de maio"
        r'(\w+,?\s+\d{1,2}\s+de\s+\w+)',  # "Segunda, 5 de maio"
    ]
    
    for pattern in date_patterns:
        matches = re.findall(pattern, plain_text, re.IGNORECASE)
        for match in matches:
            clean_date = match.strip().rstrip(',')
            if len(clean_date) < 30:  # Evita datas muito longas
                return clean_date
    
    # Prioridade 2: Diários e documentos específicos  
    diary_patterns = [
        r'diário\s+de\s+([\w\s]+?)(?:\s|\(|$)',
        r'carta\s+de\s+([\w\s]+?)(?:\s|$)',
        r'memorando\s+de\s+([\w\s]+?)(?:\s|$)',
        r'nota\s+de\s+([\w\s]+?)(?:\s|$)',
    ]
    
    for pattern in diary_patterns:
        matches = re.findall(pattern, plain_text, re.IGNORECASE)
        for match in matches:
            clean_match = match.strip()
            if len(clean_match) < 50 and len(clean_match) > 3:
                doc_type = pattern.split('\\s')[0].title()  # Diário, Carta, etc.
                return f"{doc_type} de {clean_match}"
    
    # Prioridade 3: Taquigrafia
    if 'taquigrafado' in plain_text.lower():
        return "Diário (Taquigrafado)"
    
    # Prioridade 4: Padrões específicos do Dracula
    special_patterns = [
        (r'registro\s+fonográfico', 'Registro Fonográfico'),
        (r'relatório\s+médico', 'Relatório Médico'),
        (r'anotações?\s+de\s+viagem', 'Anotações de Viagem'),
    ]
    
    for pattern, title in special_patterns:
        if re.search(pattern, plain_text, re.IGNORECASE):
            return title
    
    # Fallback: Usa primeiras palavras significativas
    lines = plain_text.strip().split('\n')
    for line in lines[:3]:
        line = line.strip()
        if len(line) > 10 and len(line) < 80:
            # Remove palavras muito comuns no início
            if not line.lower().startswith(('o ', 'a ', 'uma ', 'um ', 'para ', 'com ', 'de ', 'no ', 'na ')):
                return line.rstrip('.,;:!?')
    
    return None

def _extract_subchapters_from_html(html_content: str, chapter_title: str, base_index: str) -> List['HierarchicalChapter']:
    """Extrai subcapítulos de um arquivo HTML baseado em headings e estrutura."""
    if not html_content or len(html_content.strip()) < 200:
        return []
    
    import re
    from bs4 import BeautifulSoup
    
    try:
        soup = BeautifulSoup(html_content, 'html.parser')
        
        # Remove scripts, styles, e outros elementos não textuais
        for script in soup(["script", "style"]):
            script.decompose()
        
        # Procura por headings (h1, h2, h3, h4) que podem ser subcapítulos
        headings = soup.find_all(['h1', 'h2', 'h3', 'h4', 'h5'])
        
        subchapters = []
        current_content = []
        subchapter_index = 1
        
        # Divide o conteúdo baseado nos headings
        all_elements = soup.find('body') or soup
        if all_elements:
            elements = list(all_elements.children)
            
            current_section_title = None
            current_section_content = []
            
            for element in elements:
                if hasattr(element, 'name') and element.name in ['h1', 'h2', 'h3', 'h4', 'h5']:
                    # Se já temos uma seção anterior, salva ela
                    if current_section_title and current_section_content:
                        section_text = ' '.join([str(e) for e in current_section_content])
                        clean_text = html_to_plain_text(section_text).strip()
                        
                        if len(clean_text) > 200:  # Só cria subcapítulo se tiver conteúdo substancial
                            subchapter = HierarchicalChapter(
                                index=f"{base_index}.{subchapter_index}",
                                title=current_section_title,
                                level=2,
                                play_order=subchapter_index,
                                src="",
                                original_id=f"sub_{subchapter_index}",
                                char_count=len(clean_text),
                                estimated_duration=len(clean_text) / 1000 * 0.6,
                                children=[]
                            )
                            subchapters.append(subchapter)
                            subchapter_index += 1
                    
                    # Inicia nova seção
                    current_section_title = html_to_plain_text(str(element)).strip()
                    current_section_content = []
                else:
                    # Adiciona elemento à seção atual
                    current_section_content.append(element)
            
            # Não esquece da última seção
            if current_section_title and current_section_content:
                section_text = ' '.join([str(e) for e in current_section_content])
                clean_text = html_to_plain_text(section_text).strip()
                
                if len(clean_text) > 200:
                    subchapter = HierarchicalChapter(
                        index=f"{base_index}.{subchapter_index}",
                        title=current_section_title,
                        level=2,
                        play_order=subchapter_index,
                        src="",
                        original_id=f"sub_{subchapter_index}",
                        char_count=len(clean_text),
                        estimated_duration=len(clean_text) / 1000 * 0.6,
                        children=[]
                    )
                    subchapters.append(subchapter)
        
        return subchapters
        
    except Exception as e:
        # Se der erro no parsing HTML, tenta uma abordagem mais simples com regex
        return _extract_subchapters_with_regex(html_content, base_index)

def _extract_subchapters_with_regex(content: str, base_index: str) -> List['HierarchicalChapter']:
    """Fallback: extrai subcapítulos usando regex para padrões comuns."""
    import re
    
    # Padrões comuns para subcapítulos
    patterns = [
        r'<h[1-4][^>]*>([^<]+)</h[1-4]>',  # Headings HTML
        r'(?:^|\n)\s*([A-Z][^.\n]{10,60})\s*(?:\n|$)',  # Linhas em maiúscula (títulos)
        r'(?:^|\n)\s*(\d+\s+de\s+\w+[^.\n]*)\s*(?:\n|$)',  # Datas (ex: "3 de maio")
        r'(?:^|\n)\s*(Diário\s+de\s+[^.\n]+)\s*(?:\n|$)',  # Diários
        r'(?:^|\n)\s*(Carta\s+de\s+[^.\n]+)\s*(?:\n|$)',   # Cartas
        r'(?:^|\n)\s*(Capítulo\s+[IVX]+[^.\n]*)\s*(?:\n|$)'  # Capítulos romanos
    ]
    
    subchapters = []
    plain_text = html_to_plain_text(content)
    
    # Tenta cada padrão
    for pattern in patterns:
        matches = re.findall(pattern, plain_text, re.MULTILINE | re.IGNORECASE)
        
        if matches:
            # Remove duplicatas e filtra títulos muito curtos
            unique_matches = []
            seen = set()
            for match in matches:
                clean_match = match.strip()
                if len(clean_match) > 5 and clean_match not in seen:
                    unique_matches.append(clean_match)
                    seen.add(clean_match)
            
            # Se encontrou subcapítulos válidos, cria a estrutura
            if len(unique_matches) >= 2:  # Pelo menos 2 subcapítulos
                for i, title in enumerate(unique_matches, 1):
                    # Estimativa de conteúdo (divide o texto total pelos subcapítulos)
                    estimated_chars = len(plain_text) // len(unique_matches)
                    
                    subchapter = HierarchicalChapter(
                        index=f"{base_index}.{i}",
                        title=title,
                        level=2,
                        play_order=i,
                        src="",
                        original_id=f"regex_sub_{i}",
                        char_count=estimated_chars,
                        estimated_duration=estimated_chars / 1000 * 0.6,
                        children=[]
                    )
                    subchapters.append(subchapter)
                break  # Para no primeiro padrão que funcionar
    
    return subchapters

def _is_meaningful_toc_structure(toc_structure: List[HierarchicalChapter]) -> bool:
    """Verifica se a estrutura do TOC é significativa (não apenas CSS/folhas de rosto)."""
    if not toc_structure or len(toc_structure) < 2:
        return False
    
    # Verifica se há pelo menos alguns capítulos com conteúdo substancial
    meaningful_chapters = [ch for ch in toc_structure if ch.char_count > 500]
    
    # Critério específico para coleções (como Nárnia): se temos poucos capítulos com títulos descritivos
    if len(toc_structure) <= 15:  # Poucos capítulos principais
        descriptive_titles = [ch for ch in toc_structure if len(ch.title) > 10 and not ch.title.isdigit() and ch.title not in ['Página de título', 'Folha de Rosto']]
        if len(descriptive_titles) >= 3:  # Pelo menos 3 títulos descritivos
            return True
    
    # Critério flexível: se temos navPoints em quantidade razoável e pelo menos alguns com conteúdo
    if len(meaningful_chapters) >= 5 and len(toc_structure) < 200:  # Pelo menos 5 capítulos substanciais
        return True
    
    # Critério original mais restritivo
    return len(meaningful_chapters) >= max(2, len(toc_structure) * 0.1)  # Pelo menos 10% dos capítulos devem ter conteúdo

def _parse_toc_ncx(zf: zipfile.ZipFile, base_dir: str, chapters: List[Chapter], book_title: str = "", book_author: str = "") -> List[HierarchicalChapter]:
    """
    Parseia o toc.ncx para extrair estrutura hierárquica dos capítulos.
    Retorna uma lista de HierarchicalChapter com a estrutura aninhada.
    """
    toc_path = _join_path(base_dir, "toc.ncx")
    if toc_path not in zf.namelist():
        # Fallback: procura por qualquer arquivo .ncx
        ncx_files = [f for f in zf.namelist() if f.endswith('.ncx')]
        if not ncx_files:
            return []  # Sem toc.ncx, retorna lista vazia
        toc_path = ncx_files[0]
    
    try:
        toc_xml = _read_zip_text(zf, toc_path)
        root = ET.fromstring(toc_xml)
        
        # Namespaces NCX
        ns = {'ncx': 'http://www.daisy.org/z3986/2005/ncx/'}
        
        # Mapeia src para Chapter para obter char_count
        src_to_chapter = {}
        for ch in chapters:
            # Remove prefixo base_dir da source_path e normaliza
            normalized_src = ch.source_path
            if normalized_src.startswith(base_dir):
                normalized_src = normalized_src[len(base_dir):].lstrip('/')
            src_to_chapter[normalized_src] = ch
            # Também mapeia versões com e sem fragmento
            if '#' in normalized_src:
                base_src = normalized_src.split('#')[0]
                if base_src not in src_to_chapter:
                    src_to_chapter[base_src] = ch
        
        
        def parse_navpoint(nav_points, level=1, parent_index=""):
            """Recursivamente parseia navPoint elements."""
            hierarchical_chapters = []
            
            for i, nav_point in enumerate(nav_points, 1):
                # Extrai informações básicas
                play_order = int(nav_point.get('playOrder', 0))
                nav_id = nav_point.get('id', '')
                
                # Extrai título
                nav_label = nav_point.find('ncx:navLabel/ncx:text', ns)
                nav_title = nav_label.text.strip() if nav_label is not None else f"Capítulo {i}"
                
                
                # Extrai src
                content_elem = nav_point.find('ncx:content', ns)
                src = content_elem.get('src', '') if content_elem is not None else ''
                
                
                # Normaliza src
                normalized_src = src.split('#')[0] if '#' in src else src
                if normalized_src.startswith('Text/'):
                    normalized_src = normalized_src[5:]  # Remove prefixo Text/
                
                
                # Encontra capítulo correspondente para char_count e text
                char_count = 0
                chapter_text = ""
                matching_chapter = src_to_chapter.get(normalized_src)
                
                
                if matching_chapter:
                    char_count = len(matching_chapter.text)
                    chapter_text = matching_chapter.text
                
                # Se é um arquivo _split_, sempre tenta somar os arquivos relacionados
                if '_split_' in normalized_src:
                    total_chars = 0
                    base_pattern = normalized_src.replace('_split_000.html', '').replace('_split_001.html', '').replace('_split_002.html', '').replace('_split_003.html', '').replace('.html', '')
                    # Remove prefixo de diretório para comparação
                    if '/' in base_pattern:
                        base_pattern = base_pattern.split('/')[-1]
                    
                    
                    for chapter_src, chapter in src_to_chapter.items():
                        chapter_base = chapter_src.split('/')[-1] if '/' in chapter_src else chapter_src
                        chapter_pattern = chapter_base.replace('_split_000.html', '').replace('_split_001.html', '').replace('_split_002.html', '').replace('_split_003.html', '').replace('.html', '')
                        
                        
                        if base_pattern == chapter_pattern:
                            total_chars += len(chapter.text)
                    
                    if total_chars > char_count:  # Usa a soma se for maior
                        char_count = total_chars
                
                if not matching_chapter and '_split_' not in normalized_src:
                    # Tenta busca mais flexível para arquivos split
                    # Remove prefixos de diretório para busca
                    base_src = normalized_src
                    if '/' in base_src:
                        base_src = base_src.split('/')[-1]
                    
                    # Busca direta
                    if base_src in src_to_chapter:
                        char_count = len(src_to_chapter[base_src].text)
                    else:
                        # Para arquivos split, soma todos os arquivos relacionados
                        total_chars = 0
                        base_pattern = base_src.replace('_split_000.html', '').replace('_split_001.html', '').replace('_split_002.html', '').replace('_split_003.html', '').replace('.html', '')
                        
                        if False:  # Debug desabilitado
                            print(f"🔍 Buscando padrão '{base_pattern}' para src='{src}' normalized='{normalized_src}' base='{base_src}'")
                        
                        for chapter_src, chapter in src_to_chapter.items():
                            chapter_base = chapter_src.split('/')[-1] if '/' in chapter_src else chapter_src
                            chapter_pattern = chapter_base.replace('_split_000.html', '').replace('_split_001.html', '').replace('_split_002.html', '').replace('_split_003.html', '').replace('.html', '')
                            
                            if base_pattern == chapter_pattern:
                                total_chars += len(chapter.text)
                                if False:  # Debug desabilitado
                                    print(f"   Encontrou: {chapter_src} -> {chapter.name} ({len(chapter.text)} chars)")
                        
                        char_count = total_chars
                        if False:  # Debug desabilitado
                            print(f"   Total chars: {char_count}")
                
                # Usa título do TOC (mais confiável)
                actual_title = nav_title
                
                # Se matching_chapter tem nome descritivo, considera usar
                if matching_chapter and matching_chapter.name:
                    chapter_name = matching_chapter.name.strip()
                    # Se o nome do arquivo for mais descritivo que o TOC, usa ele
                    # Evita nomes genéricos como part0015_split_000, index_split_001, etc.
                    if (not chapter_name.endswith('.html') and 
                        len(chapter_name) > len(actual_title) and
                        not ('split_' in chapter_name or 'part0' in chapter_name or 'index_' in chapter_name)):
                        actual_title = chapter_name
                
                # Calcula index hierárquico  
                if parent_index:
                    hierarchical_index = f"{parent_index}.{i}"
                else:
                    hierarchical_index = str(i)
                
                # Cria HierarchicalChapter
                hier_chapter = HierarchicalChapter(
                    index=hierarchical_index,
                    title=actual_title,
                    level=level,
                    play_order=play_order,
                    src=src,
                    original_id=nav_id,
                    char_count=char_count,
                    estimated_duration=char_count / 1000 * 0.6,
                    children=[],
                    text=chapter_text  # Inclui o texto real
                )
                
                # Parseia filhos recursivamente (apenas filhos diretos)
                direct_children = nav_point.findall('ncx:navPoint', ns)
                if direct_children:
                    hier_chapter.children = parse_navpoint(direct_children, level + 1, hierarchical_index)
                
                hierarchical_chapters.append(hier_chapter)
            
            return hierarchical_chapters
        
        
        # Encontra navMap e parseia navPoints
        nav_map = root.find('.//ncx:navMap', ns)
        if nav_map is None:
            return []
            
        # Garante que encontra TODOS os navPoints
        all_nav_points = root.findall('.//ncx:navPoint', ns)
        
        def create_subchapters_from_splits(chapter, src_to_chapter):
            """Cria subcapítulos a partir de arquivos split com títulos diferentes."""
            normalized_src = chapter.src.split('#')[0] if '#' in chapter.src else chapter.src
            if normalized_src.startswith('Text/'):
                normalized_src = normalized_src[5:]
            
            base_pattern = normalized_src.replace('_split_000.html', '').replace('_split_001.html', '').replace('_split_002.html', '').replace('_split_003.html', '').replace('.html', '')
            if '/' in base_pattern:
                base_pattern = base_pattern.split('/')[-1]
            
            # Coleta todos os arquivos split relacionados
            split_files = []
            for chapter_src, chapter_obj in src_to_chapter.items():
                chapter_base = chapter_src.split('/')[-1] if '/' in chapter_src else chapter_src
                chapter_pattern = chapter_base.replace('_split_000.html', '').replace('_split_001.html', '').replace('_split_002.html', '').replace('_split_003.html', '').replace('.html', '')
                
                if base_pattern == chapter_pattern and '_split_' in chapter_src:
                    # Extrai número do split para ordenação
                    split_num = 0
                    if '_split_001' in chapter_src:
                        split_num = 1
                    elif '_split_002' in chapter_src:
                        split_num = 2
                    elif '_split_003' in chapter_src:
                        split_num = 3
                    split_files.append((split_num, chapter_src, chapter_obj))
            
            # Ordena por número do split
            split_files.sort()
            
            # Filtra apenas arquivos com títulos substanciais e únicos
            meaningful_chapters = []
            for _, chapter_src, chapter_obj in split_files:
                # Check if this is essentially the same as the main chapter title
                is_duplicate_title = False
                if chapter_obj.name.strip() and chapter.title.strip():
                    # Remove "CAPÍTULO " prefix and compare
                    chapter_clean = chapter_obj.name.replace("CAPÍTULO ", "").strip()
                    main_clean = chapter.title.strip()
                    
                    # Check if they're the same (e.g., "XIV" == "XIV" or "CAPÍTULO XIV" contains "XIV")
                    if (chapter_clean == main_clean or 
                        chapter_obj.name.strip() == chapter.title.strip() or
                        main_clean in chapter_obj.name):
                        is_duplicate_title = True
                
                if (chapter_obj.name.strip() and 
                    not chapter_obj.name.endswith('.html') and 
                    not is_duplicate_title and  # Skip duplicate titles
                    len(chapter_obj.text.strip()) > 100):  # Conteúdo substancial
                    meaningful_chapters.append((chapter_src, chapter_obj))
            
            # Se há múltiplos subcapítulos com títulos únicos, cria a estrutura hierárquica
            if len(meaningful_chapters) > 1:
                unique_titles = set(ch.name for _, ch in meaningful_chapters)
                if len(unique_titles) > 1:  # Títulos realmente diferentes
                    sub_chapters = []
                    for i, (chapter_src, chapter_obj) in enumerate(meaningful_chapters, 1):
                        sub_char_count = len(chapter_obj.text)
                        # Usa título inteligente com numeração sequencial
                        intelligent_title = _extract_intelligent_title_with_content(chapter_obj, i)
                        
                        sub_chapter = HierarchicalChapter(
                            index=f"{chapter.index}.{i}",
                            title=intelligent_title,
                            level=chapter.level + 1,
                            play_order=chapter.play_order * 100 + i,
                            src=chapter_src,
                            original_id=f"{chapter.original_id}_sub_{i}",
                            char_count=sub_char_count,
                            estimated_duration=sub_char_count / 1000 * 0.6,
                            children=[],
                            text=chapter_obj.text  # Inclui o texto real
                        )
                        sub_chapters.append(sub_chapter)
                    
                    # Set parent chapter to 0 chars since content is in subcapters
                    chapter.char_count = 0
                    chapter.estimated_duration = 0.0
                    
                    return sub_chapters
            
            # Verifica se é um capítulo "container" estilo Duna (poucos chars, muitos arquivos sequenciais)
            if (chapter.char_count < 200 and  # Container pequeno
                chapter.title in ['Livro primeiro', 'Livro segundo', 'Livro terceiro']):  # Título Duna-style
                
                return create_sequential_subchapters(chapter, src_to_chapter)
            
            return []
        
        def create_sequential_subchapters(chapter, src_to_chapter):
            """Cria subcapítulos sequenciais para livros estilo Duna - CORREÇÃO do problema de parsing."""
            base_src = chapter.src.split('#')[0] if '#' in chapter.src else chapter.src
            if base_src.startswith('Text/'):
                base_src = base_src[5:]
            
            # Extrai padrão do arquivo baseado em diferentes formatos
            import re
            
            # Padrões mais flexíveis para diferentes estruturas de EPUB
            patterns = [
                r'(\w+)_split_(\d+)\.html',     # index_split_005.html
                r'(\w+)_(\d+)\.html',           # index_005.html
                r'(part\d+)_split_(\d+)\.html', # part001_split_005.html
                r'(chapter)_?(\d+)\.html'       # chapter_5.html ou chapter5.html
            ]
            
            match = None
            for pattern in patterns:
                match = re.search(pattern, base_src, re.IGNORECASE)
                if match:
                    break
            
            if not match:
                return []
            
            prefix = match.group(1)
            start_num = int(match.group(2))
            
            # Detecção inteligente de range baseado no conteúdo e estrutura
            # Em vez de ranges fixos, usa lógica dinâmica
            sequential_files = []
            
            # Procura arquivos sequenciais dinamicamente
            for check_num in range(start_num + 1, start_num + 100):  # Verifica próximos 100 arquivos
                file_patterns = [
                    f"{prefix}_split_{check_num:03d}.html",
                    f"{prefix}_{check_num:03d}.html",
                    f"{prefix}_split_{check_num:d}.html",
                    f"{prefix}_{check_num:d}.html"
                ]
                
                found_file = False
                for file_pattern in file_patterns:
                    for chapter_src, chapter_obj in src_to_chapter.items():
                        if file_pattern in chapter_src and len(chapter_obj.text.strip()) > 200:  # Conteúdo mínimo
                            sequential_files.append((check_num, chapter_src, chapter_obj))
                            found_file = True
                            break
                    if found_file:
                        break
                
                # Para se não encontrar arquivo por 5 tentativas consecutivas
                if not found_file:
                    if check_num - start_num > 5:  # 5 arquivos não encontrados seguidos
                        break
            
            # Ordena por número
            sequential_files.sort()
            
            # Cria subcapítulos com títulos inteligentes
            if len(sequential_files) > 0:
                sub_chapters = []
                for i, (file_num, chapter_src, chapter_obj) in enumerate(sequential_files, 1):
                    sub_char_count = len(chapter_obj.text)
                    
                    # Extração inteligente de título com numeração sequencial e conteúdo
                    title = _extract_intelligent_title_with_content(chapter_obj, i)
                    
                    sub_chapter = HierarchicalChapter(
                        index=f"{chapter.index}.{i}",
                        title=title,
                        level=chapter.level + 1,
                        play_order=chapter.play_order * 100 + i,
                        src=chapter_src,
                        original_id=f"{chapter.original_id}_seq_{i}",
                        char_count=sub_char_count,
                        estimated_duration=sub_char_count / 1000 * 0.6,
                        children=[],
                        text=chapter_obj.text  # Inclui o texto real
                    )
                    sub_chapters.append(sub_chapter)
                
                # Parent chapter vira container
                chapter.char_count = 0
                chapter.estimated_duration = 0.0
                
                return sub_chapters
            
            return []
        
        # Abordagem agnóstica: parseia hierarquia completa do TOC
        root_nav_points = nav_map.findall('ncx:navPoint', ns)
        hierarchical_chapters = parse_navpoint(root_nav_points)
        
        # Busca seções perdidas em qualquer nível (agnóstico)
        # Pega TODOS os navPoints e verifica se algum foi perdido
        all_nav_points = root.findall('.//ncx:navPoint', ns)
        existing_src = {ch.src.split('#')[0] if '#' in ch.src else ch.src for ch in hierarchical_chapters}
        
        for nav_point in all_nav_points:
            content_elem = nav_point.find('ncx:content', ns)
            if content_elem is not None:
                src = content_elem.get('src', '')
                normalized_src = src.split('#')[0] if '#' in src else src
                
                # Se este navPoint não está representado, adiciona
                if normalized_src and normalized_src not in existing_src:
                    nav_label = nav_point.find('ncx:navLabel/ncx:text', ns)
                    title = nav_label.text.strip() if nav_label is not None else f"Seção {len(hierarchical_chapters) + 1}"
                    play_order = int(nav_point.get('playOrder', len(hierarchical_chapters) + 1))
                    
                    # Busca char_count
                    char_count = 0
                    if normalized_src.startswith('Text/'):
                        normalized_src = normalized_src[5:]
                    matching_chapter = src_to_chapter.get(normalized_src)
                    if matching_chapter:
                        char_count = len(matching_chapter.text)
                    
                    # Só adiciona se tem conteúdo substancial
                    if char_count > 100:
                        chapter_text = matching_chapter.text if matching_chapter else ""
                        additional_chapter = HierarchicalChapter(
                            index=str(len(hierarchical_chapters) + 1),
                            title=title,
                            level=1,
                            play_order=play_order,
                            src=src,
                            original_id=nav_point.get('id', ''),
                            char_count=char_count,
                            estimated_duration=char_count / 1000 * 0.6,
                            children=[],
                            text=chapter_text
                        )
                        
                        hierarchical_chapters.append(additional_chapter)
                        existing_src.add(normalized_src)
        
        # Ordena capítulos por playOrder para manter sequência correta
        hierarchical_chapters.sort(key=lambda ch: ch.play_order)
        
        # Post-processa para criar subcapítulos automaticamente baseado no conteúdo HTML
        processed_chapters = []
        for chapter in hierarchical_chapters:
            # Para capítulos com conteúdo substancial, tenta extrair subcapítulos
            if chapter.char_count > 1000 and not chapter.children:
                # Encontra o arquivo HTML correspondente
                html_content = None
                normalized_src = chapter.src.split('#')[0] if '#' in chapter.src else chapter.src
                if normalized_src.startswith('Text/'):
                    normalized_src = normalized_src[5:]
                
                # Busca o HTML no mapeamento de capítulos
                matching_chapter = src_to_chapter.get(normalized_src)
                if matching_chapter:
                    # Tenta acessar o HTML bruto do arquivo EPUB diretamente
                    try:
                        # Reconstrói o caminho completo do arquivo no EPUB
                        full_path = _join_path(base_dir, normalized_src)
                        if full_path in zf.namelist():
                            html_content = _read_zip_text(zf, full_path)
                        else:
                            # Tenta caminho alternativo
                            alt_path = f"Text/{normalized_src}" if not normalized_src.startswith('Text/') else normalized_src
                            if alt_path in zf.namelist():
                                html_content = _read_zip_text(zf, alt_path)
                            else:
                                html_content = None
                    except Exception as e:
                        html_content = None
                
                # Se não conseguiu acessar HTML, tenta usar o texto processado
                if not html_content and matching_chapter:
                    # Reconstrói HTML básico do texto processado para tentar extrair estrutura
                    html_content = f"<html><body><p>{matching_chapter.text}</p></body></html>"
                
                # Detecção específica para Dracula (baseada em padrões de data/diário/taquigrafia)
                # Verifica título do livro via metadados do OPF
                is_dracula = ('dracula' in book_title.lower() or 'drácula' in book_title.lower() or
                             'stoker' in book_author.lower())
                
                if is_dracula and '_split_' in chapter.src:
                    # Usa método específico do Dracula para subcapítulos
                    sub_chapters = _extract_dracula_subchapters(zf, normalized_src, chapter.title, chapter.index)
                    if sub_chapters and len(sub_chapters) >= 2:
                        chapter.children = sub_chapters
                        chapter.char_count = 0
                        chapter.estimated_duration = 0.0
                
                # Fallback: Extrai subcapítulos do HTML (método genérico)
                elif html_content:
                    sub_chapters = _extract_subchapters_from_html(html_content, chapter.title, chapter.index)
                    if sub_chapters and len(sub_chapters) >= 2:
                        chapter.children = sub_chapters
                        # Parent chapter vira container, conteúdo fica nos subcapítulos
                        chapter.char_count = 0
                        chapter.estimated_duration = 0.0
            
            # Fallback: tenta método anterior para arquivos split
            elif '_split_' in chapter.src and not chapter.children:
                sub_chapters = create_subchapters_from_splits(chapter, src_to_chapter)
                if sub_chapters:
                    chapter.children = sub_chapters
                    chapter.char_count = 0
                    chapter.estimated_duration = 0.0
            
            processed_chapters.append(chapter)
        
        return processed_chapters
        
    except Exception as e:
        print(f"⚠️ Erro ao parsear toc.ncx: {e}")
        return []



def read_epub(path: str) -> Book:
    """Lê um EPUB e retorna um Book com capítulos em ordem."""
    if not os.path.isfile(path):
        raise FileNotFoundError(f"Arquivo não encontrado: {path}")

    with zipfile.ZipFile(path, "r") as zf:
        # content.opf
        opf_path = _find_opf_path(zf)
        manifest, spine_ids, book_title, book_author = _parse_opf(zf, opf_path)
        base_dir = _opf_dir(opf_path)

        # Carrega todos HTML/XHTML referenciados no manifest (para notas/índices)
        html_by_path: Dict[str, str] = {}
        for href in manifest.values():
            if _is_html_like(href):
                full_path = _join_path(base_dir, href)
                if full_path in zf.namelist():
                    html_by_path[full_path] = _read_zip_text(zf, full_path)

        # Índice global de ids para notas
        id_index_by_path = _build_id_index_for_all_html(zf, html_by_path)

        # Monta capítulos segundo o spine
        chapters: List[Chapter] = []
        chap_idx = 1
        for iid in spine_ids:
            href = manifest.get(iid)
            if not href or not _is_html_like(href):
                continue
            src_path = _join_path(base_dir, href)
            if src_path not in zf.namelist():
                # Pode ser media/estilos etc. Ignora se não existir.
                continue

            raw_html = html_by_path.get(src_path)
            if raw_html is None:
                raw_html = _read_zip_text(zf, src_path)

            # Nome do capítulo: primeiro heading, senão primeiras palavras do texto
            heading_name = extract_first_heading(raw_html)
            if heading_name:
                name = heading_name
            else:
                # Converte para texto e tenta extrair título das primeiras linhas
                temp_html_with_notes = _inject_footnotes_inline(
                    raw_html, html_by_path, id_index_by_path, current_path=src_path
                )
                temp_txt = html_to_plain_text(temp_html_with_notes)
                
                # Extrai título inteligente das primeiras palavras
                intelligent_title = _extract_first_words(temp_txt, max_words=6)
                
                if intelligent_title and len(intelligent_title.strip()) > 5:
                    name = intelligent_title
                else:
                    # Fallback: usa número do capítulo com índice sequencial
                    name = f"Capítulo {chap_idx}"

            # Injeta notas inline
            html_with_notes = _inject_footnotes_inline(
                raw_html, html_by_path, id_index_by_path, current_path=src_path
            )

            # Converte para texto simples
            txt = html_to_plain_text(html_with_notes)

            # Adiciona pausa após títulos naturais no início do texto
            # Procura por títulos/datas no início e adiciona pausa
            lines = txt.split('\n')
            if lines and len(lines) > 1:
                first_line = lines[0].strip()
                # Se a primeira linha parece ser um título/data e é curta, adiciona pausa
                if (len(first_line) < 50 and 
                    (any(keyword in first_line.lower() for keyword in ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro']) or
                     any(char in first_line for char in ['º', 'ª', 'I', 'V', 'X']) or
                     first_line.isupper() or
                     first_line.startswith('Capítulo'))):
                    lines[0] = f"{first_line} ..."
                    txt = '\n'.join(lines)

            chapters.append(
                Chapter(
                    index=chap_idx,
                    name=name,
                    source_path=src_path,
                    text=txt.strip(),
                )
            )
            chap_idx += 1

        return Book(
            title=book_title or os.path.splitext(os.path.basename(path))[0],
            author=book_author or "",
            chapters=chapters,
        )

def read_pdf(path: str) -> Book:
    """Lê um PDF e retorna um Book com páginas como capítulos."""
    if not PDF_AVAILABLE:
        raise ImportError("Biblioteca 'pypdf' não instalada. Execute: pip install pypdf")
    
    if not os.path.isfile(path):
        raise FileNotFoundError(f"Arquivo não encontrado: {path}")
    
    try:
        with open(path, 'rb') as pdf_file:
            pdf_reader = pypdf.PdfReader(pdf_file)
            
            # Metadados básicos
            book_title = "PDF Document"
            book_author = ""
            
            if pdf_reader.metadata:
                book_title = pdf_reader.metadata.get('/Title', book_title)
                book_author = pdf_reader.metadata.get('/Author', book_author)
            
            # Se não conseguir metadados, usa o nome do arquivo
            if book_title == "PDF Document":
                book_title = os.path.splitext(os.path.basename(path))[0]
            
            chapters = []
            
            # Cada página vira um "capítulo"
            for page_num, page in enumerate(pdf_reader.pages, start=1):
                try:
                    text = page.extract_text()
                    if text.strip():  # Só adiciona se tem conteúdo
                        chapters.append(
                            Chapter(
                                index=page_num,
                                name=f"Página {page_num}",
                                source_path=f"page_{page_num}",
                                text=text.strip(),
                            )
                        )
                except Exception as e:
                    print(f"⚠️  Erro ao extrair texto da página {page_num}: {e}")
                    # Adiciona capítulo vazio mesmo se der erro
                    chapters.append(
                        Chapter(
                            index=page_num,
                            name=f"Página {page_num} (erro na extração)",
                            source_path=f"page_{page_num}",
                            text="",
                        )
                    )
            
            return Book(
                title=book_title,
                author=book_author,
                chapters=chapters,
            )
            
    except Exception as e:
        raise ValueError(f"Erro ao processar PDF: {e}")

# ---------------------------
# API pública simples
# ---------------------------

def read_book(path: str) -> Book:
    """
    Ponto de entrada principal: dado um .epub, retorna Book.
    Levanta exceções claras em caso de problemas.
    """
    low = path.lower()
    if low.endswith(".epub"):
        return read_epub(path)
    elif low.endswith(".pdf"):
        return read_pdf(path)
    raise ValueError(f"Formato não suportado: {path}")

# ---------------------------
# CLI de teste rápido
# ---------------------------

def _preview(book: Book, max_chars: int = 800) -> str:
    lines = [
        f"Título: {book.title or '(desconhecido)'}",
        f"Autor: {book.author or '(desconhecido)'}",
        f"Capítulos: {len(book.chapters)}",
        "-" * 40,
    ]
    for ch in book.chapters[:3]:
        lines.append(f"[{ch.index:02d}] {ch.name}  —  fonte: {ch.source_path}")
        excerpt = ch.text[:max_chars].strip().replace("\n", " ")
        lines.append(f"  {excerpt}" + ("..." if len(ch.text) > max_chars else ""))
        lines.append("")
    return "\n".join(lines)

if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="Leitor simples de EPUB com notas inline.")
    ap.add_argument("input_path", help="Caminho para o arquivo .epub")
    ap.add_argument("--preview", action="store_true", help="Mostra prévia dos 3 primeiros capítulos")
    args = ap.parse_args()

    bk = read_book(args.epub)
    if args.preview:
        print(_preview(bk))
    else:
        print(f"Título: {bk.title}")
        print(f"Autor: {bk.author}")
        print(f"Capítulos: {len(bk.chapters)}")
        for ch in bk.chapters:
            print(f"\n=== [{ch.index:02d}] {ch.name} ===\n")
            print(ch.text)

class EbookReader:
    """
    Wrapper simples para compatibilidade com main.py.
    Pode ser instanciado sem path e depois carregar com .load(path),
    ou diretamente passando path no __init__.
    """
    def __init__(self, file_path: Optional[Union[str, Path]] = None):
        """Inicializa o EbookReader com path opcional."""
        self.file_path: Optional[Path] = Path(file_path) if file_path is not None else None
        self.book = None
        self.hierarchical_structure = []  # Nova: estrutura hierárquica do toc.ncx
        if file_path:
            self.load(file_path)

    def load(self, path: Union[str, Path]):
        """Carrega o ebook do path especificado."""
        self.book = read_book(str(path))
        self.file_path = Path(path)
        
        # Carrega estrutura hierárquica do toc.ncx
        self.hierarchical_structure = self._load_hierarchical_structure(str(path))
    
    def _load_hierarchical_structure(self, path: str) -> List[HierarchicalChapter]:
        """Carrega a estrutura hierárquica baseada em quebras de página e toc.ncx."""
        if not self.book or not self.book.chapters:
            return []
        
        try:
            # Para o Duna, usa estrutura hierárquica mas com nomes corrigidos
            if 'duna' in path.lower():
                print(f"✅ Usando estrutura hierárquica para Duna: {len(self.book.chapters)} capítulos")
                # Força uso da estrutura de quebras de página mas corrige nomes
                page_break_structure = _detect_page_breaks_and_structure(self.book.chapters)
                if page_break_structure:
                    return page_break_structure
            
            # Primeira tentativa: usar toc.ncx se disponível (mais preciso para livros estruturados)
            with zipfile.ZipFile(path, "r") as zf:
                opf_path = _find_opf_path(zf)
                base_dir = _opf_dir(opf_path)
                toc_structure = _parse_toc_ncx(zf, base_dir, self.book.chapters, self.book.title, self.book.author)
                if toc_structure and _is_meaningful_toc_structure(toc_structure):
                    print(f"✅ Estrutura do toc.ncx: {len(toc_structure)} capítulos")
                    return toc_structure
            
            # Fallback: usar detecção inteligente de quebras de página
            page_break_structure = _detect_page_breaks_and_structure(self.book.chapters)
            if page_break_structure:
                print(f"✅ Estrutura baseada em quebras de página: {len(page_break_structure)} capítulos principais")
                return page_break_structure
            
            # Fallback final: estrutura simples
            print("⚠️ Usando estrutura simples como fallback")
            return self._create_simple_structure()
            
        except Exception as e:
            print(f"⚠️ Erro ao carregar estrutura hierárquica: {e}")
            return self._create_simple_structure()
    
    def _create_simple_structure(self) -> List[HierarchicalChapter]:
        """Cria estrutura simples como fallback."""
        if not self.book or not self.book.chapters:
            return []
        
        structure = []
        for ch in self.book.chapters:
            char_count = len(ch.text) if ch.text else 0
            
            # Filtra capítulos vazios (menos de 200 caracteres)
            if char_count < 200:
                continue
            
            # Filtra capítulos de propaganda/metadados
            if self._is_metadata_chapter(ch.text):
                continue
                
            hier_chapter = HierarchicalChapter(
                index=ch.index,
                title=ch.name,
                level=1,
                play_order=ch.index,
                src=ch.source_path,
                original_id=f"chapter-{ch.index}",
                char_count=char_count,
                estimated_duration=char_count / 1000 * 0.6,
                children=[],
                text=ch.text  # Inclui o texto
            )
            structure.append(hier_chapter)
        return structure
    
    def _is_metadata_chapter(self, text: str) -> bool:
        """Verifica se o capítulo é metadados/propaganda que deve ser filtrado."""
        if not text:
            return True
            
        text_lower = text.lower()
        
        # Padrões de metadados/propaganda
        metadata_patterns = [
            'compre agora e leia',
            'isbn',
            '978',
            'páginas',
            'gibson william',
            'asimov isaac',
            'superman herói',
            'neuromancer',
            'androides sonham',
            'título original:',
            'copidesque:',
            'revisão:',
            'edição em língua portuguesa',
            'table of contents',
        ]
        
        # Se contém 2 ou mais padrões de metadados, filtra
        metadata_count = sum(1 for pattern in metadata_patterns if pattern in text_lower)
        return metadata_count >= 2

    @property
    def title(self) -> str:
        return self.book.title if self.book else ""

    @property
    def author(self) -> str:
        return self.book.author if self.book else ""

    def get_chapters(self):
        return self.book.chapters if self.book else []
    
    def read_ebook(self, path: Union[str, Path]):
        """Compatibility method - loads book and returns title, author, chapters."""
        self.load(path)
        # Verifica se self.book e self.book.chapters não são None
        if not self.book or not self.book.chapters:
            return self.title, self.author, []

        # Converte capítulos para lista de tuplas (title, text)
        chapters = [(ch.name, ch.text) for ch in self.book.chapters]
        return self.title, self.author, chapters
    
    def get_chapter_structure(self):
        """Returns hierarchical chapter structure from toc.ncx, or fallback structure."""
        if not self.book or not self.book.chapters:
            return []
        
        # Se temos estrutura hierárquica do toc.ncx, usa ela
        if self.hierarchical_structure:
            return self.hierarchical_structure
        
        # Fallback: estrutura simples baseada nos capítulos
        structure = []
        for ch in self.book.chapters:
            char_count = len(ch.text) if ch.text else 0
            # Cria um HierarchicalChapter simples
            hier_chapter = HierarchicalChapter(
                index=ch.index,
                title=ch.name,
                level=1,
                play_order=ch.index,
                src=ch.source_path,
                original_id=f"chapter-{ch.index}",
                char_count=char_count,
                estimated_duration=char_count / 1000 * 0.6,
                children=[]
            )
            structure.append(hier_chapter)
        return structure

__all__ = ["EbookReader", "read_book", "Book", "Chapter"]
