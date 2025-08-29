# -*- coding: utf-8 -*-
"""
Simple EPUB reader - extracts text with proper chapter numbering
"""
import os
import re
import zipfile
from dataclasses import dataclass
from typing import List, Optional
from xml.etree import ElementTree as ET

@dataclass
class SimpleChapter:
    index: str          # "1", "1.1", "1.2", etc.
    title: str
    text: str
    char_count: int
    
    @property
    def level(self) -> int:
        """Returns chapter level (1, 2, 3...) based on dots in index"""
        return self.index.count('.') + 1

def read_epub_simple(epub_path: str, parse_html_subchapters: bool = False) -> List[SimpleChapter]:
    """
    Reads EPUB maintaining original TOC numbering and detecting subchapters via HTML parsing.
    Each subchapter becomes a separate TXT/MP3 file.
    """
    from ebook_reader import EbookReader
    
    reader = EbookReader(epub_path)
    
    if parse_html_subchapters:
        # Use TOC structure and parse HTML for subchapters
        return _parse_toc_with_html_subchapters(reader, epub_path)
    else:
        # Simple fallback: use hierarchical structure
        hierarchical_chapters = reader.get_chapter_structure()
        chapters = []
        
        def process_hierarchy(hier_chapters, parent_index=""):
            for i, hier_ch in enumerate(hier_chapters, 1):
                index = f"{parent_index}.{i}" if parent_index else hier_ch.title or str(i)
                
                chapter = SimpleChapter(
                    index=index,
                    title=hier_ch.title,
                    text="",
                    char_count=hier_ch.char_count
                )
                chapters.append(chapter)
                
                if hier_ch.children:
                    process_hierarchy(hier_ch.children, index)
        
        process_hierarchy(hierarchical_chapters)
        return chapters

def _parse_toc_with_html_subchapters(reader, epub_path: str) -> List[SimpleChapter]:
    """
    Parse TOC structure and detect subchapters via HTML analysis.
    Uses 3 methods: HTML tags, file changes, formatted text patterns.
    Sequential numbering: 1, 2, 3, 4... for ALL TOC entries.
    """
    import zipfile
    
    hierarchical_chapters = reader.get_chapter_structure()
    all_chapters = []
    chapter_number = 1
    
    def process_chapter_recursive(hier_ch, parent_title=""):
        nonlocal chapter_number
        
        # Build hierarchical title
        if parent_title:
            full_title = f"{parent_title} - {hier_ch.title}"
        else:
            full_title = hier_ch.title
        
        # ALWAYS process this chapter first, regardless of whether it has children
        if hier_ch.char_count > 0:
            # This chapter has content - parse it for subchapters
            subchapters = _parse_chapter_html_for_subchapters(hier_ch, zf, reader)
            
            # Renumber subchapters with global sequential numbering
            for i, subch in enumerate(subchapters):
                if len(subchapters) == 1:
                    # Single chapter - use simple numbering and enhanced title
                    subch.index = str(chapter_number)
                    # Use first words of content for generic chapter titles
                    enhanced_title = _enhance_chapter_title(full_title, subch.text)
                    subch.title = enhanced_title
                else:
                    # Multiple subchapters - use dot notation
                    subch.index = f"{chapter_number}.{i+1}"
                    enhanced_title = _enhance_chapter_title(full_title, subch.text)
                    subch.title = f"{enhanced_title}.{i+1}"
                    
            all_chapters.extend(subchapters)
            chapter_number += 1
        
        # THEN process children (if any) - pass current title as parent
        if hier_ch.children:
            for child_idx, child in enumerate(hier_ch.children, 1):
                # Create a copy of the child with corrected title
                import copy
                corrected_child = copy.copy(child)
                
                # Fix chapter numbering - extract original number and renumber
                if "Capítulo" in child.title:
                    corrected_child.title = f"Capítulo {child_idx}"
                
                process_chapter_recursive(corrected_child, full_title)
    
    with zipfile.ZipFile(epub_path, 'r') as zf:
        for hier_ch in hierarchical_chapters:
            process_chapter_recursive(hier_ch)
    
    return all_chapters

def _parse_chapter_html_for_subchapters(hier_chapter, zf: zipfile.ZipFile, reader) -> List[SimpleChapter]:
    """
    Parse a single chapter's HTML content to detect subchapters using 3 methods:
    1. HTML page break tags
    2. File changes (different HTML files)  
    3. Formatted text patterns (dates, headings, etc.)
    """
    # Get HTML content for this chapter
    html_files = _get_html_files_for_chapter(hier_chapter, zf)
    
    if not html_files:
        # No HTML found, return single chapter
        return [SimpleChapter(
            index=hier_chapter.title or "1",
            title=hier_chapter.title or "Chapter",
            text=_get_text_for_chapter(hier_chapter, reader),
            char_count=hier_chapter.char_count
        )]
    
    # Parse HTML files for subchapters
    subchapters = []
    
    if len(html_files) == 1:
        # Single HTML file - parse internal breaks
        subchapters = _parse_single_html_for_subchapters(html_files[0], hier_chapter, zf)
    else:
        # Multiple HTML files - each file is potentially a subchapter
        subchapters = _parse_multiple_html_files(html_files, hier_chapter, zf)
    
    return subchapters

def _get_html_files_for_chapter(hier_chapter, zf: zipfile.ZipFile) -> List[str]:
    """Get all HTML files that belong to this chapter."""
    if not hier_chapter.src:
        return []
    
    # Start with the main source file
    main_src = hier_chapter.src.split('#')[0]
    html_files = []
    
    # Try to find the actual file path
    possible_paths = [
        main_src,
        f"text/{main_src}",
        f"Text/{main_src}",
        f"OEBPS/{main_src}"
    ]
    
    for path in possible_paths:
        if path in zf.namelist():
            html_files.append(path)
            break
    
    # Look for related split files (part0001_split_000.html, part0001_split_001.html, etc.)
    if html_files:
        base_path = html_files[0]
        
        # Extract base name - handle files that are already split files
        if '_split_' in base_path:
            # File is already a split file like "text/part0015_split_000.html"
            # Extract base: "text/part0015"
            base_name = base_path.split('_split_')[0]
        else:
            # Regular file, just remove .html
            base_name = base_path.replace('.html', '')
        
        # Handle split files intelligently
        if '_split_' in base_path:
            # Extract the split number
            split_num = int(base_path.split('_split_')[1].split('.')[0])
            
            # Try to collect 1-2 additional sequential splits only if current file is very small
            # This prevents overlap while ensuring complete content
            current_size = 0
            try:
                current_content = zf.read(base_path).decode('utf-8')
                current_size = len(current_content)
            except:
                pass
            
            if current_size < 1000:  # Only collect more if current file is small
                next_split = f"{base_name}_split_{split_num + 1:03d}.html"
                if next_split in zf.namelist():
                    html_files.append(next_split)
            # This ensures we get sequential content for all split-based chapters
        else:
            # Check for all split files starting from 000 only for non-split sources
            split_counter = 0
            while True:
                split_path = f"{base_name}_split_{split_counter:03d}.html"
                if split_path in zf.namelist():
                    if split_path not in html_files:
                        html_files.append(split_path)
                    split_counter += 1
                else:
                    break
    
    return html_files

def _parse_single_html_for_subchapters(html_path: str, hier_chapter, zf: zipfile.ZipFile) -> List[SimpleChapter]:
    """Parse a single HTML file for internal subchapter breaks."""
    try:
        html_content = zf.read(html_path).decode('utf-8')
    except:
        return [SimpleChapter(
            index=hier_chapter.title or "1",
            title=hier_chapter.title or "Chapter", 
            text="",
            char_count=0
        )]
    
    return _parse_single_html_for_subchapters_from_content(html_content, hier_chapter)

def _parse_single_html_for_subchapters_from_content(html_content: str, hier_chapter) -> List[SimpleChapter]:
    """Parse HTML content for internal subchapter breaks - MAXIMUM separation."""
    
    # Method 1: Look for page break tags
    page_breaks = _find_page_break_tags(html_content)
    
    # Method 2: Look for formatted chapter/date patterns
    text_breaks = _find_formatted_text_breaks(html_content)
    
    # Combine and sort all breaks
    all_breaks = page_breaks + text_breaks
    all_breaks = sorted(set(all_breaks))  # Remove duplicates and sort
    
    # Allow many breaks for maximum separation - no artificial limits
    
    if not all_breaks:
        # No breaks found, return single chapter
        text_content = _html_to_text(html_content)
        return [SimpleChapter(
            index=hier_chapter.title or "1",
            title=hier_chapter.title or "Chapter",
            text=text_content,
            char_count=len(text_content)
        )]
    
    # Split HTML into subchapters based on breaks
    subchapters = []
    prev_pos = 0
    
    for i, break_pos in enumerate(all_breaks + [len(html_content)], 1):
        section_html = html_content[prev_pos:break_pos]
        section_text = _html_to_text(section_html)
        
        if len(section_text.strip()) > 50:  # Allow smaller chapters for maximum separation
            # Extract title from section
            section_title = _extract_section_title(section_html) or f"Seção {i}"
            
            subchapter = SimpleChapter(
                index=f"{hier_chapter.title}.{i}",
                title=section_title,
                text=section_text,
                char_count=len(section_text)
            )
            subchapters.append(subchapter)
        
        prev_pos = break_pos
    
    return subchapters

def _parse_multiple_html_files(html_files: List[str], hier_chapter, zf: zipfile.ZipFile) -> List[SimpleChapter]:
    """Parse multiple HTML files - combine them and detect subchapters within."""
    # Combine all HTML files into one content
    combined_html_content = ""
    
    for html_path in html_files:
        try:
            html_content = zf.read(html_path).decode('utf-8')
            combined_html_content += html_content + "\n"
        except:
            continue
    
    if not combined_html_content.strip():
        return []
    
    # Now parse the combined HTML for subchapters using the same logic as single file
    return _parse_single_html_for_subchapters_from_content(combined_html_content, hier_chapter)

def _find_page_break_tags(html_content: str) -> List[int]:
    """Find positions of HTML page break tags."""
    import re
    
    break_patterns = [
        r'<hr[^>]*>',  # Horizontal rules
        r'<div[^>]*page-break[^>]*>',  # Page break divs
        r'<p[^>]*page-break[^>]*>',   # Page break paragraphs  
        r'<br[^>]*page-break[^>]*>',  # Page break line breaks
        r'<div[^>]*class="[^"]*break[^"]*"[^>]*>',  # Break classes
    ]
    
    positions = []
    for pattern in break_patterns:
        for match in re.finditer(pattern, html_content, re.IGNORECASE):
            positions.append(match.start())
    
    return positions

def _find_formatted_text_breaks(html_content: str) -> List[int]:
    """Find positions where formatted text indicates chapter breaks."""
    import re
    
    # MAXIMUM separation patterns - detect many more breaks
    chapter_patterns = [
        r'<h[1-6][^>]*>[^<]{3,100}</h[1-6]>',  # ALL headings H1-H6
        r'<p[^>]*><strong>[^<]{5,100}</strong></p>',  # ANY bold text
        r'<p[^>]*><em>[^<]{5,100}</em></p>',  # ANY italic text
        r'<p[^>]*class="[^"]*chapter[^"]*"[^>]*>',  # Chapter paragraphs
        r'<div[^>]*class="[^"]*chapter[^"]*"[^>]*>',  # Chapter divs
        r'<p[^>]*><strong>[0-9]+\s+de\s+\w+[^<]*</strong></p>',  # Bold dates
        r'<p[^>]*><em>Diário de[^<]*</em></p>',  # Diary entries
        r'<p[^>]*><b>[^<]{3,50}</b></p>',  # Bold tags
        r'<center[^>]*>[^<]{5,50}</center>',  # Centered text
        r'<div[^>]*style="[^"]*text-align:\s*center[^"]*"[^>]*>[^<]{5,50}</div>',  # Centered divs
        # Text-based patterns for common separators
        r'(LIVRO|Livro|PARTE|Parte|CAPÍTULO|Capítulo|Chapter)\s+(PRIMEIRO|primeiro|SEGUNDO|segundo|TERCEIRO|terceiro|[IVX]+|\d+)',
    ]
    
    positions = []
    for pattern in chapter_patterns:
        for match in re.finditer(pattern, html_content, re.IGNORECASE):
            positions.append(match.start())
    
    return positions

def _enhance_chapter_title(base_title: str, text_content: str) -> str:
    """Enhance chapter title with first words of content - no filtering."""
    
    # Add first words of content, no filtering whatsoever
    if text_content and text_content.strip():
        # Just get first 3-4 words exactly as they are
        words = text_content.strip().split()[:4]
        if words:
            first_words = ' '.join(words)[:40]
            return f"{base_title} - {first_words}"
    
    return base_title

def _extract_section_title(html_content: str) -> str:
    """Extract title from HTML section - language agnostic."""
    import re
    
    # Try different title extraction methods
    title_patterns = [
        r'<h[1-4][^>]*>([^<]{3,50})</h[1-4]>',  # Headings
        r'<strong>([^<]{5,50})</strong>',  # Any bold text
        r'<em>([^<]{5,50})</em>',  # Any italic text
        r'<title>([^<]{3,50})</title>',  # Title tags
    ]
    
    for pattern in title_patterns:
        match = re.search(pattern, html_content, re.IGNORECASE)
        if match:
            title = match.group(1).strip()
            # Clean up title
            title = re.sub(r'^\W+|\W+$', '', title)  # Remove leading/trailing punctuation
            if len(title) > 3:
                return title
    
    # If no heading found, extract first words from text content
    text_content = _html_to_text(html_content)
    if text_content:
        # Get first 3-4 words, up to 40 characters
        words = text_content.split()[:4]
        if words:
            first_words = ' '.join(words)[:40].strip()
            if first_words:
                return first_words
    
    return ""

def _get_text_for_chapter(hier_chapter, reader) -> str:
    """Get text content for a hierarchical chapter by matching with original chapters."""
    orig_chapters = reader.get_chapters()
    
    # Try to match by title or source
    for orig_ch in orig_chapters:
        if (hier_chapter.title and hier_chapter.title in orig_ch.name) or \
           (hier_chapter.src and hier_chapter.src.split('/')[-1] in orig_ch.source_path):
            return orig_ch.text
    
    return ""

def _expand_chapters_with_html_parsing(chapters: List[SimpleChapter], reader, epub_path: str) -> List[SimpleChapter]:
    """
    Parse HTML content to detect subchapters in chapters like I, II, III, etc.
    Also extract better names for part00xxx_split chapters.
    """
    expanded_chapters = []
    
    with zipfile.ZipFile(epub_path, 'r') as zf:
        for chapter in chapters:
            # Check if this is a Roman numeral chapter (I, II, III, etc.) that might have subchapters
            if _is_roman_numeral_chapter(chapter.title) and chapter.char_count > 1000:
                subchapters = _parse_html_for_subchapters(chapter, zf, reader)
                if subchapters:
                    # Add main chapter as container
                    main_ch = SimpleChapter(
                        index=chapter.index,
                        title=chapter.title,
                        text="",  # Container chapter, no text
                        char_count=0
                    )
                    expanded_chapters.append(main_ch)
                    expanded_chapters.extend(subchapters)
                else:
                    expanded_chapters.append(chapter)
            
            # Extract better names for part00xxx_split chapters
            elif "part0" in chapter.title and "_split" in chapter.title:
                better_title = _extract_title_from_html(chapter, zf, reader)
                if better_title:
                    chapter.title = better_title
                expanded_chapters.append(chapter)
            
            else:
                expanded_chapters.append(chapter)
    
    return expanded_chapters

def _is_roman_numeral_chapter(title: str) -> bool:
    """Check if title is a Roman numeral (I, II, III, IV, V, etc.)"""
    roman_pattern = r'^(I|II|III|IV|V|VI|VII|VIII|IX|X|XI|XII|XIII|XIV|XV|XVI|XVII|XVIII|XIX|XX|XXI|XXII|XXIII|XXIV|XXV|XXVI|XXVII)$'
    return bool(re.match(roman_pattern, title.strip()))

def _parse_html_for_subchapters(chapter: SimpleChapter, zf: zipfile.ZipFile, reader) -> List[SimpleChapter]:
    """
    Parse HTML content to find subchapters like '3 de maio', '4 de maio', etc.
    """
    # Find the HTML source for this chapter
    html_content = _get_html_content_for_chapter(chapter, zf, reader)
    if not html_content:
        return []
    
    # Look for date patterns, headings, or other subchapter markers
    subchapter_patterns = [
        r'<h[1-4][^>]*>([^<]+de\s+\w+[^<]*)</h[1-4]>',  # "3 de maio" style dates
        r'<p[^>]*><strong>([^<]+de\s+\w+[^<]*)</strong></p>',  # Bold dates
        r'<p[^>]*>([0-9]+\s+de\s+\w+.*?)</p>',  # Paragraph with dates
        r'<h[1-4][^>]*>([A-Z][^<]{5,40})</h[1-4]>',  # Other headings
    ]
    
    subchapters = []
    for i, pattern in enumerate(subchapter_patterns):
        matches = re.findall(pattern, html_content, re.IGNORECASE)
        if matches and len(matches) >= 2:  # At least 2 subchapters
            # Split content by these markers
            parts = re.split(pattern, html_content, flags=re.IGNORECASE)
            
            for j, match in enumerate(matches, 1):
                # Try to extract the content for this subchapter
                subchapter_text = _extract_subchapter_content(html_content, match, j == len(matches))
                
                if subchapter_text and len(subchapter_text.strip()) > 100:
                    subchapter = SimpleChapter(
                        index=f"{chapter.index}.{j}",
                        title=match.strip(),
                        text=_html_to_text(subchapter_text),
                        char_count=len(_html_to_text(subchapter_text))
                    )
                    subchapters.append(subchapter)
            
            if subchapters:  # If we found subchapters with first pattern, stop
                break
    
    return subchapters

def _get_html_content_for_chapter(chapter: SimpleChapter, zf: zipfile.ZipFile, reader) -> str:
    """Get raw HTML content for a chapter"""
    # Try to find the HTML file that corresponds to this chapter
    hierarchical_chapters = reader.get_chapter_structure()
    
    # Find the hierarchical chapter that matches
    def find_hier_chapter(hier_list, target_index):
        for hc in hier_list:
            if str(hc.play_order) == target_index or hc.title == chapter.title:
                return hc
            if hc.children:
                result = find_hier_chapter(hc.children, target_index)
                if result:
                    return result
        return None
    
    hier_ch = find_hier_chapter(hierarchical_chapters, chapter.index)
    if not hier_ch or not hier_ch.src:
        return ""
    
    # Read the HTML file
    src_path = hier_ch.src.split('#')[0]  # Remove fragment
    possible_paths = [
        src_path,
        f"text/{src_path}",
        f"Text/{src_path}",
        f"OEBPS/{src_path}"
    ]
    
    for path in possible_paths:
        if path in zf.namelist():
            try:
                return zf.read(path).decode('utf-8')
            except:
                continue
    
    return ""

def _extract_subchapter_content(html_content: str, marker: str, is_last: bool) -> str:
    """Extract content for a specific subchapter between markers"""
    # Find the position of this marker
    marker_pos = html_content.lower().find(marker.lower())
    if marker_pos == -1:
        return ""
    
    # Find the next marker or end of content
    remaining_content = html_content[marker_pos:]
    
    # Look for the next heading or strong tag to find the end
    next_marker_patterns = [
        r'<h[1-4][^>]*>',
        r'<p[^>]*><strong>',
        r'<strong>[0-9]+\s+de\s+'
    ]
    
    end_pos = len(remaining_content)
    for pattern in next_marker_patterns:
        match = re.search(pattern, remaining_content[len(marker):], re.IGNORECASE)
        if match:
            end_pos = match.start() + len(marker)
            break
    
    return remaining_content[:end_pos]

def _extract_title_from_html(chapter: SimpleChapter, zf: zipfile.ZipFile, reader) -> str:
    """Extract better title from HTML content for part00xxx_split chapters"""
    html_content = _get_html_content_for_chapter(chapter, zf, reader)
    if not html_content:
        return ""
    
    # Look for title patterns in HTML
    title_patterns = [
        r'<h[1-4][^>]*>([^<]{5,60})</h[1-4]>',  # Headings
        r'<title>([^<]{5,60})</title>',  # Title tag
        r'<p[^>]*><strong>([^<]{5,60})</strong></p>',  # Bold paragraphs
    ]
    
    for pattern in title_patterns:
        matches = re.findall(pattern, html_content, re.IGNORECASE)
        if matches:
            # Take the first meaningful title
            for match in matches:
                clean_title = match.strip()
                if (len(clean_title) > 5 and 
                    not clean_title.lower().startswith('drácula') and
                    not 'part0' in clean_title.lower()):
                    return clean_title
    
    return ""

def _group_diary_entries(chapters: List[SimpleChapter]) -> List[SimpleChapter]:
    """
    Group diary entries and date-based chapters into hierarchical structure.
    Creates chapters like:
    - I (container)
      - I.1: 5 de maio
      - I.2: 7 de maio  
    - II (container)
      - II.1: 15 de agosto
    etc.
    """
    grouped_chapters = []
    current_roman_chapter = None
    roman_counter = 1
    subchapter_counter = 1
    
    # Roman numerals for chapter grouping
    roman_numerals = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X', 
                      'XI', 'XII', 'XIII', 'XIV', 'XV', 'XVI', 'XVII', 'XVIII', 'XIX', 'XX',
                      'XXI', 'XXII', 'XXIII', 'XXIV', 'XXV', 'XXVI', 'XXVII']
    
    i = 0
    while i < len(chapters):
        chapter = chapters[i]
        
        # Check if this is a date-based diary entry that should be grouped
        if _is_diary_entry(chapter):
            # Start a new roman chapter if needed
            if current_roman_chapter is None:
                roman_numeral = roman_numerals[roman_counter - 1] if roman_counter <= len(roman_numerals) else f"Cap {roman_counter}"
                current_roman_chapter = SimpleChapter(
                    index=str(roman_counter),
                    title=roman_numeral,
                    text="",  # Container chapter
                    char_count=0
                )
                grouped_chapters.append(current_roman_chapter)
                subchapter_counter = 1
            
            # Create subchapter
            subchapter = SimpleChapter(
                index=f"{roman_counter}.{subchapter_counter}",
                title=chapter.title,
                text=chapter.text,
                char_count=chapter.char_count
            )
            grouped_chapters.append(subchapter)
            subchapter_counter += 1
            
            # Check if we should start a new roman chapter
            # Look ahead to see if there's a significant gap or different character
            if i + 1 < len(chapters):
                next_chapter = chapters[i + 1]
                if (_should_start_new_roman_chapter(chapter, next_chapter) or 
                    subchapter_counter > 10):  # Max 10 subchapters per roman chapter
                    current_roman_chapter = None
                    roman_counter += 1
        
        else:
            # Non-diary entry - add as regular chapter
            grouped_chapters.append(chapter)
            current_roman_chapter = None  # Reset roman chapter grouping
        
        i += 1
    
    return grouped_chapters

def _is_diary_entry(chapter: SimpleChapter) -> bool:
    """Check if chapter is a diary entry based on title patterns."""
    title_lower = chapter.title.lower()
    
    # Date patterns
    date_patterns = [
        r'\d+\s+de\s+\w+',  # "5 de maio"
        r'\d+º\s+de\s+\w+',  # "1º de outubro"
        r'\w+,\s+\d+\s+de\s+\w+',  # "segunda, 5 de maio"
    ]
    
    for pattern in date_patterns:
        if re.search(pattern, chapter.title):
            return True
    
    # Diary-specific titles
    diary_indicators = [
        'diário de',
        'diario de',
        'diary of',
        'continuação',
        'mais tarde',
        'noite',
        'manhã',
        'madrugada'
    ]
    
    return any(indicator in title_lower for indicator in diary_indicators)

def _should_start_new_roman_chapter(current_chapter: SimpleChapter, next_chapter: SimpleChapter) -> bool:
    """Determine if we should start a new roman chapter based on content patterns."""
    
    # If next chapter is not a diary entry, end current roman chapter
    if not _is_diary_entry(next_chapter):
        return True
    
    # Look for character changes in diary entries
    current_text = current_chapter.text.lower()
    next_text = next_chapter.text.lower()
    
    # Different characters (Harker vs Seward vs Mina, etc.)
    characters = ['harker', 'seward', 'mina', 'lucy', 'van helsing', 'godalming', 'morris']
    
    current_char = None
    next_char = None
    
    for char in characters:
        if char in current_text:
            current_char = char
        if char in next_text:
            next_char = char
    
    # If different characters, start new chapter
    if current_char and next_char and current_char != next_char:
        return True
    
    # Look for significant time gaps (different months)
    current_month = _extract_month(current_chapter.title)
    next_month = _extract_month(next_chapter.title)
    
    if current_month and next_month and current_month != next_month:
        month_order = ['maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro']
        try:
            current_idx = month_order.index(current_month)
            next_idx = month_order.index(next_month)
            if next_idx > current_idx:  # Moved to next month
                return True
        except ValueError:
            pass
    
    return False

def _extract_month(title: str) -> str:
    """Extract month from title if present."""
    months = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho',
              'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro']
    
    title_lower = title.lower()
    for month in months:
        if month in title_lower:
            return month
    return ""

def _parse_toc_simple(zf: zipfile.ZipFile, toc_content: str, base_dir: str) -> List[SimpleChapter]:
    """Parse toc.ncx maintaining hierarchy with simple logic"""
    chapters = []
    
    try:
        root = ET.fromstring(toc_content)
        nav_points = root.findall('.//{http://www.daisy.org/z3986/2005/ncx/}navPoint')
        
        # Build hierarchy map: parent_id -> [children]
        hierarchy = {}
        nav_data = {}
        
        for nav_point in nav_points:
            nav_id = nav_point.get('id', '')
            play_order = int(nav_point.get('playOrder', 0))
            
            # Get title
            label = nav_point.find('.//{http://www.daisy.org/z3986/2005/ncx/}text')
            title = label.text.strip() if label is not None else f"Chapter {play_order}"
            
            # Get source file
            content = nav_point.find('.//{http://www.daisy.org/z3986/2005/ncx/}content')
            src = content.get('src', '') if content is not None else ''
            
            nav_data[nav_id] = {
                'title': title,
                'src': src,
                'play_order': play_order,
                'element': nav_point
            }
            
            # Find if this is a child by checking if it's nested in another navPoint
            is_child = False
            for other_nav in nav_points:
                if other_nav != nav_point:
                    children = other_nav.findall('.//{http://www.daisy.org/z3986/2005/ncx/}navPoint')
                    if nav_point in children:
                        parent_id = other_nav.get('id', '')
                        if parent_id not in hierarchy:
                            hierarchy[parent_id] = []
                        hierarchy[parent_id].append(nav_id)
                        is_child = True
                        break
            
            if not is_child:
                # Root level
                if 'ROOT' not in hierarchy:
                    hierarchy['ROOT'] = []
                hierarchy['ROOT'].append(nav_id)
        
        # Build chapters with proper numbering
        def build_chapters(nav_ids: List[str], parent_index: str = ""):
            for i, nav_id in enumerate(nav_ids, 1):
                data = nav_data.get(nav_id, {})
                
                # Create index
                if parent_index:
                    index = f"{parent_index}.{i}"
                else:
                    index = str(i)
                
                # Get text content
                text = _extract_text_from_src(zf, data.get('src', ''), base_dir)
                
                chapter = SimpleChapter(
                    index=index,
                    title=data.get('title', 'Untitled'),
                    text=text,
                    char_count=len(text)
                )
                chapters.append(chapter)
                
                # Process children
                children = hierarchy.get(nav_id, [])
                if children:
                    build_chapters(children, index)
        
        # Start from root
        root_children = hierarchy.get('ROOT', [])
        build_chapters(root_children)
        
    except Exception as e:
        print(f"Error parsing TOC: {e}")
        return []
    
    return chapters

def _parse_spine_simple(zf: zipfile.ZipFile, opf_path: str) -> List[SimpleChapter]:
    """Fallback: read chapters from spine order (flat structure)"""
    chapters = []
    
    try:
        opf_content = zf.read(opf_path).decode('utf-8')
        opf_root = ET.fromstring(opf_content)
        base_dir = os.path.dirname(opf_path) if '/' in opf_path else ''
        
        # Get manifest (id -> href mapping)
        manifest = {}
        for item in opf_root.findall('.//{http://www.idpf.org/2007/opf}item'):
            manifest[item.get('id')] = item.get('href')
        
        # Get spine order
        spine_items = opf_root.findall('.//{http://www.idpf.org/2007/opf}itemref')
        
        for i, item in enumerate(spine_items, 1):
            idref = item.get('idref')
            href = manifest.get(idref)
            
            if href and href.lower().endswith(('.html', '.xhtml', '.htm')):
                text = _extract_text_from_src(zf, href, base_dir)
                
                # Extract title from first heading
                title = _extract_title_from_text(text) or f"Chapter {i}"
                
                chapter = SimpleChapter(
                    index=str(i),
                    title=title,
                    text=text,
                    char_count=len(text)
                )
                chapters.append(chapter)
                
    except Exception as e:
        print(f"Error parsing spine: {e}")
    
    return chapters

def _extract_text_from_src(zf: zipfile.ZipFile, src: str, base_dir: str) -> str:
    """Extract clean text from HTML file in EPUB"""
    if not src:
        return ""
    
    # Clean src (remove fragment)
    src = src.split('#')[0]
    
    # Build full path
    if base_dir:
        full_path = f"{base_dir}/{src}".replace('\\', '/')
    else:
        full_path = src
    
    # Try different path variations
    possible_paths = [
        full_path,
        src,
        f"Text/{src}",
        f"OEBPS/{src}"
    ]
    
    for path in possible_paths:
        if path in zf.namelist():
            try:
                html_content = zf.read(path).decode('utf-8')
                text = _html_to_text(html_content)
                # Debug para ver o que está acontecendo
                if len(text) < 50 and src:
                    print(f"DEBUG: {src} -> {len(text)} chars: '{text[:100]}'")
                return text
            except Exception as e:
                print(f"Error reading {path}: {e}")
                continue
    
    return ""

def _html_to_text(html: str) -> str:
    """Convert HTML to plain text"""
    if not html:
        return ""
    
    # Remove scripts and styles
    html = re.sub(r'<script.*?</script>', '', html, flags=re.DOTALL | re.IGNORECASE)
    html = re.sub(r'<style.*?</style>', '', html, flags=re.DOTALL | re.IGNORECASE)
    
    # Convert common block elements to line breaks
    html = re.sub(r'</?(p|div|br|h[1-6]|li|tr|td)[^>]*>', '\n', html, flags=re.IGNORECASE)
    
    # Remove all other HTML tags
    html = re.sub(r'<[^>]+>', '', html)
    
    # Clean up text
    html = html.replace('&nbsp;', ' ')
    html = re.sub(r'\s+', ' ', html)
    html = re.sub(r'\n\s*\n\s*', '\n\n', html)
    
    # Remove repetitive book title prefixes (language agnostic pattern)
    text = html.strip()
    # Remove patterns like "BookName (Series Name)" at the beginning
    text = re.sub(r'^[\w\s]+\s*\([^)]+\)\s*', '', text)
    
    return text

def _extract_title_from_text(text: str) -> Optional[str]:
    """Extract title from first line of text"""
    if not text:
        return None
    
    first_line = text.split('\n')[0].strip()
    
    # If first line is short and looks like a title
    if len(first_line) < 100 and first_line:
        return first_line
    
    return None

# Test function
if __name__ == "__main__":
    import sys
    
    if len(sys.argv) != 2:
        print("Usage: python simple_epub_reader.py <epub_file>")
        sys.exit(1)
    
    epub_path = sys.argv[1]
    chapters = read_epub_simple(epub_path)
    
    print(f"\n📚 CHAPTERS ({len(chapters)} total)")
    print("=" * 60)
    
    for ch in chapters:
        indent = "  " * (ch.level - 1)
        print(f"{indent}{ch.index}. {ch.title} ({ch.char_count} chars)")
    
    print("=" * 60)