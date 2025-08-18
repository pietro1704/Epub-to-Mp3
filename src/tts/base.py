"""
src/tts/base.py

Interfaces base e classes abstratas para engines TTS.
"""

from abc import ABC, abstractmethod
from pathlib import Path
from typing import Optional, List


class TTSEngine(ABC):
    """Interface base para engines TTS."""
    
    @abstractmethod
    def synthesize(self, text: str, output_path: Path) -> None:
        """
        Sintetiza texto em arquivo de áudio.
        
        Args:
            text: Texto para sintetizar
            output_path: Caminho de saída do arquivo MP3
        """
        pass
    
    @abstractmethod
    def validate_dependencies(self) -> None:
        """Valida se todas as dependências estão disponíveis."""
        pass
    
    @abstractmethod
    def preview_voice(self) -> None:
        """Gera preview da voz selecionada."""
        pass
    
    def chunk_text(self, text: str, max_chars: int) -> List[str]:
        """
        Divide texto em chunks menores respeitando pontuação e pausas naturais.
        
        Args:
            text: Texto para dividir
            max_chars: Tamanho máximo de cada chunk
            
        Returns:
            Lista de chunks de texto
        """
        if len(text) <= max_chars:
            return [text]
        
        chunks = []
        import re
        
        # Divide por seções principais (pausas)
        major_sections = re.split(r'(\.\.\. \.\.\.)', text)
        current_chunk = ""
        
        for section in major_sections:
            if section == "... ...":
                if current_chunk:
                    current_chunk += " " + section
                continue
                
            section = section.strip()
            if not section:
                continue
            
            if len(current_chunk) + len(section) + 10 <= max_chars:
                if current_chunk:
                    current_chunk += " " + section
                else:
                    current_chunk = section
            else:
                if current_chunk:
                    chunks.append(current_chunk.strip())
                    current_chunk = ""
                
                if len(section) > max_chars:
                    # Divide por parágrafos
                    paragraphs = section.split('\n\n')
                    temp_chunk = ""
                    
                    for paragraph in paragraphs:
                        paragraph = paragraph.strip()
                        if not paragraph:
                            continue
                            
                        if len(temp_chunk) + len(paragraph) + 2 <= max_chars:
                            if temp_chunk:
                                temp_chunk += "\n\n" + paragraph
                            else:
                                temp_chunk = paragraph
                        else:
                            if temp_chunk:
                                chunks.append(temp_chunk)
                            
                            if len(paragraph) > max_chars:
                                # Divide por sentenças
                                sentences = re.split(r'[.!?]+', paragraph)
                                sent_chunk = ""
                                
                                for sentence in sentences:
                                    sentence = sentence.strip()
                                    if not sentence:
                                        continue
                                        
                                    if len(sent_chunk) + len(sentence) + 2 <= max_chars:
                                        if sent_chunk:
                                            sent_chunk += ". " + sentence
                                        else:
                                            sent_chunk = sentence
                                    else:
                                        if sent_chunk:
                                            chunks.append(sent_chunk + ".")
                                        sent_chunk = sentence
                                
                                if sent_chunk:
                                    temp_chunk = sent_chunk + "."
                                else:
                                    temp_chunk = ""
                            else:
                                temp_chunk = paragraph
                    
                    if temp_chunk:
                        current_chunk = temp_chunk
                else:
                    current_chunk = section
        
        if current_chunk:
            chunks.append(current_chunk.strip())
        
        return [chunk for chunk in chunks if chunk.strip()]


class AudioConverter:
    """Utilitário para conversão de áudio usando ffmpeg."""
    
    @staticmethod
    def convert_wav_to_mp3(wav_path: Path, mp3_path: Path, 
                          sample_rate: int = 22050, channels: int = 1, 
                          bitrate: str = "32k") -> None:
        """
        Converte WAV para MP3 usando ffmpeg.
        
        Args:
            wav_path: Arquivo WAV de entrada
            mp3_path: Arquivo MP3 de saída
            sample_rate: Taxa de amostragem
            channels: Número de canais
            bitrate: Taxa de bits
        """
        import subprocess
        
        cmd = [
            "ffmpeg", "-y",
            "-i", str(wav_path),
            "-ar", str(sample_rate),
            "-ac", str(channels),
            "-b:a", bitrate,
            "-loglevel", "error",
            str(mp3_path),
        ]
        
        try:
            result = subprocess.run(cmd, capture_output=True, timeout=120)
            if result.returncode != 0:
                raise RuntimeError(f"ffmpeg falhou: {result.stderr.decode()}")
        except subprocess.TimeoutExpired:
            raise RuntimeError("Timeout na conversão MP3")
    
    @staticmethod
    def concatenate_audio_files(file_list: List[Path], output_path: Path) -> None:
        """
        Concatena múltiplos arquivos de áudio.
        
        Args:
            file_list: Lista de arquivos para concatenar
            output_path: Arquivo de saída
        """
        import subprocess
        
        if len(file_list) <= 1:
            if file_list:
                file_list[0].rename(output_path)
            return
        
        concat_list = output_path.parent / ".tmp-concat.txt"
        
        try:
            with open(concat_list, 'w') as f:
                for file_path in file_list:
                    f.write(f"file '{file_path.name}'\n")
            
            cmd = [
                "ffmpeg", "-y", 
                "-f", "concat", 
                "-safe", "0", 
                "-i", str(concat_list), 
                "-c", "copy", 
                str(output_path)
            ]
            
            result = subprocess.run(cmd, capture_output=True, check=True)
            if result.returncode != 0:
                raise RuntimeError(f"Concatenação falhou: {result.stderr.decode()}")
                
        finally:
            if concat_list.exists():
                concat_list.unlink()


class TTSValidator:
    """Validador de dependências para engines TTS."""
    
    @staticmethod
    def check_ffmpeg() -> None:
        """Verifica se ffmpeg está disponível."""
        import subprocess
        
        try:
            subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            raise RuntimeError("ffmpeg não encontrado no PATH")
    
    @staticmethod
    def check_piper() -> None:
        """Verifica se Piper está disponível."""
        import subprocess
        
        try:
            subprocess.run(["piper", "--help"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            raise RuntimeError("Piper não encontrado no PATH")
    
    @staticmethod
    def check_edge_tts() -> None:
        """Verifica se Edge-TTS está disponível."""
        try:
            import edge_tts
        except ImportError:
            raise RuntimeError("Edge-TTS não instalado. Execute: pip install edge-tts")
    
    @staticmethod
    def check_coqui_tts() -> None:
        """Verifica se Coqui TTS está disponível."""
        try:
            import TTS
        except ImportError:
            raise RuntimeError("Coqui TTS não instalado. Execute: pip install TTS")