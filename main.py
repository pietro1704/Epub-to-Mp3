#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
main.py

Ponto de entrada principal para conversão de EPUB/PDF em MP3 usando TTS.
Versão corrigida e funcional.
"""

import argparse
import sys
import os
from pathlib import Path

# Adiciona o diretório src ao path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))

from cache_manager import CacheManager
from ebook_reader import EbookReader
from tts_factory import TTSFactory
from converter import EbookToAudioConverter
from progress_tracker import ProgressTracker
from ui.menu import MenuInterface
from config import Config


def parse_arguments():
    """Configura e processa argumentos da linha de comando."""
    parser = argparse.ArgumentParser(
        description="Converte EPUB/PDF em MP3s por capítulo usando TTS"
    )
    
    parser.add_argument(
        "file_path", 
        type=Path, 
        help="Caminho do arquivo .epub ou .pdf"
    )
    
    parser.add_argument(
        "--engine", 
        choices=["edge", "coqui", "piper"], 
        help="Engine TTS (se não especificado, mostra menu)"
    )
    
    parser.add_argument(
        "--voice", 
        help="Voz específica (Edge-TTS)"
    )
    
    parser.add_argument(
        "--model-path", 
        type=Path, 
        default=Path("./models/pt_BR-faber-medium.onnx"),
        help="Modelo Piper (.onnx)"
    )
    
    parser.add_argument(
        "--coqui-model", 
        help="Modelo Coqui TTS"
    )
    
    parser.add_argument(
        "--no-cache", 
        action="store_true", 
        help="Força reprocessamento do arquivo (ignora cache)"
    )
    
    parser.add_argument(
        "--bitrate", 
        default="32k", 
        help="Bitrate MP3"
    )
    
    parser.add_argument(
        "--ar", 
        type=int, 
        default=22050, 
        help="Sample rate"
    )
    
    parser.add_argument(
        "--ac", 
        type=int, 
        default=1, 
        help="Canais de áudio"
    )
    
    parser.add_argument(
        "--skip-validation", 
        action="store_true", 
        help="Pula validação"
    )
    
    return parser.parse_args()


def main():
    """Função principal do programa."""
    try:
        args = parse_arguments()
        
        # Valida arquivo de entrada
        if not args.file_path.exists():
            print(f"❌ ERRO: Arquivo não encontrado: {args.file_path}")
            sys.exit(1)
        
        # Valida formato
        file_ext = args.file_path.suffix.lower()
        if file_ext not in ['.epub', '.pdf']:
            print(f"❌ ERRO: Formato não suportado: {file_ext}. Use .epub ou .pdf")
            sys.exit(1)
        
        # Inicializa componentes
        cache_manager = CacheManager()
        ebook_reader = EbookReader()
        menu = MenuInterface()
        
        # Gerencia cache
        book_title_preview = args.file_path.stem
        existing_cache = cache_manager.check_existing_cache(book_title_preview)
        
        if existing_cache and not args.no_cache:
            print(f"📂 Usando cache existente: {existing_cache}")
            try:
                metadata, chapters = cache_manager.load_from_cache(existing_cache)
                book_title = metadata["title"]
                author = None
                print(f"✅ Cache carregado: {len(chapters)} capítulos")
            except Exception as e:
                print(f"⚠️ Erro no cache ({e}), reprocessando arquivo...")
                book_title, author, chapters = ebook_reader.read_ebook(args.file_path)
                cache_manager.create_cache_structure(book_title, chapters)
        else:
            if args.no_cache and existing_cache:
                print(f"🔄 Flag --no-cache: ignorando cache e reprocessando arquivo")
            
            # Lê arquivo e cria/atualiza cache
            book_title, author, chapters = ebook_reader.read_ebook(args.file_path)
            cache_manager.create_cache_structure(book_title, chapters)
            print(f"✅ {file_ext.upper()} processado e cache atualizado")
        
        # Seleção de engine via menu se não especificado
        if not args.engine:
            args.engine = menu.show_engine_menu()
        
        # Configuração específica por engine
        tts_factory = TTSFactory()
        
        if args.engine == "edge":
            voice = args.voice or menu.get_edge_voice()
            engine_config = {
                "voice": voice,
                "bitrate": args.bitrate,
                "ar": args.ar,
                "ac": args.ac
            }
        elif args.engine == "coqui":
            if args.coqui_model:
                model_name = args.coqui_model
                speaker = None
            else:
                model_name, speaker = menu.get_coqui_model()
            engine_config = {"model_name": model_name, "speaker": speaker}
        elif args.engine == "piper":
            model_path = args.model_path
            if not model_path.exists():
                model_path = menu.get_piper_model()
            engine_config = {"model_path": model_path}
        
        # Validação
        if not args.skip_validation:
            try:
                tts_engine = tts_factory.create_engine(args.engine, engine_config)
                tts_engine.validate_dependencies()
            except Exception as e:
                print(f"\n❌ ERRO: {e}")
                sys.exit(1)
        
        # Configuração global
        config = Config(
            engine=args.engine,
            engine_config=engine_config,
            book_title=book_title,
            author=author,
            chapters=chapters,
            output_format=file_ext.upper(),
            force_reprocess=args.no_cache  # Passa flag --no-cache
        )
        
        # Inicializa conversor
        converter = EbookToAudioConverter(config, tts_factory, cache_manager)
        
        # Executa conversão
        converter.convert()
        
    except KeyboardInterrupt:
        print("\n\n👋 Conversão cancelada pelo usuário")
        sys.exit(0)
    except Exception as e:
        print(f"\n❌ ERRO: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()