"""
src/tts/coqui_engine.py

Engine TTS para Coqui TTS (100% local) - Versão corrigida para XTTS v2.
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
    """Engine TTS usando Coqui TTS local (100% privado) - Versão corrigida para XTTS v2."""
    
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
    
    def synthesize(self, text: str, output_path: Path) -> None:
        """
        Sintetiza texto usando Coqui TTS local.
        
        Args:
            text: Texto para sintetizar
            output_path: Caminho de saída do arquivo MP3
        """
        chunks = self.chunk_text(text, max_chars=1500)
        
        if len(chunks) == 1:
            self._synthesize_single_chunk(text, output_path)
        else:
            self._synthesize_multiple_chunks(chunks, output_path)
    
    def _synthesize_single_chunk(self, text: str, output_path: Path) -> None:
        """Sintetiza um único chunk."""
        wav_tmp = output_path.with_suffix('.wav')
        
        try:
            tts = self._get_tts_instance()
            
            # Verifica se é modelo XTTS e ajusta parâmetros
            if self._is_xtts_model():
                self._synthesize_xtts(tts, text, wav_tmp)
            elif self.speaker and hasattr(tts, 'speakers') and tts.speakers:
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
                if self._is_xtts_model():
                    self._synthesize_xtts(tts, chunk, temp_wav)
                elif self.speaker and hasattr(tts, 'speakers') and tts.speakers:
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
    
    def _synthesize_xtts(self, tts, text: str, wav_path: Path) -> None:
        """
        Sintetiza usando XTTS detectando automaticamente v1 vs v2 e configurando adequadamente.
        
        Args:
            tts: Instância do TTS
            text: Texto para sintetizar
            wav_path: Caminho do arquivo WAV de saída
        """
        # Detecta versão do XTTS baseado no model_name
        is_v2 = "v2" in self.model_name.lower()
        
        if is_v2:
            print("🎤 XTTS v2 detectado - usando clonagem de voz")
            
            # 1. Verifica arquivo de voz de referência
            ref_voice_path = Path("./reference_voice.wav")
            
            if ref_voice_path.exists():
                # Voice cloning com arquivo de referência
                print(f"🎤 Usando voz clonada: {ref_voice_path}")
                tts.tts_to_file(
                    text=text,
                    file_path=str(wav_path),
                    speaker_wav=str(ref_voice_path),
                    language="pt"
                )
            elif self.speaker and self.speaker.endswith('.wav'):
                # Speaker é um arquivo de áudio
                print(f"🎤 Usando arquivo de voz configurado: {self.speaker}")
                tts.tts_to_file(
                    text=text,
                    file_path=str(wav_path),
                    speaker_wav=self.speaker,
                    language="pt"
                )
            elif self.speaker:
                # Speaker é um nome pré-definido (XTTS v2 tem alguns hardcoded)
                print(f"🎤 Usando speaker configurado: {self.speaker}")
                tts.tts_to_file(
                    text=text,
                    file_path=str(wav_path),
                    speaker=self.speaker,
                    language="pt"
                )
            else:
                # Fallback: usa speakers conhecidos do XTTS v2
                known_speakers = ["Ana Florence", "Claribel Dervla", "Tammie Ema"]
                selected_speaker = known_speakers[0]  # Ana Florence é a melhor para PT-BR
                
                print(f"🎤 Usando speaker padrão para XTTS v2: {selected_speaker}")
                tts.tts_to_file(
                    text=text,
                    file_path=str(wav_path),
                    speaker=selected_speaker,
                    language="pt"
                )
        else:
            print("🎤 XTTS v1 detectado - modelo tradicional")
            
            # Para XTTS v1, verifica se tem speakers disponíveis
            has_speakers = hasattr(tts, 'speakers') and tts.speakers
            
            if has_speakers:
                # Usa primeiro speaker disponível
                default_speaker = tts.speakers[0]
                print(f"🎤 Usando speaker do v1: {default_speaker}")
                tts.tts_to_file(
                    text=text,
                    file_path=str(wav_path),
                    speaker=default_speaker,
                    language="pt"
                )
            elif self.speaker:
                # Tenta usar speaker configurado
                print(f"🎤 Tentando speaker configurado: {self.speaker}")
                tts.tts_to_file(
                    text=text,
                    file_path=str(wav_path),
                    speaker=self.speaker,
                    language="pt"
                )
            else:
                # Síntese básica sem speaker (single-speaker model)
                print("🎤 Síntese básica XTTS v1 (sem speaker)")
                tts.tts_to_file(
                    text=text,
                    file_path=str(wav_path),
                    language="pt"
                )
    
    def _get_tts_instance(self):
        """Obtém instância do TTS (cached) com informações corretas sobre XTTS."""
        if self._tts_instance is None:
            print(f"📥 Carregando modelo: {self.model_name}")
            self._tts_instance = CoquiTTS(model_name=self.model_name)
            
            # Se é XTTS, mostra informações específicas da versão
            if self._is_xtts_model():
                is_v2 = "v2" in self.model_name.lower()
                
                if is_v2:
                    print("📢 XTTS v2: Modelo de clonagem de voz")
                    print("   💡 Para melhor qualidade, use reference_voice.wav")
                    print("   💡 Speakers disponíveis: Ana Florence, Claribel Dervla, Tammie Ema")
                else:
                    print("📢 XTTS v1: Modelo tradicional")
                    if hasattr(self._tts_instance, 'speakers') and self._tts_instance.speakers:
                        print(f"   📢 {len(self._tts_instance.speakers)} speakers disponíveis")
                        for i, speaker in enumerate(self._tts_instance.speakers[:3], 1):
                            print(f"      {i}. {speaker}")
                        if len(self._tts_instance.speakers) > 3:
                            print(f"      ... e mais {len(self._tts_instance.speakers) - 3}")
                    else:
                        print("   📢 Modelo single-speaker")
        
        return self._tts_instance
    
    def _is_xtts_model(self) -> bool:
        """Verifica se o modelo é XTTS."""
        return "xtts" in self.model_name.lower()
    
    def validate_dependencies(self) -> None:
        """Valida dependências do Coqui TTS."""
        if not TTS:
            raise RuntimeError("Coqui TTS não instalado. Execute: pip install TTS")
        
        try:
            subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            raise RuntimeError("ffmpeg não encontrado no PATH")
    
    def preview_voice(self) -> None:
        """Gera preview da voz selecionada - VERSÃO CORRIGIDA PARA XTTS v1/v2."""
        preview_text = "Olá! Esta é uma demonstração da voz selecionada para o XTTS em português brasileiro. A qualidade será mantida durante toda a conversão."
        preview_file = Path(".preview-coqui.wav")
        
        try:
            tts = self._get_tts_instance()
            
            if self._is_xtts_model():
                # Para XTTS, usa a mesma lógica do _synthesize_xtts
                is_v2 = "v2" in self.model_name.lower()
                
                if is_v2:
                    # XTTS v2 - Voice cloning ou speakers conhecidos
                    ref_voice_path = Path("./reference_voice.wav")
                    
                    if ref_voice_path.exists():
                        print("🎤 Preview com voz clonada")
                        tts.tts_to_file(
                            text=preview_text,
                            file_path=str(preview_file),
                            speaker_wav=str(ref_voice_path),
                            language="pt"
                        )
                    elif self.speaker and self.speaker.endswith('.wav'):
                        print(f"🎤 Preview com arquivo: {self.speaker}")
                        tts.tts_to_file(
                            text=preview_text,
                            file_path=str(preview_file),
                            speaker_wav=self.speaker,
                            language="pt"
                        )
                    elif self.speaker:
                        print(f"🎤 Preview com speaker: {self.speaker}")
                        tts.tts_to_file(
                            text=preview_text,
                            file_path=str(preview_file),
                            speaker=self.speaker,
                            language="pt"
                        )
                    else:
                        # Usa Ana Florence como padrão
                        print("🎤 Preview com Ana Florence (padrão XTTS v2)")
                        tts.tts_to_file(
                            text=preview_text,
                            file_path=str(preview_file),
                            speaker="Ana Florence",
                            language="pt"
                        )
                else:
                    # XTTS v1 - Traditional speakers
                    if hasattr(tts, 'speakers') and tts.speakers:
                        default_speaker = tts.speakers[0]
                        print(f"🎤 Preview com speaker v1: {default_speaker}")
                        tts.tts_to_file(
                            text=preview_text,
                            file_path=str(preview_file),
                            speaker=default_speaker,
                            language="pt"
                        )
                    elif self.speaker:
                        print(f"🎤 Preview com speaker configurado: {self.speaker}")
                        tts.tts_to_file(
                            text=preview_text,
                            file_path=str(preview_file),
                            speaker=self.speaker,
                            language="pt"
                        )
                    else:
                        print("🎤 Preview básico XTTS v1")
                        tts.tts_to_file(
                            text=preview_text,
                            file_path=str(preview_file),
                            language="pt"
                        )
            else:
                # Modelos não-XTTS
                if self.speaker and hasattr(tts, 'speakers') and tts.speakers:
                    tts.tts_to_file(text=preview_text, file_path=str(preview_file), speaker=self.speaker)
                else:
                    tts.tts_to_file(text=preview_text, file_path=str(preview_file))
            
            print(f"✅ Preview gerado: {preview_file}")
            self._play_preview(preview_file)
            
        except Exception as e:
            print(f"❌ Erro ao gerar preview Coqui: {e}")
            print("💡 Dica: Para XTTS v2, certifique-se de ter um speaker configurado ou reference_voice.wav")
    
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