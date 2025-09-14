# -*- coding: utf-8 -*-
"""
Enhanced EbookReader with TOC support and hierarchical chapters
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
PAGE_BREAK_RE = re.compile(r'page-break-before\s*:\s*always|page-break-after\s*:\s*always|break-before\s*:\s*page|break-after\s*:\s*page', re.I)

@dataclass
class Chapter:
    index: str  # Can be "1" or "1.1" for hierarchical
    name: str
    source_path: str
    text: str
    level: int = 1  # Chapter level (1, 2, 3...)

@dataclass  
class Book:
    title: str
    author: str
    chapters: List[Chapter]

@dataclass
class TocEntry:
    title: str
    href: str
    level: int = 1
    children: Optional[List['TocEntry']] = None

class EbookReader:
    """Enhanced ebook reader with TOC support"""

    def __init__(self, file_path: str):
        self.file_path = Path(file_path)
        self._book: Optional[Book] = None

    def _is_content_file(self, href: str, media_type: str) -> bool:
        """Check if a file should be processed as content (not CSS, images, etc.)"""
        # Filter by file extension
        href_lower = href.lower()
        content_extensions = {'.html', '.xhtml', '.htm', '.xml'}
        non_content_extensions = {'.css', '.js', '.jpg', '.jpeg', '.png', '.gif', '.svg',
                                '.bmp', '.webp', '.woff', '.woff2', '.ttf', '.otf', '.eot'}

        # Check file extension
        for ext in non_content_extensions:
            if href_lower.endswith(ext):
                return False

        # If it has a content extension, it's likely content
        for ext in content_extensions:
            if href_lower.endswith(ext):
                break
        else:
            # No recognized content extension, check media type
            if not media_type:
                return False

        # Filter by media type
        content_media_types = {
            'application/xhtml+xml',
            'text/html',
            'text/xml',
            'application/xml'
        }

        non_content_media_types = {
            'text/css',
            'application/javascript',
            'text/javascript',
            'application/x-javascript',
            'image/',  # Any image type
            'font/',   # Any font type
            'application/font'
        }

        if media_type:
            # Check for non-content media types
            for non_content in non_content_media_types:
                if media_type.startswith(non_content):
                    return False

            # Check for content media types
            if media_type in content_media_types:
                return True

        # Default: assume it's content if we can't determine otherwise
        return True

    def _is_css_content(self, text: str) -> bool:
        """Check if text content looks like CSS content"""
        if not text:
            return False

        text_lower = text.lower().strip()

        # Check for CSS patterns
        css_patterns = [
            r'@page\s*\{',  # @page rules
            r'@media\s*\(',  # @media queries
            r'@import\s+',   # @import statements
            r'@charset\s+',  # @charset declarations
            r'body\s*\{',    # body selectors
            r'\.[\w-]+\s*\{', # class selectors
            r'#[\w-]+\s*\{',  # id selectors
        ]

        # If multiple CSS patterns are found, likely CSS content
        css_pattern_count = 0
        for pattern in css_patterns:
            if re.search(pattern, text_lower):
                css_pattern_count += 1

        # Also check for common CSS properties
        css_properties = [
            'margin:', 'padding:', 'font-family:', 'text-align:', 'color:',
            'background:', 'border:', 'width:', 'height:', 'display:'
        ]

        css_property_count = 0
        for prop in css_properties:
            if prop in text_lower:
                css_property_count += 1

        # If we have CSS patterns and properties, it's likely CSS
        return css_pattern_count >= 1 and css_property_count >= 2

    @property
    def title(self) -> str:
        return self._ensure_loaded().title
        
    @property
    def author(self) -> str:
        return self._ensure_loaded().author
        
    def get_chapters(self) -> List[Chapter]:
        return self._ensure_loaded().chapters
        
    def get_chapter_structure(self) -> List[Chapter]:
        return self.get_chapters()
    
    def _ensure_loaded(self) -> Book:
        if not self._book:
            self._book = self._parse_epub() if self.file_path.suffix.lower() == '.epub' else self._parse_pdf()
        return self._book

    def _parse_epub(self) -> Book:
        import zipfile
        with zipfile.ZipFile(self.file_path, 'r') as zf:
            opf_path = self._find_opf(zf)
            manifest, spine, title, author = self._parse_opf(zf, opf_path)
            toc_entries = self._parse_toc(zf, manifest, opf_path)

            # Map hrefs do TOC para títulos
            toc_map = {}
            def flatten_toc(entries):
                for e in entries:
                    toc_map[e.href.split('#')[0]] = e.title
                    if e.children:
                        flatten_toc(e.children)
            flatten_toc(toc_entries)

            # Build division mapping for hierarchical structure
            division_map = {}  # Maps file index to (division_index, division_title)
            current_division = None

            # Analyze TOC to identify book divisions
            toc_files = []
            for entry in toc_entries:
                href = entry.href.split('#')[0]
                if self._looks_like_division(entry.title):
                    current_division = (len(toc_files) + 1, entry.title)
                toc_files.append((href, entry.title, current_division))

            # Create file to division mapping
            for i, (href, title, division) in enumerate(toc_files):
                if division:
                    division_map[href] = division

            opf_dir = '/'.join(opf_path.split('/')[:-1]) if '/' in opf_path else ''
            chapters = []
            chapter_index = 1
            current_division_info = None
            subchapter_counter = 1

            for item_id in spine:
                if item_id not in manifest:
                    continue

                item_info = manifest[item_id]
                href = item_info['href']
                media_type = item_info['media-type']

                # Skip non-content files (CSS, images, etc.)
                if not self._is_content_file(href, media_type):
                    continue

                full_path = f"{opf_dir}/{href}" if opf_dir else href
                try:
                    with zf.open(full_path, 'r') as f:
                        html_content = f.read().decode('utf-8', errors='ignore')
                        text_content = self._html_to_text(html_content)

                        # Check if this file starts a new division (before checking minimal content)
                        base_title = toc_map.get(href)

                        if base_title and self._looks_like_division(base_title):
                            # This is a division header (like "Livro primeiro")
                            current_division_info = (chapter_index, base_title)
                            subchapter_counter = 1
                            chapter_index += 1
                            continue

                        # Skip files with minimal or CSS-like content
                        if len(text_content.strip()) < 50:
                            continue

                        # Skip files that look like CSS content
                        if self._is_css_content(text_content):
                            continue

                        # If no TOC title, extract from content
                        if not base_title:
                            base_title = self._extract_first_words(text_content, 8)

                        # Subcapítulos por quebra de página
                        subcap_parts = self._split_by_page_breaks(html_content, text_content)
                        for i, (sub_html, sub_text) in enumerate(subcap_parts):
                            # Process all parts, even empty ones (images, etc.)
                            if len(sub_text.strip()) == 0:
                                # For empty text content, use the base title or indicate it's an image/empty page
                                sub_text = f"[{base_title}]" if base_title else "[Página vazia ou imagem]"

                            # Generate chapter name based on division context
                            if current_division_info:
                                # We are inside a division
                                division_index, division_title = current_division_info
                                if i == 0:
                                    idx = f"{division_index}.{subchapter_counter}"
                                    name = f"{division_title} - {self._extract_first_words(sub_text, 8)}"
                                else:
                                    idx = f"{division_index}.{subchapter_counter + i}"
                                    name = f"{division_title} - {self._extract_first_words(sub_text, 8)}"
                            else:
                                # Regular chapter
                                if i == 0:
                                    idx = f"{chapter_index}.0"
                                    name = base_title
                                else:
                                    idx = f"{chapter_index}.{i}"
                                    name = f"{base_title} - {self._extract_first_words(sub_text, 8)}"

                            chapters.append(Chapter(
                                index=idx,
                                name=name,
                                source_path=full_path,
                                text=sub_text,
                                level=1 if i == 0 else 2
                            ))

                        # Update counters
                        if current_division_info:
                            subchapter_counter += len(subcap_parts)
                        else:
                            chapter_index += 1
                except Exception as e:
                    print(f"Warning: Could not extract chapter from {full_path}: {e}")

            return Book(title or "Unknown", author or "Unknown", chapters)
    
    # (implementação removida, pois já existe uma versão corrigida acima)
    
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
    
    def _parse_opf(self, zf: zipfile.ZipFile, opf_path: str) -> Tuple[Dict[str, Dict[str, str]], List[str], str, str]:
        opf_content = zf.read(opf_path).decode('utf-8', errors='ignore')
        root = ET.fromstring(opf_content)
        # Extract metadata with better title handling
        title_elem = root.find('.//{http://www.idpf.org/2007/opf}title')
        dc_title_elem = root.find('.//{http://purl.org/dc/elements/1.1/}title')
        title = None
        if title_elem is not None and title_elem.text:
            title = title_elem.text.strip()
        elif dc_title_elem is not None and dc_title_elem.text:
            title = dc_title_elem.text.strip()
        if not title:
            title = "Unknown"
        author_elem = root.find('.//{http://purl.org/dc/elements/1.1/}creator')
        author = author_elem.text.strip() if author_elem is not None and author_elem.text else "Unknown"
        # Build manifest with media-type information
        manifest = {}
        for item in root.findall('.//{http://www.idpf.org/2007/opf}item'):
            item_id = item.get('id')
            href = item.get('href')
            media_type = item.get('media-type', '')
            if item_id and href:
                manifest[item_id] = {
                    'href': href,
                    'media-type': media_type
                }
        # Build spine
        spine = []
        for item in root.findall('.//{http://www.idpf.org/2007/opf}itemref'):
            idref = item.get('idref')
            if idref:
                spine.append(idref)
        return manifest, spine, title, author
    
    def _parse_toc(self, zf: zipfile.ZipFile, manifest: Dict[str, Dict[str, str]], opf_path: str) -> List[TocEntry]:
        """Parse EPUB TOC (table of contents)"""
        # Look for NCX file (traditional TOC)
        ncx_id = None
        for item_id, item_info in manifest.items():
            href = item_info['href']
            if href.endswith('.ncx'):
                ncx_id = item_id
                break

        if ncx_id and ncx_id in manifest:
            return self._parse_ncx_toc(zf, manifest[ncx_id]['href'], opf_path)

        # Look for nav.xhtml (EPUB3 TOC)
        nav_files = [item_info['href'] for item_info in manifest.values() if 'nav' in item_info['href'].lower() and item_info['href'].endswith('.xhtml')]
        if nav_files:
            return self._parse_nav_toc(zf, nav_files[0], opf_path)
        
        return []
    
    def _parse_ncx_toc(self, zf: zipfile.ZipFile, ncx_href: str, opf_path: str) -> List[TocEntry]:
        """Parse NCX (Navigation Control File) TOC"""
        try:
            opf_dir = '/'.join(opf_path.split('/')[:-1]) if '/' in opf_path else ''
            ncx_path = f"{opf_dir}/{ncx_href}" if opf_dir else ncx_href
            
            ncx_content = zf.read(ncx_path).decode('utf-8', errors='ignore')
            root = ET.fromstring(ncx_content)
            
            toc_entries = []
            for navPoint in root.findall('.//{http://www.daisy.org/z3986/2005/ncx/}navPoint'):
                title_elem = navPoint.find('.//{http://www.daisy.org/z3986/2005/ncx/}text')
                content_elem = navPoint.find('.//{http://www.daisy.org/z3986/2005/ncx/}content')
                
                if title_elem is not None and content_elem is not None:
                    title = title_elem.text.strip() if title_elem.text else f"Chapter {len(toc_entries)+1}"
                    href = content_elem.get('src', '').split('#')[0]  # Remove fragment
                    
                    if href:
                        toc_entries.append(TocEntry(title=title, href=href, level=1))
            
            return toc_entries
        except Exception as e:
            print(f"Warning: Could not parse NCX TOC: {e}")
            return []
    
    def _parse_nav_toc(self, zf: zipfile.ZipFile, nav_href: str, opf_path: str) -> List[TocEntry]:
        """Parse EPUB3 Navigation Document TOC"""
        try:
            opf_dir = '/'.join(opf_path.split('/')[:-1]) if '/' in opf_path else ''
            nav_path = f"{opf_dir}/{nav_href}" if opf_dir else nav_href
            
            nav_content = zf.read(nav_path).decode('utf-8', errors='ignore')
            # Remove namespaces for easier parsing
            nav_content = re.sub(r'xmlns[^=]*="[^"]*"', '', nav_content)
            root = ET.fromstring(nav_content)
            
            toc_entries = []
            # Look for nav element with epub:type="toc"
            nav_elem = root.find('.//nav[@*="toc"]') or root.find('.//nav')
            if nav_elem is not None:
                for li in nav_elem.findall('.//li'):
                    a_elem = li.find('.//a')
                    if a_elem is not None:
                        title = a_elem.text.strip() if a_elem.text else f"Chapter {len(toc_entries)+1}"
                        href = a_elem.get('href', '').split('#')[0]  # Remove fragment
                        
                        if href:
                            toc_entries.append(TocEntry(title=title, href=href, level=1))
            
            return toc_entries
        except Exception as e:
            print(f"Warning: Could not parse NAV TOC: {e}")
            return []
    
    def _extract_chapters_from_toc(self, zf: zipfile.ZipFile, manifest: Dict[str, Dict[str, str]], toc_entries: List[TocEntry], opf_path: str) -> List[Chapter]:
        """Extract chapters based on TOC structure with direct numbering"""
        chapters = []
        opf_dir = '/'.join(opf_path.split('/')[:-1]) if '/' in opf_path else ''
        chapter_counter = 1

        for entry in toc_entries:
            full_path = f"{opf_dir}/{entry.href}" if opf_dir else entry.href

            try:
                # Read the content of the chapter file
                with zf.open(full_path, 'r') as chapter_file:
                    html_content = chapter_file.read().decode('utf-8', errors='ignore')
                    text_content = self._html_to_text(html_content)

                    # Create a Chapter object
                    chapters.append(Chapter(
                        index=f"{chapter_counter}.0",
                        name=entry.title,
                        source_path=full_path,
                        text=text_content,
                        level=entry.level
                    ))

                    # Detect subchapters based on page breaks
                    subchapters = self._split_by_page_breaks(html_content, text_content)
                    for i, (sub_html, sub_text) in enumerate(subchapters):
                        subtitle = self._extract_first_words(sub_text, 8)
                        chapters.append(Chapter(
                            index=f"{chapter_counter}.{i + 1}",
                            name=f"{entry.title} - {subtitle}",
                            source_path=full_path,
                            text=sub_text,
                            level=entry.level + 1
                        ))
                    chapter_counter += 1
            except Exception as e:
                print(f"Warning: Could not extract chapter from {full_path}: {e}")

        return chapters
    
    def _extract_chapters_from_toc_with_spine_support(self, zf: zipfile.ZipFile, manifest: Dict[str, Dict[str, str]],
                                                     spine: List[str], toc_entries: List[TocEntry],
                                                     opf_path: str) -> List[Chapter]:
        """Extract chapters from TOC but use spine content when TOC entries are empty divisions"""
        chapters = []
        opf_dir = '/'.join(opf_path.split('/')[:-1]) if '/' in opf_path else ''
        spine_index = 0
        used_spine_content = set()  # Track used content to avoid duplication

        # Pre-analyze TOC to understand structure
        normal_entries = []  # Will be 1, 2, 3...
        book_divisions = []  # Will be I, II, III...

        for entry in toc_entries:
            if self._looks_like_division(entry.title):
                book_divisions.append(entry)
            else:
                normal_entries.append(entry)

        # Process book divisions first (I, II, III...)
        division_index = 1
        for entry in book_divisions:
            full_path = f"{opf_dir}/{entry.href}" if opf_dir else entry.href

            try:
                # Read the content of the division file
                with zf.open(full_path, 'r') as division_file:
                    html_content = division_file.read().decode('utf-8', errors='ignore')
                    text_content = self._html_to_text(html_content)

                    # Create a Chapter object for the division
                    chapters.append(Chapter(
                        index=f"{division_index}.0",
                        name=entry.title,
                        source_path=full_path,
                        text=text_content,
                        level=1
                    ))

                    # Detect subcapítulos dentro da divisão com base em quebras de página
                    subcap_parts = self._split_by_page_breaks(html_content, text_content)
                    for i, (sub_html, sub_text) in enumerate(subcap_parts):
                        chapters.append(Chapter(
                            index=f"{division_index}.{i + 1}",
                            name=f"{entry.title} - {self._extract_first_words(sub_text)}",
                            source_path=full_path,
                            text=sub_text,
                            level=2
                        ))

                    division_index += 1
            except Exception as e:
                print(f"Warning: Could not extract division from {full_path}: {e}")

        # Process normal entries (1, 2, 3...)
        chapter_index = division_index
        for entry in normal_entries:
            full_path = f"{opf_dir}/{entry.href}" if opf_dir else entry.href

            try:
                # Read the content of the chapter file
                with zf.open(full_path, 'r') as chapter_file:
                    html_content = chapter_file.read().decode('utf-8', errors='ignore')
                    text_content = self._html_to_text(html_content)

                    # Create a Chapter object
                    chapters.append(Chapter(
                        index=f"{chapter_index}.0",
                        name=entry.title,
                        source_path=full_path,
                        text=text_content,
                        level=1
                    ))
                    chapter_index += 1
            except Exception as e:
                print(f"Warning: Could not extract chapter from {full_path}: {e}")

        # Sort chapters numerically before returning
        return self._sort_chapters_numerically(chapters)
    
    def _extract_chapters_from_spine(self, zf: zipfile.ZipFile, manifest: Dict[str, Dict[str, str]],
                                   spine: List[str], opf_path: str) -> List[Chapter]:
        """Fallback: extract chapters from spine order"""
        chapters = []
        opf_dir = '/'.join(opf_path.split('/')[:-1]) if '/' in opf_path else ''
        
        for i, item_id in enumerate(spine):
            if item_id not in manifest:
                continue

            item_info = manifest[item_id]
            href = item_info['href']
            media_type = item_info['media-type']

            # Skip non-content files
            if not self._is_content_file(href, media_type):
                continue

            full_path = f"{opf_dir}/{href}" if opf_dir else href

            try:
                content = zf.read(full_path).decode('utf-8', errors='ignore')
                text = self._html_to_text(content)
                if text.strip() and len(text.strip()) > 100:
                    title = self._extract_title(content) or f"Chapter {i+1}"
                    chapters.append(Chapter(f"{i+1}.0", title, full_path, text))
            except:
                continue
                
        return chapters
    
    def _detect_subchapters(self, html_content: str, text_content: str, main_title: str) -> List[Tuple[str, str, Optional[str]]]:
        """Detect subchapters using multiple methods"""
        
        # Method 0: Special handling for diary/journal entries (dates, page breaks)
        diary_entries = self._split_by_diary_entries(html_content, text_content)
        if len(diary_entries) > 1:
            return diary_entries
        
        # Method 1: Page breaks
        page_break_parts = self._split_by_page_breaks(html_content, text_content)
        if len(page_break_parts) > 1:
            result = []
            for part_html, part_text in page_break_parts:
                subtitle = self._extract_title(part_html) or self._extract_first_words(part_text)
                result.append((part_html, part_text, subtitle))
            return result
        
        # Method 2: Multiple h1/h2/h3 headers indicating sections
        headers = re.findall(r'<h([1-3])[^>]*>(.*?)</h\1>', html_content, re.I | re.DOTALL)
        if len(headers) > 1:
            # Split by headers
            header_pattern = r'(<h[1-3][^>]*>.*?</h[1-3]>)'
            parts = re.split(header_pattern, html_content, flags=re.I | re.DOTALL)
            
            result = []
            current_content = ""
            current_title = None
            
            for part in parts:
                if re.match(r'<h[1-3]', part, re.I):
                    # This is a header
                    if current_content.strip():
                        # Save previous section
                        part_text = self._html_to_text(current_content)
                        if part_text.strip():
                            result.append((current_content, part_text, current_title))
                    
                    # Start new section
                    current_title = self._html_to_text(part)
                    current_content = part
                else:
                    # This is content
                    current_content += part
            
            # Add final section
            if current_content.strip():
                part_text = self._html_to_text(current_content)
                if part_text.strip():
                    result.append((current_content, part_text, current_title))
            
            if len(result) > 1:
                return result
        
        # Method 3: Always try to split content into natural sections
        sections = self._split_large_content_into_sections(html_content, text_content)
        if len(sections) > 1:
            return sections
        
        # Method 4: Look for numbered sections (1., 2., I., II., etc.)
        numbered_sections = re.split(r'\n\s*([IVXLC]+\.|[\d]+\.)\s*([^\n]+)\n', text_content)
        if len(numbered_sections) > 3:  # Original + at least one split creates 3+ parts
            result = []
            for i in range(1, len(numbered_sections), 3):  # Skip original, take number-title-content groups
                if i + 2 < len(numbered_sections):
                    number = numbered_sections[i]
                    title = numbered_sections[i + 1].strip()
                    content = numbered_sections[i + 2]
                    if content.strip():
                        # Reconstruct HTML approximation
                        section_html = f"<h3>{number} {title}</h3>{content}"
                        result.append((section_html, content.strip(), f"{number} {title}"))
            
            if len(result) > 1:
                return result
        
        # Default: single chapter
        subtitle = self._extract_title(html_content) or self._extract_first_words(text_content)
        return [(html_content, text_content, subtitle)]
        
    def _split_large_content_into_sections(self, html_content: str, text_content: str) -> List[Tuple[str, str, Optional[str]]]:
        """Split large content into natural reading sections"""
        
        # Method 1: Look for multiple large paragraph breaks (scene changes)
        # Split by double line breaks that might indicate scene changes
        paragraphs = re.split(r'\n\s*\n\s*\n+', text_content)  # Triple+ line breaks
        if len(paragraphs) > 2:
            sections = []
            for i, para in enumerate(paragraphs):
                if len(para.strip()) > 0:  # Accept ANY content
                    title = self._extract_first_words(para, 8)
                    sections.append((f"<div>{para}</div>", para.strip(), title))
            
            if len(sections) > 1:
                return sections
        
        # Method 2: Split by content length (for ANY long texts)
        if len(text_content) > 10000:  # Any moderately long content
            # Split into chunks of reasonable size
            chunk_size = 20000
            sections = []
            words = text_content.split()
            
            current_chunk: List[str] = []
            current_length = 0
            
            for word in words:
                current_chunk.append(word)
                current_length += len(word) + 1
                
                if current_length >= chunk_size:
                    # Try to break at sentence end
                    chunk_text = ' '.join(current_chunk)
                    # Find last sentence end
                    last_sentence = chunk_text.rfind('. ')
                    if last_sentence > chunk_size * 0.7:  # At least 70% through
                        chunk_text = chunk_text[:last_sentence + 1]
                        remaining = ' '.join(current_chunk)[last_sentence + 2:]
                        current_chunk = remaining.split() if remaining else []
                        current_length = len(remaining) if remaining else 0
                    else:
                        current_chunk = []
                        current_length = 0
                    
                    if chunk_text.strip():
                        title = self._extract_first_words(chunk_text, 8)
                        sections.append((f"<div>{chunk_text}</div>", chunk_text.strip(), title))
            
            # Add final chunk
            if current_chunk:
                final_text = ' '.join(current_chunk)
                if final_text.strip():
                    title = self._extract_first_words(final_text, 8)
                    sections.append((f"<div>{final_text}</div>", final_text.strip(), title))
            
            if len(sections) > 1:
                return sections
        
        # Default: return as single section
        subtitle = self._extract_first_words(text_content, 8)
        return [(html_content, text_content, subtitle)]
    
    def _split_by_page_breaks(self, html_content: str, text_content: str) -> List[Tuple[str, str]]:
        """Split content by page breaks"""
        # Look for page-break CSS or explicit page break elements
        if not PAGE_BREAK_RE.search(html_content):
            return [(html_content, text_content)]
        
        # Simple split by page break patterns
        parts = re.split(r'<[^>]*(?:page-break|break-)[^>]*>', html_content)
        if len(parts) <= 1:
            return [(html_content, text_content)]
        
        result = []
        for part in parts:
            if part.strip():
                part_text = self._html_to_text(part)
                if part_text.strip():
                    result.append((part, part_text))
        
        return result if result else [(html_content, text_content)]
    
    def _split_by_diary_entries(self, html_content: str, text_content: str) -> List[Tuple[str, str, Optional[str]]]:
        """Split content by diary entries, dates, and page breaks"""
        
        # Look for diary date patterns in headers or emphasized text
        # Common patterns: "5 de maio", "16 de agosto", etc. or numbered dates
        date_patterns = [
            # Portuguese/Brazilian dates
            r'<h[1-6][^>]*>.*?(\d+\s+de\s+\w+.*?)</h[1-6]>',
            r'<em[^>]*>.*?(\d+\s+de\s+\w+.*?)</em>',
            # Date with location
            r'<h[1-6][^>]*>.*?(\d+\s+de\s+\w+.*?(?:castelo|casa|hotel|na\s+\w+).*?)</h[1-6]>',
            r'<em[^>]*>.*?(\d+\s+de\s+\w+.*?(?:castelo|casa|hotel|na\s+\w+).*?)</em>',
            # English patterns for diary entries
            r'<h[1-6][^>]*>.*?(\w+\s+\d+.*?)</h[1-6]>',  # "May 5th", "August 16"
            r'<em[^>]*>.*?(\w+\s+\d+.*?)</em>',
            # Journal entry markers
            r'<h[1-6][^>]*>.*?(Diário de .*?)</h[1-6]>',
            r'<h[1-6][^>]*>.*?(Carta de .*?)</h[1-6]>',
            r'<h[1-6][^>]*>.*?(Memorando.*?)</h[1-6]>',
        ]
        
        # Also look for page break IDs that often indicate chapter/entry breaks
        page_break_pattern = r'id=["\']calibre_pb_\d+["\']'
        
        # Combine all patterns to find potential split points
        split_points = []
        
        # Find date headers
        for pattern in date_patterns:
            for match in re.finditer(pattern, html_content, re.I | re.DOTALL):
                split_points.append((match.start(), match.group(1).strip()))
        
        # Find page breaks with significant content
        for match in re.finditer(page_break_pattern, html_content):
            # Look for nearby text to see if this is a meaningful break
            start_pos = max(0, match.start() - 200)
            end_pos = min(len(html_content), match.end() + 200) 
            context = html_content[start_pos:end_pos]
            
            # Check if there's a date or header near this page break
            context_text = self._html_to_text(context)
            if (re.search(r'\d+\s+de\s+\w+', context_text, re.I) or 
                re.search(r'[Dd]iário|[Cc]arta|[Mm]emo', context_text, re.I) or
                re.search(r'[A-Z][a-z]+\s+\d+', context_text)):  # English dates
                split_points.append((match.start(), f"Entry {len(split_points)+1}"))
        
        # Sort by position and remove duplicates
        split_points = sorted(set(split_points), key=lambda x: x[0])
        
        if len(split_points) <= 1:
            return [(html_content, text_content, None)]
        
        # Split content at these points
        result = []
        prev_pos = 0
        
        for i, (pos, title) in enumerate(split_points):
            if i == 0:
                # First entry starts from beginning
                continue
            
            # Extract content from prev_pos to current pos
            section_html = html_content[prev_pos:pos]
            section_text = self._html_to_text(section_html)
            
            if len(section_text.strip()) > 50:  # Must have substantial content
                # Use the title from this split point
                prev_title = split_points[i-1][1] if i > 0 else title
                result.append((section_html, section_text.strip(), prev_title))
            
            prev_pos = pos
        
        # Add final section
        final_html = html_content[prev_pos:]
        final_text = self._html_to_text(final_html)
        if len(final_text.strip()) > 50:
            final_title = split_points[-1][1] if split_points else "Final Entry"
            result.append((final_html, final_text.strip(), final_title))
        
        # Return results only if we found meaningful splits
        return result if len(result) > 1 else [(html_content, text_content, None)]
    
    def _collect_split_files_for_chapter(self, zf: zipfile.ZipFile, manifest: Dict[str, Dict[str, str]],
                                       spine: List[str], chapter_href: str, opf_path: str,
                                       used_content: set) -> List[Tuple[str, str, str]]:
        """Collect all split files for a chapter (diary entries)"""
        opf_dir = '/'.join(opf_path.split('/')[:-1]) if '/' in opf_path else ''
        base_href = chapter_href.split('#')[0]  # Remove fragment
        
        # Find the base filename pattern (e.g., part0015_split_000.html -> part0015)
        if '_split_' in base_href:
            base_pattern = base_href.split('_split_')[0]
        else:
            # No splits for this chapter
            return []
        
        # Collect all split files for this base pattern
        split_files = []
        for item_id in spine:
            if item_id in manifest:
                item_info = manifest[item_id]
                href = item_info['href']
                if href.startswith(base_pattern) and '_split_' in href:
                    full_path = f"{opf_dir}/{href}" if opf_dir else href
                    if full_path not in used_content:
                        split_files.append((item_id, href, full_path))
        
        # Sort by split number
        def extract_split_num(item):
            try:
                return int(item[1].split('_split_')[1].split('.')[0])
            except:
                return 0
        
        split_files.sort(key=extract_split_num)
        
        # Process each split file
        result = []
        for i, (item_id, href, full_path) in enumerate(split_files):
            try:
                content = zf.read(full_path).decode('utf-8', errors='ignore')
                text = self._html_to_text(content)
                
                if len(text.strip()) > 50:  # Must have meaningful content
                    # Extract title from content
                    title = self._extract_diary_date_from_content(content) or f"Entry {i+1}"
                    result.append((title, text.strip(), full_path))
                    
            except Exception:
                continue
        
        return result if len(result) > 1 else []
    
    def _extract_diary_date_from_content(self, html_content: str) -> Optional[str]:
        """Extract diary date from HTML content"""
        # Look for date patterns in headers or emphasized text
        date_patterns = [
            r'<h[1-6][^>]*>.*?<em[^>]*>(.*?\d+\s+de\s+\w+.*?)</em>.*?</h[1-6]>',
            r'<h[1-6][^>]*>.*?(\d+\s+de\s+\w+.*?)</h[1-6]>',
            r'<em[^>]*>.*?(\d+\s+de\s+\w+.*?)</em>',
            # English patterns
            r'<h[1-6][^>]*>.*?<em[^>]*>([A-Z][a-z]+\s+\d+.*?)</em>.*?</h[1-6]>',
            r'<h[1-6][^>]*>.*?([A-Z][a-z]+\s+\d+.*?)</h[1-6]>',
            # Diary/Journal markers
            r'<h[1-6][^>]*>.*?(Diário de .*?)</h[1-6]>',
            r'<h[1-6][^>]*>.*?(Carta de .*?)</h[1-6]>',
        ]
        
        for pattern in date_patterns:
            match = re.search(pattern, html_content, re.I | re.DOTALL)
            if match:
                date_text = self._html_to_text(match.group(1))
                return date_text.strip()
        
        return None
    
    def _looks_like_division(self, title: str) -> bool:
        """Check if title looks like a book division rather than a real chapter"""
        if not title:
            return False

        title_lower = title.lower().strip()

        # Portuguese patterns for book divisions
        division_patterns = [
            r'^livro\s+[ivx]+$',  # Livro I, II, III...
            r'^livro\s+(primeiro|segundo|terceiro|quarto|quinto|sexto|sétimo|oitavo|nono|décimo)$',  # Livro primeiro, segundo, etc.
            r'^parte\s+[ivx\d]+$',  # Parte I, 1, etc
            r'^parte\s+(primeira|segunda|terceira|quarta|quinta)$',  # Parte primeira, segunda, etc.
            r'^seção\s+[ivx\d]+$',  # Seção I, 1, etc
            r'^capítulo\s*$',  # Just "Capítulo" without number/title
            # English patterns
            r'^book\s+[ivx\d]+$',  # Book I, 1, etc (English)
            r'^book\s+(one|two|three|four|five|six|seven|eight|nine|ten)$',  # Book one, two, etc
            r'^part\s+[ivx\d]+$',  # Part I, 1, etc (English)
        ]

        # Check exact patterns first
        for pattern in division_patterns:
            if re.match(pattern, title_lower):
                return True

        # More flexible patterns for Portuguese
        if (re.search(r'\blivro\s+(primeiro|segundo|terceiro|quarto|quinto)\b', title_lower) or
            re.search(r'\blivro\s+[ivx]+\b', title_lower)):
            return True

        return False
    
    def _extract_real_chapters_from_division(self, html_content: str, text_content: str, division_title: str) -> List[Tuple[str, str]]:
        """Extract real chapters from a book division that has minimal direct content"""
        
        # Method 1: Look for chapter markers in the spine following this division
        # This requires checking the next few files in the spine that might contain the real chapters
        # For now, let's work with the content we have
        
        # Method 2: Look for strong chapter indicators in the HTML
        chapter_patterns = [
            # Roman numerals at start of line/paragraph
            r'<(?:p|h[1-6])[^>]*>\s*([IVXLC]+)\.?\s*([^<\n]*?)(?:</(?:p|h[1-6])>|<br|$)',
            # Arabic numbers at start  
            r'<(?:p|h[1-6])[^>]*>\s*(\d+)\.?\s*([^<\n]*?)(?:</(?:p|h[1-6])>|<br|$)',
            # Chapter word with number
            r'<(?:p|h[1-6])[^>]*>\s*(?:capítulo|chapter)\s+([ivxlc\d]+)\.?\s*([^<\n]*?)(?:</(?:p|h[1-6])>|<br|$)',
        ]
        
        chapters = []
        
        for pattern in chapter_patterns:
            matches = re.findall(pattern, html_content, re.I | re.MULTILINE)
            if len(matches) > 1:  # Found multiple chapters
                # Split content by these chapters
                split_pattern = pattern.replace('([IVXLC]+)', '([IVXLC]+)').replace('([ivxlc\\d]+)', '([ivxlc\\d]+)').replace('([^<\\n]*?)', '([^<\\n]*?)')
                parts = re.split(pattern, html_content, flags=re.I | re.MULTILINE)
                
                current_chapter = ""
                current_title = None
                
                for i, part in enumerate(parts):
                    if i == 0:
                        # Skip content before first chapter
                        continue
                    elif i % 3 == 1:  # Chapter number
                        # Save previous chapter
                        if current_title and current_chapter:
                            chapter_text = self._html_to_text(current_chapter)
                            if len(chapter_text.strip()) > 100:  # Minimum content
                                chapters.append((current_title, chapter_text))
                        
                        # Start new chapter
                        current_title = f"Capítulo {part}"
                        current_chapter = ""
                    elif i % 3 == 2:  # Chapter title (if any)
                        if part.strip():
                            if current_title:
                                current_title += f" - {part.strip()}"
                    else:  # Chapter content
                        current_chapter = part
                
                # Add final chapter
                if current_title and current_chapter:
                    chapter_text = self._html_to_text(current_chapter)
                    if len(chapter_text.strip()) > 100:
                        chapters.append((current_title, chapter_text))
                
                if len(chapters) > 1:
                    return chapters
        
        # Method 3: Look for paragraph-based chapter breaks (less reliable)
        paragraphs = re.split(r'</p>\s*<p[^>]*>', html_content)
        if len(paragraphs) > 5:  # Enough content to potentially have chapters
            # Look for paragraphs that start with numbers or roman numerals
            potential_chapters = []
            current_chapter_content = []
            current_chapter_title = None
            
            for p in paragraphs:
                p_text = self._html_to_text(f"<p>{p}</p>").strip()
                if not p_text:
                    continue
                
                # Check if this paragraph starts a new chapter
                chapter_start = re.match(r'^([IVXLC\d]+)\.?\s*(.{0,50}?)(?:\.|$)', p_text, re.I)
                if chapter_start and len(p_text) < 200:  # Likely a chapter title
                    # Save previous chapter
                    if current_chapter_title and current_chapter_content:
                        chapter_text = '\n\n'.join(current_chapter_content)
                        if len(chapter_text.strip()) > 200:
                            potential_chapters.append((current_chapter_title, chapter_text))
                    
                    # Start new chapter
                    current_chapter_title = f"Capítulo {chapter_start.group(1)}"
                    if chapter_start.group(2).strip():
                        current_chapter_title += f" - {chapter_start.group(2).strip()}"
                    current_chapter_content = []
                else:
                    # Add to current chapter
                    if p_text:
                        current_chapter_content.append(p_text)
            
            # Add final chapter
            if current_chapter_title and current_chapter_content:
                chapter_text = '\n\n'.join(current_chapter_content)
                if len(chapter_text.strip()) > 200:
                    potential_chapters.append((current_chapter_title, chapter_text))
            
            if len(potential_chapters) > 1:
                return potential_chapters
        
        return []  # No clear chapter structure found
    
    def _extract_first_words(self, text: str, max_words: int = 6) -> str:
        """Extract first words from text content"""
        if not text or not text.strip():
            return ""
        
        clean_text = re.sub(r'\s+', ' ', text.strip())
        words = clean_text.split()[:max_words]
        return ' '.join(words)
    
    def _parse_pdf(self) -> Book:
        if not PDF_AVAILABLE:
            raise ImportError("pypdf not available for PDF parsing")
            
        with open(self.file_path, 'rb') as f:
            reader = pypdf.PdfReader(f)
            
            # Extract metadata
            info = reader.metadata or {}
            title = str(info.get('/Title', self.file_path.stem))
            author = str(info.get('/Author', 'Unknown'))
            
            # Extract chapters from pages
            chapters = []
            for i, page in enumerate(reader.pages):
                text = page.extract_text().strip()
                if text:
                    chapter_title = self._extract_first_words(text) or f"Page {i+1}"
                    chapters.append(Chapter(f"{i+1}.0", chapter_title, f"page_{i+1}", text))
                    
            return Book(title, author, chapters)
    
    def _html_to_text(self, html: str) -> str:
        if not html:
            return ""
        # Remove title tags
        text = re.sub(r'<title[^>]*>.*?</title>', '', html, re.I | re.DOTALL)
        # Remove CSS style tags and their content
        text = re.sub(r'<style[^>]*>.*?</style>', '', text, re.I | re.DOTALL)
        # Remove script tags and their content
        text = re.sub(r'<script[^>]*>.*?</script>', '', text, re.I | re.DOTALL)
        # Replace non-breaking spaces
        text = re.sub(r"&nbsp;|\u00A0", " ", text, flags=re.I)
        text = PARA_RE.sub("\n", text)
        text = TAG_RE.sub("", text)
        text = WHITESPACE_RE.sub(" ", text)
        return re.sub(r"\n\s*\n\s*", "\n\n", text.strip()).strip()
    
    def _extract_title(self, html: str) -> Optional[str]:
        match = H_TAG.search(html)
        return self._html_to_text(match.group(2)) if match else None
    
    def _extract_chapter_title_from_content(self, text: str) -> Optional[str]:
        """Extract meaningful chapter title from content text"""
        if not text or not text.strip():
            return None
        
        # Clean text and get sentences
        clean_text = re.sub(r'\s+', ' ', text.strip())
        sentences = re.split(r'[.!?]+', clean_text)
        
        if not sentences:
            return None
        
        # Get first meaningful sentence (skip very short ones)
        first_sentence = None
        for sentence in sentences:
            sentence = sentence.strip()
            if len(sentence) > 10 and not sentence.isdigit():
                first_sentence = sentence
                break
        
        if not first_sentence:
            # Fallback to first words if no good sentence found
            words = clean_text.split()[:8]
            return ' '.join(words) if words else None
        
        # Truncate if too long and clean up
        if len(first_sentence) > 60:
            # Find a good break point
            words = first_sentence[:60].split()
            if len(words) > 1:
                first_sentence = ' '.join(words[:-1]) + "..."
            else:
                first_sentence = first_sentence[:60] + "..."
        
        return first_sentence
    
    def _force_split_large_text(self, text: str, chunk_size: int = 15000) -> List[str]:
        """Force split large text into reasonable chunks"""
        if len(text) <= chunk_size:
            return [text]

        chunks = []
        words = text.split()
        current_chunk: List[str] = []
        current_length = 0

        for word in words:
            if current_length + len(word) + 1 > chunk_size:
                chunks.append(' '.join(current_chunk))
                current_chunk = []
                current_length = 0

            current_chunk.append(word)
            current_length += len(word) + 1

        if current_chunk:
            chunks.append(' '.join(current_chunk))

        return chunks
    
    def _sort_chapters_numerically(self, chapters: List[Chapter]) -> List[Chapter]:
        """Sort chapters numerically based on their index."""
        def chapter_key(chapter: Chapter):
            # Split the index into parts (e.g., '3.1' -> [3, 1])
            return [int(part) for part in chapter.index.split('.')]

        return sorted(chapters, key=chapter_key)

