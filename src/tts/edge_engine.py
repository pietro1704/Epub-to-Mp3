"""
src/tts/edge_engine.py

Engine TTS para Microsoft Edge-TTS com correções para erro "No audio was received".
"""

import asyncio
import subprocess
import sys
import re
from pathlib import Path
from typing import Dict, Any

try:
    import edge_tts
except ImportError:
    edge_tts = None


class EdgeTTSEngine:
    """Engine TTS usando Microsoft Edge-TTS com tratamento robusto de erros."""
    
    def __init__(self, config: Dict[str, Any]):
        self.voice = config.get('voice', 'pt-BR-FranciscaNeural')
        self.bitrate = config.get('bitrate', '32k')
        self.sample_rate = config.get('ar', 22050)
        self.channels = config.get('ac', 1)
        
    def synthesize(self, text: str, output_path: Path) -> None:
        """Sintetiza texto com tratamento robusto de erros."""
        asyncio.run(self._synthesize_async(text, output_path))
    
    async def _synthesize_async(self, text: str, output_path: Path) -> None:
        """Versão assíncrona com múltiplas tentativas."""
        # Limpa e valida texto
        cleaned_text = self._clean_text(text)
        
        if not cleaned_text.strip():
            # Texto vazio - cria arquivo silencioso
            self._create_silent_audio(output_path)
            return
        
        chunks = self._smart_chunk_text(cleaned_text)
        
        if len(chunks) == 1:
            await self._synthesize_single_chunk_with_retry(cleaned_text, output_path)
        else:
            await self._synthesize_multiple_chunks(chunks, output_path)
    
    def _clean_text(self, text: str) -> str:
        """Limpa texto para evitar problemas com Edge-TTS."""
        # Remove caracteres problemáticos
        text = re.sub(r'[^\w\s\.\,\!\?\:\;\-\(\)\"\'àáâãäèéêëìíîïòóôõöùúûüçñ]', ' ', text)
        
        # Remove múltiplos espaços e quebras
        text = re.sub(r'\s+', ' ', text)
        text = re.sub(r'\.{4,}', '...', text)  # Max 3 pontos
        
        # Remove pausas excessivas que podem causar problemas
        text = re.sub(r'(\.\.\. \.\.\.){3,}', '... ... ...', text)
        
        # Limita tamanho por segurança
        if len(text) > 50000:
            text = text[:50000] + "..."
        
        return text.strip()
    
    def _smart_chunk_text(self, text: str, max_chars: int = 4000) -> list:
        """Divisão inteligente que evita problemas com Edge-TTS."""
        if len(text) <= max_chars:
            return [text]
        
        chunks = []
        current_chunk = ""
        
        # Divide por pausas naturais primeiro
        sections = re.split(r'(\.\.\. \.\.\.)', text)
        
        for section in sections:
            if section == "... ...":
                if current_chunk:
                    current_chunk += " " + section
                continue
                
            section = section.strip()
            if not section:
                continue
            
            # Se adicionar esta seção excede o limite
            if len(current_chunk) + len(section) + 5 > max_chars:
                if current_chunk:
                    chunks.append(current_chunk.strip())
                    current_chunk = section
                else:
                    # Seção muito grande - divide por frases
                    sentences = self._split_by_sentences(section, max_chars)
                    chunks.extend(sentences)
            else:
                if current_chunk:
                    current_chunk += " " + section
                else:
                    current_chunk = section
        
        if current_chunk:
            chunks.append(current_chunk.strip())
        
        return [chunk for chunk in chunks if chunk.strip()]
    
    def _split_by_sentences(self, text: str, max_chars: int) -> list:
        """Divide texto longo por frases."""
        sentences = re.split(r'([.!?]+)', text)
        chunks = []
        current_chunk = ""
        
        for i in range(0, len(sentences), 2):
            sentence = sentences[i].strip()
            punctuation = sentences[i + 1] if i + 1 < len(sentences) else ""
            
            full_sentence = sentence + punctuation
            
            if len(current_chunk) + len(full_sentence) + 1 > max_chars:
                if current_chunk:
                    chunks.append(current_chunk.strip())
                current_chunk = full_sentence
            else:
                if current_chunk:
                    current_chunk += " " + full_sentence
                else:
                    current_chunk = full_sentence
        
        if current_chunk:
            chunks.append(current_chunk.strip())
        
        return chunks
    
    async def _synthesize_single_chunk_with_retry(self, text: str, output_path: Path) -> None:
        """Sintetiza chunk único com tentativas múltiplas."""
        max_retries = 3
        
        for attempt in range(max_retries):
            try:
                temp_raw = output_path.with_suffix(f'.tmp{attempt}.mp3')
                
                communicate = edge_tts.Communicate(text, self.voice)
                await communicate.save(str(temp_raw))
                
                # Verifica se arquivo foi criado e tem conteúdo
                if temp_raw.exists() and temp_raw.stat().st_size > 1000:  # Mínimo 1KB
                    self._compress_audio(temp_raw, output_path)
                    if temp_raw.exists():
                        temp_raw.unlink()
                    return
                else:
                    if temp_raw.exists():
                        temp_raw.unlink()
                    raise RuntimeError("Arquivo de áudio vazio ou muito pequeno")
                    
            except Exception as e:
                print(f"    ⚠️ Tentativa {attempt + 1} falhou: {e}")
                
                if attempt == max_retries - 1:
                    # Última tentativa - tenta com texto simplificado
                    simplified_text = self._simplify_text(text)
                    if simplified_text != text and simplified_text:
                        print(f"    🔄 Tentando com texto simplificado...")
                        try:
                            temp_raw = output_path.with_suffix('.tmp_simple.mp3')
                            communicate = edge_tts.Communicate(simplified_text, self.voice)
                            await communicate.save(str(temp_raw))
                            
                            if temp_raw.exists() and temp_raw.stat().st_size > 1000:
                                self._compress_audio(temp_raw, output_path)
                                if temp_raw.exists():
                                    temp_raw.unlink()
                                return
                        except:
                            pass
                    
                    # Se tudo falhar, cria áudio silencioso
                    print(f"    ⚠️ Todas as tentativas falharam, criando áudio silencioso")
                    self._create_silent_audio(output_path)
                    return
                
                # Aguarda antes da próxima tentativa
                await asyncio.sleep(2 ** attempt)
    
    def _simplify_text(self, text: str) -> str:
        """Simplifica texto removendo elementos problemáticos."""
        # Remove símbolos especiais
        text = re.sub(r'[^\w\s\.\,\!\?]', ' ', text)
        
        # Remove pausas múltiplas
        text = re.sub(r'(\.\.\. \.\.\.)+', '. ', text)
        
        # Pega apenas primeira parte se muito longo
        if len(text) > 1000:
            sentences = text.split('. ')
            text = '. '.join(sentences[:3]) + '.'
        
        return text.strip()
    
    async def _synthesize_multiple_chunks(self, chunks: list, output_path: Path) -> None:
        """Sintetiza múltiplos chunks com tratamento de erro."""
        temp_files = []
        
        try:
            for i, chunk in enumerate(chunks):
                temp_raw = output_path.parent / f".tmp-edge-raw-{i}.mp3"
                temp_compressed = output_path.parent / f".tmp-edge-{i}.mp3"
                
                # Tenta sintetizar chunk
                success = False
                for attempt in range(2):
                    try:
                        communicate = edge_tts.Communicate(chunk, self.voice)
                        await communicate.save(str(temp_raw))
                        
                        if temp_raw.exists() and temp_raw.stat().st_size > 500:
                            self._compress_audio(temp_raw, temp_compressed)
                            temp_files.append(temp_compressed)
                            success = True
                            break
                    except Exception as e:
                        print(f"    ⚠️ Erro no chunk {i+1}, tentativa {attempt+1}: {e}")
                        await asyncio.sleep(1)
                    finally:
                        if temp_raw.exists():
                            temp_raw.unlink()
                
                if not success:
                    print(f"    ⚠️ Chunk {i+1} falhou, pulando...")
            
            # Concatena arquivos que funcionaram
            if temp_files:
                self._concatenate_audio_files(temp_files, output_path)
            else:
                # Se nenhum chunk funcionou, cria áudio silencioso
                print(f"    ⚠️ Nenhum chunk foi sintetizado, criando áudio silencioso")
                self._create_silent_audio(output_path)
                
        finally:
            # Limpa arquivos temporários
            for temp_file in temp_files:
                if temp_file.exists():
                    temp_file.unlink()
            
            for temp_raw in output_path.parent.glob(".tmp-edge-raw-*.mp3"):
                try:
                    temp_raw.unlink()
                except:
                    pass
    
    def _create_silent_audio(self, output_path: Path) -> None:
        """Cria arquivo de áudio silencioso quando síntese falha."""
        cmd = [
            "ffmpeg", "-y",
            "-f", "lavfi",
            "-i", "anullsrc=duration=1:sample_rate=22050:channels=1",
            "-ar", str(self.sample_rate),
            "-ac", str(self.channels),
            "-b:a", self.bitrate,
            "-loglevel", "error",
            str(output_path)
        ]
        
        try:
            subprocess.run(cmd, capture_output=True, check=True)
        except Exception as e:
            print(f"    ❌ Erro ao criar áudio silencioso: {e}")
            # Cria arquivo vazio como último recurso
            output_path.touch()
    
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
    
    def _concatenate_audio_files(self, file_list: list, output_path: Path) -> None:
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
    
    def validate_dependencies(self) -> None:
        """Valida dependências do Edge-TTS."""
        if not edge_tts:
            raise RuntimeError("Edge-TTS não instalado. Execute: pip install edge-tts")
        
        try:
            subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            raise RuntimeError("ffmpeg não encontrado no PATH")
    
    def preview_voice(self) -> None:
        """Gera preview da voz selecionada."""
        asyncio.run(self._preview_voice_async())
    
    async def _preview_voice_async(self) -> None:
        """Gera preview de 5 segundos da voz do Edge-TTS."""
        preview_text = "Olá, esta é uma demonstração da voz selecionada."
        preview_file = Path(f".preview-{self.voice.split('-')[-1]}.mp3")
        
        try:
            await self._synthesize_single_chunk_with_retry(preview_text, preview_file)
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
        except:
            print(f"🎵 Preview salvo em: {preview_file}")