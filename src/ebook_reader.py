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
from typing import Dict, List, Optional, Tuple
from xml.etree import ElementTree as ET

XML_NS = {
    "ocf": "urn:oasis:names:tc:opendocument:xmlns:container",
    "opf": "http://www.idpf.org/2007/opf",
    "dc": "http://purl.org/dc/elements/1.1/",
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
    text = NBSP_RE.sub(" ", html)
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
    m = H_TAG.search(html)
    if not m:
        return None
    heading_html = m.group(2)
    return html_to_plain_text(heading_html) or None

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
                # Exibe um formato curto de nota. Você pode personalizar este prefixo/sufixo.
                # Ex: "[Nota: ...]" ou " (nota: ...) "
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
            name = extract_first_heading(raw_html) or os.path.basename(src_path)

            # Injeta notas inline
            html_with_notes = _inject_footnotes_inline(
                raw_html, html_by_path, id_index_by_path, current_path=src_path
            )

            # Converte para texto simples
            txt = html_to_plain_text(html_with_notes)

            # Ganchos de pausa/reticências (se quiser pausar após título, etc.)
            # Exemplo simples: insere uma pequena pausa (simulada por "...") após o título na primeira linha.
            # Você pode ajustar isso no pipeline de TTS para inserir SSML/pausas de verdade.
            if name and not txt.startswith(name):
                # Se o título não está incluso naturalmente no texto, prefixa com ele
                txt = f"{name}\n\n{txt}"
            # Adiciona reticências após o título para marcar pausa do TTS (customizável)
            if txt.startswith(name):
                txt = txt.replace(name, f"{name} ...", 1)

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
        """**Corrigido: Inicialização properly typed e não callable**"""
        self.file_path: Optional[Path] = Path(file_path) if file_path is not None else None

    def load(self, path: str):
        self.book = read_book(path)

    @property

    def __init__(self, path: str | None = None):
        self.book = None
        if path:
            self.load(path)

    def load(self, path: str):
        self.book = read_book(path)

    @property
    def title(self) -> str:
        return self.book.title if self.book else ""

    @property
    def author(self) -> str:
        return self.book.author if self.book else ""

    def get_chapters(self):
        return self.book.chapters if self.book else []

__all__ = ["EbookReader", "read_book", "Book", "Chapter"]
