from pathlib import Path
from typing import List, Tuple, Optional, Union

from ebooklib import epub
import ebooklib
from bs4 import BeautifulSoup


class EbookReader:
    def __init__(self, file_path: Optional[Union[str, Path]] = None):
        self.file_path: Optional[Path] = Path(file_path) if file_path is not None else None

    def read(self, file_path: Optional[Union[str, Path]] = None) -> Tuple[str, Optional[str], List[Tuple[str, str]]]:
        if file_path is not None:
            self.file_path = Path(file_path)

        if self.file_path is None or not self.file_path.exists():
            raise FileNotFoundError(f"Arquivo não encontrado ou não informado corretamente: {self.file_path}")

        book = epub.read_epub(str(self.file_path))
        title = self._extract_title(book) or self.file_path.stem
        author = self._extract_author(book)
        chapters = self._extract_toc(book) or self._extract_from_spine(book) or self._extract_all_documents(book)
        return title, author, chapters

    def read_ebook(self, file_path: Optional[Union[str, Path]] = None):
        return self.read(file_path)

        # ADICIONE dentro da classe EbookReader:

    def _inline_footnotes(self, soup: "BeautifulSoup") -> None:
        """
        Converte notas de rodapé (div.footnotes, classes/ids com 'footnote', links âncora)
        em texto inline no próprio parágrafo, no formato:
        -- nota de rodapé número N: ... -- fim da nota --
        """
        from bs4 import NavigableString
        import re

        # 1) Colete possíveis notas: id -> texto da nota (limpo)
        notes_map = {}

        # a) Notas em blocos tipo <div class="footnotes"> ... >
        for fn_container in soup.select(".footnotes, .footnote, div[class*=footnote]"):
            # pega todos <a id="footnote-..."> ou qualquer elemento com id contendo 'footnote'
            for el in fn_container.select("[id*=footnote]"):
                note_id = el.get("id")
                if not note_id:
                    continue
                # texto "plano" da nota
                note_text = el.get_text(separator=" ").strip()
                # remova sups, números entre colchetes no começo
                note_text = re.sub(r"^\s*\[\d+\]\s*", "", note_text)
                notes_map[note_id] = note_text

        # b) Alguns epubs não têm o bloco; tente todo elemento com id~footnote
        if not notes_map:
            for el in soup.select("[id*=footnote]"):
                note_id = el.get("id")
                if not note_id:
                    continue
                note_text = el.get_text(separator=" ").strip()
                notes_map[note_id] = note_text

        # 2) Substitua cada referência <a href="#footnote-x"> por texto inline
        for a in soup.find_all("a", href=True):
            href = a["href"]
            if href.startswith("#"):
                target = href[1:]
                # às vezes o href aponta para ...-1 e o "id" da nota é sem "-backlink" (e vice-versa)
                candidates = {target, target.replace("-backlink", ""), f"{target}-backlink"}
                found_text = None
                number_for_voice = None

                # tente extrair número da própria âncora ([1]), para falar "número 1"
                m = re.search(r"\[(\d+)\]", a.get_text())
                if m:
                    number_for_voice = m.group(1)

                for cand in candidates:
                    if cand in notes_map:
                        found_text = notes_map[cand]
                        break

                if found_text:
                    spoken = f" -- nota de rodapé número {number_for_voice or ''}: {found_text} -- fim da nota -- "
                    a.replace_with(NavigableString(spoken))

    def _compose_chapter_text_with_title(self, chap_title: str, soup: "BeautifulSoup") -> str:
        """
        Retorna texto com o título na primeira linha seguido de uma pausa ' ... '
        e o conteúdo do capítulo abaixo. Mantém quebras de parágrafo e remove linhas vazias repetidas.
        """
        # já vem com notas inline
        text = soup.get_text(separator="\n")
        lines = [ln.strip() for ln in text.splitlines()]
        # remove linhas vazias duplicadas
        compact = []
        for ln in lines:
            if ln or (compact and compact[-1] != ""):
                compact.append(ln)
        body = "\n".join(compact).strip()
        # título + pausa para TTS (piper não usa SSML; a reticência ajuda a dar respiro)
        return f"{chap_title} ...\n\n{body}\n"

    def _sanitize_title(self, title: str) -> str:
        import re
        title = title.strip()
        # troca caracteres ilegais em nomes de arquivo
        title = re.sub(r"[\\/:*?\"<>|]", "_", title)
        return title if title else "Sem título"


    # ---------- Metadados ----------
    def _extract_title(self, book) -> Optional[str]:
        md = book.get_metadata('DC', 'title')
        return md[0][0].strip() if md else None

    def _extract_author(self, book) -> Optional[str]:
        md = book.get_metadata('DC', 'creator')
        return md[0][0].strip() if md else None

    def _extract_toc(self, book) -> List[Tuple[str, str]]:
        """Extrai capítulos a partir da TOC (toc.ncx/nav). Retorna lista (titulo, texto)."""
        chapters = []
        try:
            toc = book.toc  # disponível no ebooklib
            for entry in toc:
                if isinstance(entry, tuple):
                    # (titulo, item)
                    title = self._sanitize_title(str(entry[0]))
                    item = entry[1]
                    if hasattr(item, "get_content"):
                        chap = self._extract_chapter_from_item(item)
                        if chap:
                            chapters.append((title, chap[1]))
                else:
                    # Alguns casos vêm direto como Link ou Section
                    if hasattr(entry, "title") and hasattr(entry, "href"):
                        title = self._sanitize_title(entry.title)
                        # achar item pelo href
                        item = book.get_item_with_href(entry.href)
                        if item:
                            chap = self._extract_chapter_from_item(item)
                            if chap:
                                chapters.append((title, chap[1]))
        except Exception:
            pass
        return chapters

    def _sanitize_title(self, title: str) -> str:
        """Remove caracteres inválidos para nome de arquivo."""
        import re
        title = title.strip()
        title = re.sub(r"[\\/:*?\"<>|]", "_", title)  # caracteres ilegais no FS
        return title if title else "Sem título"


    # ---------- Extração de capítulos ----------
    def _extract_from_spine(self, book) -> List[Tuple[str, str]]:
        """Segue a ordem do spine quando possível."""
        id_to_item = {item.get_id(): item for item in book.get_items_of_type(ebooklib.ITEM_DOCUMENT)}
        chapters: List[Tuple[str, str]] = []

        # book.spine é uma lista de tuplas: [(idref, attrs_dict), ...] ou [(idref, ), ...]
        for spine_entry in getattr(book, "spine", []):
            idref = spine_entry[0] if isinstance(spine_entry, (list, tuple)) and spine_entry else None
            item = id_to_item.get(idref)
            if item:
                chap = self._extract_chapter_from_item(item)
                if chap:
                    chapters.append(chap)

        # Se não coletou nada via spine, retorna vazio para cair no fallback
        return chapters

    def _extract_all_documents(self, book) -> List[Tuple[str, str]]:
        """Fallback: percorre todos os documentos do tipo HTML/XHTML."""
        chapters: List[Tuple[str, str]] = []
        for item in book.get_items_of_type(ebooklib.ITEM_DOCUMENT):
            chap = self._extract_chapter_from_item(item)
            if chap:
                chapters.append(chap)
        return chapters

    def _extract_chapter_from_item(self, item) -> Optional[Tuple[str, str]]:
        # Conteúdo HTML
        html = item.get_content()
        soup = BeautifulSoup(html, "html.parser")

        # Remove scripts/estilos
        for tag in soup(["script", "style", "noscript"]):
            tag.decompose()

        # Título do capítulo (primeiro h1/h2/h3 razoável, senão <title>, senão nome do arquivo)
        heading = soup.find(["h1", "h2", "h3"])
        if heading:
            chap_title = heading.get_text(strip=True)
        else:
            title_tag = soup.find("title")
            chap_title = title_tag.get_text(strip=True) if title_tag else item.get_name()

        # Texto: usa separador de quebras para preservar parágrafos
        text = soup.get_text(separator="\n")
        text = "\n".join(line.strip() for line in text.splitlines())
        text = "\n".join(line for line in text.splitlines() if line)  # remove linhas vazias duplicadas

        # Filtra documentos vazios ou “técnicos”
        if not text or len(text) < 100:
            return None

        return chap_title, text
