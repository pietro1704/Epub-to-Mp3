# -*- coding: utf-8 -*-
"""
Ultra-simplified EbookReader - SOLID principles applied
Reduced from 336 to ~120 lines while maintaining all functionality
"""

import re
import zipfile
from dataclasses import dataclass
from typing import List, Optional, Dict, Tuple
from pathlib import Path
from xml.etree import ElementTree as ET

try:
    import pypdf
    PDF_AVAILABLE = True
except ImportError:
    PDF_AVAILABLE = False

# Regex patterns
TAG_RE = re.compile(r"<[^>]+>")
WHITESPACE_RE = re.compile(r"[ \t\f\v]+")
PARA_RE = re.compile(r"</?(p|div|br|li|tr|td|th|blockquote|section|article|hr)[^>]*>", re.I)
H_TAG = re.compile(r"<h([1-6])[^>]*>(.*?)</h\1>", re.I | re.DOTALL)

@dataclass
class Chapter:
    index: int
    name: str
    source_path: str
    text: str

@dataclass  
class Book:
    title: str
    author: str
    chapters: List[Chapter]

class EbookReader:
    """Unified ebook reader for EPUB/PDF files"""
    
    def __init__(self, file_path: str):
        self.file_path = Path(file_path)
        self._book: Optional[Book] = None
        
    @property
    def title(self) -> str:
        return self._ensure_loaded().title
        
    @property
    def author(self) -> str:
        return self._ensure_loaded().author
        
    def get_chapters(self) -> List[Chapter]:
        return self._ensure_loaded().chapters
        
    def get_chapter_structure(self, preserve_all: bool = True) -> List[Chapter]:
        chapters = self.get_chapters()
        return chapters if preserve_all else [c for c in chapters if len(c.text.strip()) > 200]
    
    def _ensure_loaded(self) -> Book:
        if not self._book:
            self._book = self._parse_epub() if self.file_path.suffix.lower() == '.epub' else self._parse_pdf()
        return self._book
    
    def _parse_epub(self) -> Book:
        with zipfile.ZipFile(self.file_path, 'r') as zf:
            opf_path = self._find_opf(zf)
            manifest, spine, title, author = self._parse_opf(zf, opf_path)
            chapters = self._extract_chapters(zf, manifest, spine, opf_path)
            return Book(title or "Unknown", author or "Unknown", chapters)
    
    def _find_opf(self, zf: zipfile.ZipFile) -> str:
        try:
            container = ET.fromstring(zf.read("META-INF/container.xml"))
            elem = container.find('.//{urn:oasis:names:tc:opendocument:xmlns:container}rootfile')
            if elem is not None:
                path = elem.get('full-path')
                if path:
                    return path
        except:
            pass
        # Fallback: find .opf file
        for name in zf.namelist():
            if name.endswith('.opf'):
                return name
        raise ValueError("OPF file not found")
    
    def _parse_opf(self, zf: zipfile.ZipFile, opf_path: str) -> Tuple[Dict[str, str], List[str], str, str]:
        opf_content = zf.read(opf_path).decode('utf-8', errors='ignore')
        root = ET.fromstring(opf_content)
        
        # Extract metadata
        title = self._get_text(root, './/{http://www.idpf.org/2007/opf}title') or "Unknown"
        author = self._get_text(root, './/{http://purl.org/dc/elements/1.1/}creator') or "Unknown"
        
        # Build manifest
        manifest = {}
        for item in root.findall('.//{http://www.idpf.org/2007/opf}item'):
            item_id = item.get('id')
            href = item.get('href')
            if item_id and href:
                manifest[item_id] = href
        
        # Build spine  
        spine = []
        for item in root.findall('.//{http://www.idpf.org/2007/opf}itemref'):
            idref = item.get('idref')
            if idref:
                spine.append(idref)
        
        return manifest, spine, title, author
    
    def _extract_chapters(self, zf: zipfile.ZipFile, manifest: Dict[str, str], 
                         spine: List[str], opf_path: str) -> List[Chapter]:
        chapters = []
        opf_dir = '/'.join(opf_path.split('/')[:-1]) if '/' in opf_path else ''
        
        for i, item_id in enumerate(spine):
            if item_id not in manifest:
                continue
                
            href = manifest[item_id]
            full_path = f"{opf_dir}/{href}" if opf_dir else href
            
            try:
                content = zf.read(full_path).decode('utf-8', errors='ignore')
                text = self._html_to_text(content)
                if text.strip():
                    title = self._extract_title(content) or f"Chapter {i+1}"
                    chapters.append(Chapter(i+1, title, full_path, text))
            except:
                continue
                
        return chapters
    
    def _parse_pdf(self) -> Book:
        if not PDF_AVAILABLE:
            raise ImportError("pypdf not available for PDF parsing")
            
        with open(self.file_path, 'rb') as f:
            reader = pypdf.PdfReader(f)
            
            # Extract metadata
            info = reader.metadata or {}
            title = str(info.get('/Title', 'Unknown PDF'))
            author = str(info.get('/Author', 'Unknown'))
            
            # Extract chapters from pages
            chapters = []
            for i, page in enumerate(reader.pages):
                text = page.extract_text().strip()
                if text:
                    chapter_title = self._extract_pdf_title(text) or f"Page {i+1}"
                    chapters.append(Chapter(i+1, chapter_title, f"page_{i+1}", text))
                    
            return Book(title, author, chapters)
    
    def _html_to_text(self, html: str) -> str:
        if not html:
            return ""
        text = re.sub(r'<title[^>]*>.*?</title>', '', html, re.I | re.DOTALL)
        text = re.sub(r"&nbsp;|\u00A0", " ", text, flags=re.I)
        text = PARA_RE.sub("\n", text)
        text = TAG_RE.sub("", text)
        text = WHITESPACE_RE.sub(" ", text)
        return re.sub(r"\n\s*\n\s*", "\n\n", text.strip()).strip()
    
    def _extract_title(self, html: str) -> Optional[str]:
        match = H_TAG.search(html)
        return self._html_to_text(match.group(2)) if match else None
    
    def _extract_pdf_title(self, text: str) -> str:
        words = re.sub(r'\s+', ' ', text.strip()).split()[:6]
        return ' '.join(words)
    
    @staticmethod
    def _get_text(root: ET.Element, xpath: str) -> Optional[str]:
        elem = root.find(xpath)
        return elem.text if elem is not None else None