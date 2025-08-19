"""
src/tts/piper_engine.py

Engine TTS para Piper (100% local CLI) - Nome de classe corrigido.
"""

import subprocess
from pathlib import Path
from typing import Dict, Any


class PiperTTSEngine:  # ← CORRIGIDO: era TTSEngine
    """Engine TTS usando Piper CLI (100% local)."""
    
    def __init__(self, config: Dict[str, Any]):
        """
        Inicializa o engine Piper TTS.
        
        Args:
            config: Configuração com model_path
        """
        self.model_path = config.get('model_path')
        self.sample_rate = config.get('ar', 22050)
        self.channels = config.get('ac', 1)
        self.bitrate = config.get('bitrate', '32k')
        
        if not self.model_path or not self.model_path.exists():
            raise FileNotFoundError(f"Modelo Piper não encontrado: {self.model_path}")
    
    def chunk_text(self, text: str, max_chars: int = 1500):
        """Divide texto em chunks menores respeitando pontuação."""
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
    
    def synthesize(self, text: str, output_path: Path) -> None:
        """
        Sintetiza texto usando Piper CLI.
        
        Args:
            text: Texto para sintetizar
            output_path: Caminho de saída do arquivo MP3
        """
        wav_tmp = output_path.with_suffix('.wav')
        
        cmd = [
            "piper",
            "--model", str(self.model_path),
            "--output_file", str(wav_tmp)
        ]
        
        try:
            result = subprocess.run(
                cmd, 
                input=text, 
                text=True, 
                capture_output=True, 
                timeout=300
            )
            
            if result.returncode != 0:
                raise RuntimeError(f"Piper falhou: {result.stderr}")
            
            # Converte WAV para MP3
            self._convert_wav_to_mp3(wav_tmp, output_path)
            
        finally:
            if wav_tmp.exists():
                wav_tmp.unlink()
    
    def _convert_wav_to_mp3(self, wav_path: Path, mp3_path: Path) -> None:
        """Converte WAV para MP3 usando ffmpeg."""
        cmd = [
            "ffmpeg", "-y",
            "-i", str(wav_path),
            "-ar", str(self.sample_rate),
            "-ac", str(self.channels),
            "-b:a", self.bitrate,
            "-loglevel", "error",
            str(mp3_path),
        ]
        
        try:
            result = subprocess.run(cmd, capture_output=True, timeout=120)
            if result.returncode != 0:
                raise RuntimeError(f"ffmpeg falhou: {result.stderr.decode()}")
        except subprocess.TimeoutExpired:
            raise RuntimeError("Timeout na conversão MP3")
    
    def validate_dependencies(self) -> None:
        """Valida dependências do Piper."""
        try:
            subprocess.run(["piper", "--help"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            raise RuntimeError("Piper não encontrado no PATH")
            
        try:
            subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            raise RuntimeError("ffmpeg não encontrado no PATH")
        
        if not self.model_path or not self.model_path.exists():
            raise FileNotFoundError(f"Modelo Piper não encontrado: {self.model_path}")
    
    def preview_voice(self) -> None:
        """Gera preview da voz do modelo Piper."""
        preview_text = "Esta é uma demonstração do modelo Piper selecionado."
        preview_file = Path(".preview-piper.wav")
        
        cmd = [
            "piper",
            "--model", str(self.model_path),
            "--output_file", str(preview_file)
        ]
        
        try:
            result = subprocess.run(
                cmd,
                input=preview_text,
                text=True,
                capture_output=True,
                timeout=60
            )
            
            if result.returncode != 0:
                print(f"❌ Erro ao gerar preview: {result.stderr}")
                return
            
            self._play_preview(preview_file)
            
        except Exception as e:
            print(f"❌ Erro ao gerar preview: {e}")
    
    def _play_preview(self, preview_file: Path) -> None:
        """Reproduz arquivo de preview."""
        import sys
        
        try:
            if sys.platform == "darwin":
                subprocess.run(["afplay", str(preview_file)], check=False)
            elif sys.platform.startswith("linux"):
                subprocess.run(["aplay", str(preview_file)], check=False)
            else:
                print(f"🎵 Preview salvo em: {preview_file}")
        except:
            print(f"🎵 Preview salvo em: {preview_file}")