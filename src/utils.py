# -*- coding: utf-8 -*-
"""
Simplified utilities - SOLID principles applied  
Reduced from 258 to ~80 lines by separating responsibilities
"""

import re
import shutil
import asyncio
from pathlib import Path
from typing import Optional


class FileManager:
    """Handles file operations following SRP"""
    
    @staticmethod
    def sanitize_filename(filename: str, max_length: int = 100) -> str:
        """Sanitize filename for safe file creation"""
        if not filename:
            return "untitled"
        
        # Remove/replace problematic characters
        safe_name = re.sub(r'[<>:"/\\|?*]', '_', filename)
        safe_name = re.sub(r'\s+', ' ', safe_name.strip())
        
        # Limit length
        if len(safe_name) > max_length:
            safe_name = safe_name[:max_length].rstrip()
        
        return safe_name or "untitled"
    
    @staticmethod
    def ensure_directory(path: Path) -> Path:
        """Ensure directory exists"""
        path.mkdir(parents=True, exist_ok=True)
        return path
    
    @staticmethod
    def cleanup_temp_files(directory: Path, pattern: str = "*.tmp"):
        """Clean up temporary files"""
        if directory.exists():
            for temp_file in directory.glob(pattern):
                try:
                    temp_file.unlink()
                except OSError:
                    pass


class AudioProcessor:
    """Handles audio processing operations following SRP"""
    
    @staticmethod
    async def convert_to_mp3(input_file: Path, output_file: Path, 
                           bitrate: str = "32k") -> Optional[Path]:
        """Convert audio file to MP3 format"""
        if not input_file.exists():
            return None
        
        # Use ffmpeg for conversion
        cmd = [
            "ffmpeg", "-i", str(input_file), 
            "-acodec", "mp3", "-ab", bitrate,
            "-y", str(output_file)
        ]
        
        try:
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL
            )
            await process.wait()
            
            if process.returncode == 0 and output_file.exists():
                return output_file
                
        except Exception:
            pass
        
        return None
    
    @staticmethod
    def validate_audio_file(file_path: Path) -> bool:
        """Validate audio file exists and has reasonable size"""
        return (file_path.exists() and 
                file_path.stat().st_size > 1000)  # At least 1KB


class TextValidator:
    """Validates text content following SRP"""
    
    @staticmethod
    def is_valid_text(text: str, min_length: int = 10) -> bool:
        """Check if text is valid for TTS processing"""
        if not text or not text.strip():
            return False
        
        return len(text.strip()) >= min_length
    
    @staticmethod
    def estimate_duration(text: str, words_per_minute: int = 150) -> float:
        """Estimate audio duration in seconds"""
        word_count = len(text.split())
        return (word_count / words_per_minute) * 60