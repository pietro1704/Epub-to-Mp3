"""
src/tts/coqui_engine.py

Engine TTS para Coqui TTS - SOLUÇÃO FINAL TESTADA para XTTS v2.
"""

import sys
import subprocess
from pathlib import Path
from typing import Dict, Any, Optional

try:
    from TTS.api import TTS as CoquiTTS
    import TTS
except ImportError:
    TTS = None
    CoquiTTS = None


class TTSEngine:
    """Interface base para engines TTS."""
    
    def chunk_text(self, text: str, max_chars: int):
        """Divide texto em chunks menores respeitando pontuação."""
        if len(text) <= max_chars:
            return [text]
        
        chunks = []
        import re
        
        # Para XTTS, usa chunks menores e mais simples
        if max_chars <= 200:
            # Divide por frases primeiro
            sentences = re.split(r'[.!?]+', text)
            current_chunk = ""
            
            for sentence in sentences:
                sentence = sentence.strip()
                if not sentence:
                    continue
                    
                # Se a frase cabe no chunk atual
                if len(current_chunk) + len(sentence) + 2 <= max_chars:
                    if current_chunk:
                        current_chunk += ". " + sentence
                    else:
                        current_chunk = sentence
                else:
                    # Salva chunk atual
                    if current_chunk:
                        chunks.append(current_chunk.strip())
                    
                    # Se frase é muito longa, divide por vírgulas
                    if len(sentence) > max_chars:
                        parts = sentence.split(',')
                        temp_chunk = ""
                        for part in parts:
                            part = part.strip()
                            if len(temp_chunk) + len(part) + 2 <= max_chars:
                                if temp_chunk:
                                    temp_chunk += ", " + part
                                else:
                                    temp_chunk = part
                            else:
                                if temp_chunk:
                                    chunks.append(temp_chunk)
                                temp_chunk = part
                        current_chunk = temp_chunk
                    else:
                        current_chunk = sentence
            
            if current_chunk:
                chunks.append(current_chunk.strip())
        else:
            # Lógica original para chunks maiores
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
        """Converte WAV para MP3 usando ffmpeg."""
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


class CoquiTTSEngine(TTSEngine):
    """Engine TTS usando Coqui TTS - SOLUÇÃO FINAL TESTADA para XTTS."""
    
    def __init__(self, config: Dict[str, Any]):
        """
        Inicializa o engine Coqui TTS.
        
        Args:
            config: Configuração com model_name e speaker (opcional)
        """
        self.model_name = config.get('model_name', 'tts_models/multilingual/multi-dataset/xtts_v2')
        self.speaker = config.get('speaker')
        self.sample_rate = config.get('ar', 22050)
        self.channels = config.get('ac', 1)
        self.bitrate = config.get('bitrate', '32k')
        self._tts_instance = None
        
        # Detecta automaticamente se é modelo XTTS
        self.is_xtts = "xtts" in self.model_name.lower()
        
        # Para XTTS, sempre usa português brasileiro
        self.language = "pt" if self.is_xtts else None
        
        # XTTS tem limite de caracteres muito baixo
        self.max_chars = 180 if self.is_xtts else 1500
    
    def synthesize(self, text: str, output_path: Path) -> None:
        """
        Sintetiza texto usando Coqui TTS local.
        
        Args:
            text: Texto para sintetizar
            output_path: Caminho de saída do arquivo MP3
        """
        chunks = self.chunk_text(text, max_chars=self.max_chars)
        
        if len(chunks) == 1:
            self._synthesize_single_chunk(text, output_path)
        else:
            self._synthesize_multiple_chunks(chunks, output_path)
    
    def _synthesize_single_chunk(self, text: str, output_path: Path) -> None:
        """Sintetiza um único chunk."""
        wav_tmp = output_path.with_suffix('.wav')
        
        try:
            tts = self._get_tts_instance()
            
            # Lógica específica para XTTS vs outros modelos
            if self.is_xtts:
                self._synthesize_xtts_fixed(tts, text, wav_tmp)
            else:
                # Modelos não-XTTS tradicionais
                if self.speaker and hasattr(tts, 'speakers') and tts.speakers and self.speaker in tts.speakers:
                    tts.tts_to_file(text=text, file_path=str(wav_tmp), speaker=self.speaker)
                else:
                    tts.tts_to_file(text=text, file_path=str(wav_tmp))
            
            # Converte para MP3
            AudioConverter.convert_wav_to_mp3(
                wav_tmp, output_path, 
                self.sample_rate, self.channels, self.bitrate
            )
            
        finally:
            if wav_tmp and wav_tmp.exists():
                wav_tmp.unlink()
    
    def _synthesize_multiple_chunks(self, chunks: list, output_path: Path) -> None:
        """Sintetiza múltiplos chunks e concatena."""
        temp_files = []
        
        try:
            tts = self._get_tts_instance()
            
            for i, chunk in enumerate(chunks):
                temp_wav = output_path.parent / f".tmp-coqui-{i}.wav"
                temp_mp3 = output_path.parent / f".tmp-coqui-{i}.mp3"
                
                # Sintetiza chunk
                if self.is_xtts:
                    self._synthesize_xtts_fixed(tts, chunk, temp_wav)
                else:
                    # Modelos não-XTTS
                    if self.speaker and hasattr(tts, 'speakers') and tts.speakers and self.speaker in tts.speakers:
                        tts.tts_to_file(text=chunk, file_path=str(temp_wav), speaker=self.speaker)
                    else:
                        tts.tts_to_file(text=chunk, file_path=str(temp_wav))
                
                # Converte para MP3
                AudioConverter.convert_wav_to_mp3(
                    temp_wav, temp_mp3,
                    self.sample_rate, self.channels, self.bitrate
                )
                temp_files.append(temp_mp3)
                
                # Remove WAV temporário
                if temp_wav.exists():
                    temp_wav.unlink()
            
            # Concatena arquivos
            AudioConverter.concatenate_audio_files(temp_files, output_path)
            
        finally:
            # Limpa arquivos temporários
            for temp_file in temp_files:
                if temp_file.exists():
                    temp_file.unlink()
    
    def _synthesize_xtts_fixed(self, tts, text: str, wav_path: Path) -> None:
        """
        Sintetiza usando modelo XTTS com API CORRIGIDA.
        
        Args:
            tts: Instância do TTS
            text: Texto para sintetizar
            wav_path: Caminho do arquivo WAV de saída
        """
        # SOLUÇÃO BASEADA NA PESQUISA: XTTS v2 API correta
        
        # Verifica se tem arquivo de voz de referência
        ref_voice_path = Path("./reference_voice.wav")
        
        try:
            if ref_voice_path.exists():
                # Usa arquivo de voz de referência para clonagem
                print(f"    🎤 Usando voz clonada: {ref_voice_path.name}")
                tts.tts_to_file(
                    text=text,
                    file_path=str(wav_path),
                    speaker_wav=str(ref_voice_path),
                    language=self.language
                )
            elif self.speaker and self.speaker.endswith('.wav') and Path(self.speaker).exists():
                # Speaker é um arquivo de áudio
                print(f"    🎤 Usando arquivo de voz: {Path(self.speaker).name}")
                tts.tts_to_file(
                    text=text,
                    file_path=str(wav_path),
                    speaker_wav=self.speaker,
                    language=self.language
                )
            else:
                # XTTS SEM SPEAKER - modo automático (DESCOBERTA DA PESQUISA)
                print(f"    🎤 Usando voz automática XTTS")
                tts.tts_to_file(
                    text=text,
                    file_path=str(wav_path),
                    language=self.language
                    # SEM speaker= e SEM speaker_wav= - deixa XTTS escolher
                )
        
        except Exception as e:
            error_msg = str(e).lower()
            
            # Trata erros específicos conhecidos
            if "gpt2inferencemodel" in error_msg or "generate" in error_msg:
                print(f"    ⚠️ Erro de versão XTTS, tentando fallback...")
                # Fallback: modo mais simples
                tts.tts_to_file(
                    text=text,
                    file_path=str(wav_path),
                    language="pt"
                )
            elif "multi-speaker" in error_msg and "speaker" in error_msg:
                print(f"    ⚠️ Erro de speaker, usando modo automático...")
                tts.tts_to_file(
                    text=text,
                    file_path=str(wav_path),
                    language="pt"
                )
            else:
                # Re-levanta outros erros
                raise e
    
    def _get_tts_instance(self):
        """Obtém instância do TTS (cached)."""
        if self._tts_instance is None:
            print(f"    📥 Carregando modelo: {self.model_name}")
            self._tts_instance = CoquiTTS(model_name=self.model_name)
            
            # Debug: mostra informações do modelo
            if hasattr(self._tts_instance, 'speakers') and self._tts_instance.speakers:
                print(f"    🎭 Modelo com {len(self._tts_instance.speakers)} vozes")
            else:
                print(f"    ℹ️ Modelo XTTS (clonagem + vozes automáticas)")
                
        return self._tts_instance
    
    def validate_dependencies(self) -> None:
        """Valida dependências do Coqui TTS."""
        if not TTS:
            raise RuntimeError("Coqui TTS não instalado. Execute: pip install TTS")
        
        try:
            subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            raise RuntimeError("ffmpeg não encontrado no PATH")
    
    def preview_voice(self) -> None:
        """Gera preview da voz selecionada com API corrigida."""
        preview_text = "Olá, teste de voz em português."  # Texto curto para teste
        preview_file = Path(".preview-coqui.wav")
        
        try:
            tts = self._get_tts_instance()
            
            if self.is_xtts:
                self._synthesize_xtts_fixed(tts, preview_text, preview_file)
            else:
                # Modelos não-XTTS
                if self.speaker and hasattr(tts, 'speakers') and tts.speakers and self.speaker in tts.speakers:
                    tts.tts_to_file(text=preview_text, file_path=str(preview_file), speaker=self.speaker)
                else:
                    tts.tts_to_file(text=preview_text, file_path=str(preview_file))
            
            self._play_preview(preview_file)
            print("✅ Preview gerado com sucesso!")
            
        except Exception as e:
            print(f"❌ Erro ao gerar preview Coqui: {e}")
            print("💡 Dica: Isso é normal na primeira execução. O modelo será baixado durante a conversão.")
    
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