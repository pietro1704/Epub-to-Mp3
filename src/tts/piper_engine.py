# -*- coding: utf-8 -*-
"""
Piper TTS Engine - Lightweight local TTS
"""

import subprocess
import asyncio
from pathlib import Path
from typing import Dict, Any
from .base import TTSEngine


class PiperTTSEngine(TTSEngine):
    """Engine Piper TTS local e leve"""
    
    def _validate_dependencies(self) -> None:
        """Valida dependências do Piper TTS"""
        # Verifica se piper está no PATH
        try:
            subprocess.run(['piper', '--version'], 
                         capture_output=True, check=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            raise ImportError(
                "Piper TTS não encontrado no PATH. Instale: https://github.com/rhasspy/piper"
            )
        
        # Verifica modelo
        model_path = self.config.get('model_path')
        if not model_path or not Path(model_path).exists():
            raise FileNotFoundError(
                f"Modelo Piper não encontrado: {model_path}. "
                f"Configure model_path no config ou baixe modelos de "
                f"https://github.com/rhasspy/piper/releases"
            )
    
    async def synthesize(self, text: str, output_path: Path) -> bool:
        """Sintetiza texto usando Piper TTS"""
        try:
            # Limita texto para Piper
            if len(text) > self.get_max_chunk_size():
                text = text[:self.get_max_chunk_size()]
            
            # Comando Piper
            model_path = self.config.get('model_path')
            cmd = [
                'piper',
                '--model', str(model_path),
                '--output_file', str(output_path)
            ]
            
            # Adiciona configurações extras se disponíveis
            if 'speaker' in self.config:
                cmd.extend(['--speaker', str(self.config['speaker'])])
            
            # Executa Piper
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            
            stdout, stderr = await process.communicate(input=text.encode('utf-8'))
            
            if process.returncode == 0:
                # Valida arquivo gerado
                return output_path.exists() and output_path.stat().st_size > 1000
            else:
                print(f"❌ Erro Piper TTS: {stderr.decode()}")
                return False
                
        except Exception as e:
            print(f"❌ Erro Piper TTS: {e}")
            return False
    
    def get_max_chunk_size(self) -> int:
        """Piper TTS - tamanho médio de chunk"""
        return 3000
    
    def get_voice_info(self) -> Dict[str, Any]:
        """Informações da voz Piper TTS"""
        model_path = self.config.get('model_path', '')
        model_name = Path(model_path).stem if model_path else self.voice
        
        return {
            'engine': 'piper-tts',
            'voice': self.voice,
            'model_path': model_path,
            'model_name': model_name,
            'language': self._detect_language_from_model(model_name),
            'quality': 'medium',
            'online_required': False,
            'speaker': self.config.get('speaker'),
            'description': f'Modelo Piper: {model_name}'
        }
    
    def _detect_language_from_model(self, model_name: str) -> str:
        """Detecta idioma pelo nome do modelo"""
        if 'pt_br' in model_name.lower() or 'brazilian' in model_name.lower():
            return 'pt-BR'
        elif 'pt' in model_name.lower() or 'portuguese' in model_name.lower():
            return 'pt-PT'
        return 'unknown'
    
    def get_available_speakers(self) -> list:
        """Retorna speakers disponíveis no modelo"""
        try:
            model_path = self.config.get('model_path')
            if not model_path:
                return []
            
            # Lista speakers do modelo
            cmd = ['piper', '--model', str(model_path), '--list-speakers']
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            
            # Parse output (format depends on Piper version)
            speakers = []
            for line in result.stdout.splitlines():
                if line.strip() and not line.startswith('#'):
                    speakers.append(line.strip())
            
            return speakers
            
        except Exception:
            return []