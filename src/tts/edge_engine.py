"""
src/tts/edge_engine.py

Engine TTS para Microsoft Edge-TTS.
"""

import asyncio
import subprocess
import sys
from pathlib import Path
from typing import Dict, Any

try:
    import edge_tts
except ImportError:
    edge_tts = None


class TTSEngine:
    """Interface base para engines TTS."""
    
    def chunk_text(self, text: str, max_chars: int):
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


class AudioConverter:
    """Utilitário para conversão de áudio usando ffmpeg."""
    
    @staticmethod
    def concatenate_audio_files(file_list, output_path: Path) -> None:
        """Concatena múltiplos arquivos de áudio."""
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


class EdgeTTSEngine(TTSEngine):
    """Engine TTS usando Microsoft Edge-TTS."""
    
    def __init__(self, config: Dict[str, Any]):
        """
        Inicializa o engine Edge-TTS.
        
        Args:
            config: Configuração com voice, bitrate, ar (sample rate), ac (channels)
        """
        self.voice = config.get('voice', 'pt-BR-FranciscaNeural')
        self.bitrate = config.get('bitrate', '32k')
        self.sample_rate = config.get('ar', 22050)
        self.channels = config.get('ac', 1)
        
    def synthesize(self, text: str, output_path: Path) -> None:
        """
        Sintetiza texto usando Edge-TTS e converte para MP3 comprimido.
        
        Args:
            text: Texto para sintetizar
            output_path: Caminho de saída do arquivo MP3
        """
        asyncio.run(self._synthesize_async(text, output_path))
    
    async def _synthesize_async(self, text: str, output_path: Path) -> None:
        """Versão assíncrona da síntese."""
        chunks = self.chunk_text(text, max_chars=8000)
        
        if len(chunks) == 1:
            await self._synthesize_single_chunk(text, output_path)
        else:
            await self._synthesize_multiple_chunks(chunks, output_path)
    
    async def _synthesize_single_chunk(self, text: str, output_path: Path) -> None:
        """Sintetiza um único chunk."""
        temp_raw = output_path.with_suffix('.tmp.mp3')
        
        try:
            communicate = edge_tts.Communicate(text, self.voice)
            await communicate.save(str(temp_raw))
            
            self._compress_audio(temp_raw, output_path)
            
        finally:
            if temp_raw.exists():
                temp_raw.unlink()
    
    async def _synthesize_multiple_chunks(self, chunks: list, output_path: Path) -> None:
        """Sintetiza múltiplos chunks e concatena."""
        temp_files = []
        
        try:
            for i, chunk in enumerate(chunks):
                temp_raw = output_path.parent / f".tmp-edge-raw-{i}.mp3"
                temp_compressed = output_path.parent / f".tmp-edge-{i}.mp3"
                
                # Sintetiza chunk
                communicate = edge_tts.Communicate(chunk, self.voice)
                await communicate.save(str(temp_raw))
                
                # Comprime
                self._compress_audio(temp_raw, temp_compressed)
                temp_files.append(temp_compressed)
                
                # Remove arquivo raw
                if temp_raw.exists():
                    temp_raw.unlink()
            
            # Concatena arquivos
            AudioConverter.concatenate_audio_files(temp_files, output_path)
            
        finally:
            # Limpa arquivos temporários
            for temp_file in temp_files:
                if temp_file.exists():
                    temp_file.unlink()
            
            # Limpa qualquer arquivo raw restante
            for temp_raw in output_path.parent.glob(".tmp-edge-raw-*.mp3"):
                try:
                    temp_raw.unlink()
                except:
                    pass
    
    def _compress_audio(self, input_path: Path, output_path: Path) -> None:
        """Comprime áudio usando ffmpeg."""
        cmd = [
            "ffmpeg", "-y",
            "-i", str(input_path),
            "-ar", str(self.sample_rate),
            "-ac", str(self.channels),
            "-b:a", self.bitrate,
            "-loglevel", "error",
            str(output_path)
        ]
        
        result = subprocess.run(cmd, capture_output=True, timeout=120)
        if result.returncode != 0:
            raise RuntimeError(f"Erro na conversão: {result.stderr.decode()}")
    
    def validate_dependencies(self) -> None:
        """Valida dependências do Edge-TTS."""
        if not edge_tts:
            raise RuntimeError("Edge-TTS não instalado. Execute: pip install edge-tts")
        
        try:
            subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            raise RuntimeError("ffmpeg não encontrado no PATH (necessário para Edge-TTS)")
    
    def preview_voice(self) -> None:
        """Gera preview da voz selecionada."""
        asyncio.run(self._preview_voice_async())
    
    async def _preview_voice_async(self) -> None:
        """Gera preview de 5 segundos da voz do Edge-TTS."""
        preview_text = ("Olá, esta é uma demonstração da voz selecionada para o seu "
                       "audiolivro. A qualidade será mantida durante toda a conversão.")
        preview_file = Path(f".preview-{self.voice.split('-')[-1]}.mp3")
        
        try:
            communicate = edge_tts.Communicate(preview_text, self.voice)
            await communicate.save(str(preview_file))
            
            self._play_preview(preview_file)
            
        except Exception as e:
            print(f"❌ Erro ao gerar preview: {e}")
    
    def _play_preview(self, preview_file: Path) -> None:
        """Reproduz arquivo de preview."""
        try:
            if sys.platform == "darwin":
                subprocess.run(["afplay", str(preview_file)], check=False)
            elif sys.platform.startswith("linux"):
                subprocess.run(["aplay", str(preview_file)], check=False)
            else:
                print(f"🎵 Preview salvo em: {preview_file}")
                print("   Reproduza manualmente para ouvir a voz")
        except:
            print(f"🎵 Preview salvo em: {preview_file}")