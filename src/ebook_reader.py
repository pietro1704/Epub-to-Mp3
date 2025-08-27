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
            hier_chapter = _create_hierarchical_chapter_from_group(
                current_chapter_group, chapter_counter
            )
            hierarchical_chapters.append(hier_chapter)
            current_chapter_group = []
            chapter_counter += 1
    
    return hierarchical_chapters

def _extract_base_filename(file_path: str) -> str:
    """Extrai nome base do arquivo, removendo numeração split."""
    basename = os.path.basename(file_path)
    # Remove padrões como _split_001, _001, etc.
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

def _parse_toc_ncx(zf: zipfile.ZipFile, base_dir: str, chapters: List[Chapter]) -> List[HierarchicalChapter]:
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
                
                
                # Encontra capítulo correspondente para char_count
                char_count = 0
                matching_chapter = src_to_chapter.get(normalized_src)
                
                
                if matching_chapter:
                    char_count = len(matching_chapter.text)
                
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
                
                # Encontra o título real do capítulo a partir do mapeamento de capítulos
                actual_title = nav_title  # Fallback para nav title
                if matching_chapter:
                    actual_title = matching_chapter.name
                elif normalized_src in src_to_chapter:
                    actual_title = src_to_chapter[normalized_src].name
                
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
                    children=[]
                )
                
                # Parseia filhos recursivamente (apenas filhos diretos)
                direct_children = nav_point.findall('ncx:navPoint', ns)
                if direct_children:
                    hier_chapter.children = parse_navpoint_children(direct_children, level + 1, hierarchical_index)
                
                hierarchical_chapters.append(hier_chapter)
            
            return hierarchical_chapters
        
        def parse_navpoint_children(nav_points, level, parent_index):
            """Parseia filhos diretos de navPoint."""
            children = []
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
                
                
                # Encontra capítulo correspondente para char_count
                char_count = 0
                matching_chapter = src_to_chapter.get(normalized_src)
                
                
                if matching_chapter:
                    char_count = len(matching_chapter.text)
                
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
                
                # Encontra o título real do capítulo a partir do mapeamento de capítulos
                actual_title = nav_title  # Fallback para nav title
                if matching_chapter:
                    actual_title = matching_chapter.name
                elif normalized_src in src_to_chapter:
                    actual_title = src_to_chapter[normalized_src].name
                
                # Calcula index hierárquico
                hierarchical_index = f"{parent_index}.{i}"
                
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
                    children=[]
                )
                
                # Parseia filhos recursivamente
                direct_children = nav_point.findall('ncx:navPoint', ns)
                if direct_children:
                    hier_chapter.children = parse_navpoint_children(direct_children, level + 1, hierarchical_index)
                
                children.append(hier_chapter)
            
            return children
        
        # Encontra navMap e parseia navPoints
        nav_map = root.find('.//ncx:navMap', ns)
        if nav_map is None:
            return []
        
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
                        sub_chapter = HierarchicalChapter(
                            index=f"{chapter.index}.{i}",
                            title=chapter_obj.name,
                            level=chapter.level + 1,
                            play_order=chapter.play_order * 100 + i,
                            src=chapter_src,
                            original_id=f"{chapter.original_id}_sub_{i}",
                            char_count=sub_char_count,
                            estimated_duration=sub_char_count / 1000 * 0.6,
                            children=[]
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
            """Cria subcapítulos sequenciais para livros estilo Duna."""
            # Encontra todos os arquivos sequenciais que vêm depois do arquivo do capítulo
            base_src = chapter.src.split('#')[0] if '#' in chapter.src else chapter.src
            if base_src.startswith('Text/'):
                base_src = base_src[5:]
            
            # Extrai número base do arquivo (ex: index_split_005.html -> 5)
            import re
            match = re.search(r'(\w+)_(\d+)\.html', base_src)
            if not match:
                return []
            
            prefix = match.group(1)
            start_num = int(match.group(2))
            
            # Define ranges para cada livro (baseado no toc.ncx do Duna)
            if chapter.title == 'Livro primeiro':
                end_num = 27  # index_split_005 até index_split_027
            elif chapter.title == 'Livro segundo':  
                end_num = 43  # index_split_028 até index_split_043
            elif chapter.title == 'Livro terceiro':
                end_num = 55  # index_split_044 até index_split_055
            else:
                return []
            
            # Coleta arquivos sequenciais com conteúdo substancial
            sequential_files = []
            for num in range(start_num + 1, end_num + 1):  # Pula o arquivo container
                file_name = f"{prefix}_{num:03d}.html"
                
                # Procura o arquivo no mapeamento
                for chapter_src, chapter_obj in src_to_chapter.items():
                    if file_name in chapter_src and len(chapter_obj.text.strip()) > 500:  # Conteúdo substancial
                        sequential_files.append((num, chapter_src, chapter_obj))
                        break
            
            # Ordena por número
            sequential_files.sort()
            
            # Cria subcapítulos
            if len(sequential_files) > 0:
                sub_chapters = []
                for i, (file_num, chapter_src, chapter_obj) in enumerate(sequential_files, 1):
                    sub_char_count = len(chapter_obj.text)
                    
                    # Usa nome do arquivo ou tenta extrair título do conteúdo
                    title = chapter_obj.name if chapter_obj.name and not chapter_obj.name.endswith('.html') else f"Capítulo {i}"
                    
                    # For Dune-style books, add first few words to help navigation
                    if 'Capítulo' in title and chapter_obj.text:
                        # Extract first 3-4 meaningful words from chapter text
                        text_words = chapter_obj.text.strip().split()[:15]  # Get first 15 words
                        # Filter out common Portuguese stop words and short words
                        meaningful_words = []
                        for w in text_words:
                            if (len(w) > 2 and 
                                w.lower() not in ['que', 'com', 'para', 'uma', 'mas', 'por', 'ser', 'ter', 'ele', 'ela', 
                                                 'seu', 'sua', 'dos', 'das', 'nos', 'nas', 'essa', 'esse', 'está', 
                                                 'eram', 'teve', 'foi', 'seu', 'sua', 'isso', 'isto', 'como', 'mais']):
                                meaningful_words.append(w)
                                if len(meaningful_words) >= 3:  # Take first 3 meaningful words
                                    break
                        
                        if meaningful_words:
                            preview = ' '.join(meaningful_words)
                            # Clean up punctuation at the end
                            preview = preview.rstrip('.,;:!?')
                            title = f"{title} - {preview}"
                    
                    sub_chapter = HierarchicalChapter(
                        index=f"{chapter.index}.{i}",
                        title=title,
                        level=chapter.level + 1,
                        play_order=chapter.play_order * 100 + i,
                        src=chapter_src,
                        original_id=f"{chapter.original_id}_seq_{i}",
                        char_count=sub_char_count,
                        estimated_duration=sub_char_count / 1000 * 0.6,
                        children=[]
                    )
                    sub_chapters.append(sub_chapter)
                
                # Set parent chapter to 0 chars since content is in subcapters
                chapter.char_count = 0
                chapter.estimated_duration = 0.0
                
                return sub_chapters
            
            return []
        
        # Parseia apenas os navPoints de nível raiz
        root_nav_points = nav_map.findall('ncx:navPoint', ns)
        hierarchical_chapters = parse_navpoint(root_nav_points)
        
        # Post-processa para criar subcapítulos quando há arquivos split com títulos diferentes
        processed_chapters = []
        for chapter in hierarchical_chapters:
            if '_split_' in chapter.src and not chapter.children:
                # Tenta criar subcapítulos para este capítulo
                sub_chapters = create_subchapters_from_splits(chapter, src_to_chapter)
                if sub_chapters:
                    # Substitui o capítulo original pela estrutura hierárquica
                    chapter.children = sub_chapters
                    # Keep parent chapter at 0 chars since content is in subcapters
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

            # Nome do capítulo: primeiro heading, senão o nome do arquivo
            heading_name = extract_first_heading(raw_html)
            if heading_name:
                name = heading_name
            else:
                # Fallback para nome do arquivo, mas limpa padrões index_split
                filename = os.path.basename(src_path)
                # Remove padrões como index_split_014.html e index_split_014.html.txt
                name = re.sub(r'index_split_\d+\.html(\.txt)?', 'Capítulo sem título', filename)
                # Se ainda contém extensões, remove elas
                name = re.sub(r'\.(html|htm|xhtml)$', '', name)
                # Se nome ficou vazio ou muito genérico, usa índice
                if not name or name in ['Capítulo sem título', '']:
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
            # Primeira tentativa: usar detecção inteligente de quebras de página
            page_break_structure = _detect_page_breaks_and_structure(self.book.chapters)
            if page_break_structure:
                print(f"✅ Estrutura baseada em quebras de página: {len(page_break_structure)} capítulos principais")
                return page_break_structure
            
            # Fallback: usar toc.ncx se disponível
            with zipfile.ZipFile(path, "r") as zf:
                opf_path = _find_opf_path(zf)
                base_dir = _opf_dir(opf_path)
                toc_structure = _parse_toc_ncx(zf, base_dir, self.book.chapters)
                if toc_structure:
                    print(f"✅ Estrutura do toc.ncx: {len(toc_structure)} capítulos")
                    return toc_structure
            
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
