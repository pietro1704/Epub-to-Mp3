# -*- coding: utf-8 -*-
"""
Simplified Progress Tracker - SOLID principles applied
New focused module for progress tracking following SRP
"""

import time
from typing import Optional


class ProgressTracker:
    """Tracks conversion progress following SRP"""
    
    def __init__(self, total_chapters: int):
        self.total_chapters = total_chapters
        self.completed_chapters = 0
        self.start_time = time.time()
        self.current_chapter: Optional[str] = None
    
    def start_chapter(self, chapter_name: str):
        """Start processing a chapter"""
        self.current_chapter = chapter_name
        print(f"🎧 Converting: {chapter_name}")
    
    def complete_chapter(self):
        """Mark chapter as completed"""
        self.completed_chapters += 1
        self._show_progress()
    
    def _show_progress(self):
        """Display current progress"""
        progress = (self.completed_chapters / self.total_chapters) * 100
        elapsed = time.time() - self.start_time
        
        if self.completed_chapters > 0:
            eta = (elapsed / self.completed_chapters) * (self.total_chapters - self.completed_chapters)
            eta_str = f" (ETA: {eta/60:.1f}min)" if eta > 60 else f" (ETA: {eta:.0f}s)"
        else:
            eta_str = ""
        
        print(f"📊 Progress: {self.completed_chapters}/{self.total_chapters} ({progress:.1f}%){eta_str}")
    
    def finish(self):
        """Mark conversion as finished"""
        elapsed = time.time() - self.start_time
        print(f"✅ Conversion completed in {elapsed/60:.1f} minutes")