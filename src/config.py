"""
src/config.py

Configurações centralizadas do sistema.
"""

from dataclasses import dataclass
from typing import List, Tuple, Dict, Any, Optional


@dataclass
class Config:
    """Configurações centralizadas da aplicação."""
    
    # Engine TTS
    engine: str
    engine_config: Dict[str, Any]
    
    # Dados do livro
    book_title: str
    author: Optional[str]
    chapters: List[Tuple[str, str]]
    output_format: str
    
    # Configurações de controle
    force_reprocess: bool = False  # Para --no-cache
    
    # Configurações de áudio
    bitrate: str = "32k"
    sample_rate: int = 22050
    channels: int = 1
    
    # Configurações de processamento
    max_chunk_size: int = 1500
    edge_max_chunk_size: int = 8000
    
    # Configurações de arquivo
    max_filename_length: int = 120
    forbidden_chars: str = r"\\/:*?\"<>|\n\r\t"
    
    # Configurações de cache
    cache_dir: str = ".cache"
    
    # Timeouts
    ffmpeg_timeout: int = 120
    piper_timeout: int = 300
    
    def get_total_chars(self) -> int:
        """Retorna total de caracteres de todos os capítulos."""
        return sum(len(text) for _, text in self.chapters)
    
    def get_total_chapters(self) -> int:
        """Retorna número total de capítulos."""
        return len(self.chapters)
    
    def is_xtts_model(self) -> bool:
        """Verifica se o modelo é XTTS."""
        if self.engine == "coqui":
            model_name = self.engine_config.get("model_name", "")
            return "xtts" in model_name.lower()
        return False
    
    def get_model_short_name(self) -> str:
        """Retorna nome curto do modelo."""
        if self.engine == "edge":
            voice = self.engine_config.get('voice', '')
            return voice.split('-')[-1].replace('Neural', '')
        elif self.engine == "coqui":
            model_name = self.engine_config.get('model_name', '')
            return model_name.split('/')[-1]
        elif self.engine == "piper":
            model_path = self.engine_config.get('model_path')
            return model_path.name if model_path else "Desconhecido"
        return "Desconhecido"


# Configurações de vozes Edge-TTS
EDGE_VOICES = {
    # Vozes femininas
    "1": ("pt-BR-FranciscaNeural", "Francisca - Feminina, natural, recomendada ⭐"),
    "2": ("pt-BR-BrendaNeural", "Brenda - Feminina, jovem"),
    "3": ("pt-BR-ElzaNeural", "Elza - Feminina, madura"),
    "4": ("pt-BR-GiovannaNeural", "Giovanna - Feminina, suave"),
    "5": ("pt-BR-LeilaNeural", "Leila - Feminina, clara"),
    "6": ("pt-BR-LeticiaNeural", "Leticia - Feminina, jovem"),
    "7": ("pt-BR-ManuelaNeural", "Manuela - Feminina, expressiva"),
    "8": ("pt-BR-YaraNeural", "Yara - Feminina, doce"),
    
    # Vozes masculinas
    "9": ("pt-BR-AntonioNeural", "Antonio - Masculino, padrão"),
    "10": ("pt-BR-DonatoNeural", "Donato - Masculino, grave"),
    "11": ("pt-BR-FabioNeural", "Fabio - Masculino, jovem"),
    "12": ("pt-BR-HumbertoNeural", "Humberto - Masculino, firme"),
    "13": ("pt-BR-JulioNeural", "Julio - Masculino, forte"),
    "14": ("pt-BR-NicolauNeural", "Nicolau - Masculino, claro"),
    "15": ("pt-BR-ValerioNeural", "Valerio - Masculino, profundo")
}

# Configurações de modelos Coqui TTS
COQUI_MODELS = {
    "1": ("tts_models/multilingual/multi-dataset/xtts_v2", "XTTS v2 Multilíngue PT-BR", "Melhor qualidade, mais lento ⭐", True),
    "2": ("tts_models/multilingual/multi-dataset/xtts_v1.1", "XTTS v1.1 Multilíngue PT-BR", "Boa qualidade, médio", True),
    "3": ("tts_models/multilingual/multi-dataset/your_tts", "YourTTS Multilíngue PT-BR", "Qualidade OK, rápido", True),
    "4": ("tts_models/pt/cv/vits", "Português CV-VITS", "PT-PT, rápido, voz robótica", False)
}

# Configurações de modelos Piper conhecidos
KNOWN_PIPER_MODELS = {
    "pt_BR-faber-medium.onnx": "Faber - Masculino, médio ⭐",
    "pt_BR-faber-low.onnx": "Faber - Masculino, rápido",
    "pt_BR-edresson-low.onnx": "Edresson - Masculino, alternativo",
    "pt-br_male-edresson-low.onnx": "Edresson - Masculino BR",
}

# Padrões para detectar títulos de capítulos em PDFs
CHAPTER_PATTERNS = [
    r'^(CAPÍTULO|Capítulo|CHAPTER|Chapter)\s+([IVXLCDM]+|\d+)',
    r'^(PARTE|Parte|PART|Part)\s+([IVXLCDM]+|\d+)',
    r'^\d+\.\s+[A-Z]',  # "1. Título"
    r'^[IVXLCDM]+\.\s+',  # "I. Título"
    r'^CASA\s+[IVXLCDM]+',  # "CASA IV" - específico para astrologia
]

# Padrões para detectar subtítulos
SUBTITLE_PATTERNS = [
    r'^\d+\s*de\s+(janeiro|fevereiro|março|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)',
    r'^capítulo\s+[ivx\d]+',
    r'^diário\s+de',
    r'^\([^)]*\)',
    r'^\d+\s*$',
    r'^[A-Z\s]{3,}$',
    # Padrões astrológicos específicos
    r'^\w+\s+na\s+Casa\s+[IVXLCDM]+',  # "Lua na Casa IV"
    r'^Síntese:',
    r'^Exemplos:',
    r'^Aporia:',
]

# Adição ao src/config.py - Configurações expandidas do Piper

# Configurações expandidas de modelos Piper com informações detalhadas
PIPER_MODELS_DETAILED = {
    # Modelos Português Brasil - Masculinos
    "pt_BR-faber-medium.onnx": {
        "name": "Faber",
        "gender": "Masculino",
        "quality": "Médio",
        "speed": "Médio",
        "description": "Voz masculina natural, recomendada ⭐",
        "size_mb": 63,
        "sample_rate": 22050,
        "recommended": True
    },
    "pt_BR-faber-low.onnx": {
        "name": "Faber",
        "gender": "Masculino", 
        "quality": "Baixo",
        "speed": "Rápido",
        "description": "Voz masculina mais rápida",
        "size_mb": 20,
        "sample_rate": 22050,
        "recommended": False
    },
    "pt_BR-edresson-low.onnx": {
        "name": "Edresson",
        "gender": "Masculino",
        "quality": "Baixo", 
        "speed": "Rápido",
        "description": "Voz masculina alternativa",
        "size_mb": 20,
        "sample_rate": 22050,
        "recommended": False
    },
    
    # Modelos Português Brasil - Femininos (se disponíveis)
    "pt_BR-mel-medium.onnx": {
        "name": "Mel",
        "gender": "Feminino",
        "quality": "Médio",
        "speed": "Médio", 
        "description": "Voz feminina suave",
        "size_mb": 63,
        "sample_rate": 22050,
        "recommended": True
    },
    "pt_BR-luana-medium.onnx": {
        "name": "Luana",
        "gender": "Feminino",
        "quality": "Médio",
        "speed": "Médio",
        "description": "Voz feminina clara",
        "size_mb": 63, 
        "sample_rate": 22050,
        "recommended": True
    },
    
    # Modelos Português Portugal
    "pt-pt_female-tugao-medium.onnx": {
        "name": "Tugão",
        "gender": "Feminino",
        "quality": "Médio", 
        "speed": "Médio",
        "description": "Português europeu feminino",
        "size_mb": 63,
        "sample_rate": 22050,
        "recommended": False
    },
    
    # Modelos genéricos/personalizados
    "custom-voice.onnx": {
        "name": "Personalizado", 
        "gender": "Variável",
        "quality": "Variável",
        "speed": "Variável",
        "description": "Modelo personalizado",
        "size_mb": 0,
        "sample_rate": 22050,
        "recommended": False
    }
}

# URLs para download automático dos modelos mais populares
PIPER_MODEL_URLS = {
    "pt_BR-faber-medium.onnx": {
        "url": "https://github.com/rhasspy/piper/releases/download/v1.2.0/pt_BR-faber-medium.tar.gz",
        "config_url": "https://github.com/rhasspy/piper/releases/download/v1.2.0/pt_BR-faber-medium.onnx.json"
    },
    "pt_BR-faber-low.onnx": {
        "url": "https://github.com/rhasspy/piper/releases/download/v1.2.0/pt_BR-faber-low.tar.gz", 
        "config_url": "https://github.com/rhasspy/piper/releases/download/v1.2.0/pt_BR-faber-low.onnx.json"
    }
}

# Filtros para seleção
PIPER_FILTERS = {
    "gender": ["Masculino", "Feminino", "Todos"],
    "quality": ["Alto", "Médio", "Baixo", "Todos"],
    "language": ["PT-BR", "PT-PT", "Todos"]
}