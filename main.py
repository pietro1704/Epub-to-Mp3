#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
main.py

Ponto de entrada principal - VERSÃO MELHORADA com estrutura de navegação.
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
from ui.menu import MenuInterface
from config import Config, EDGE_VOICES


def parse_arguments():
    """Configura e processa argumentos da linha de comando."""
    parser = argparse.ArgumentParser(
        description="Converte EPUB/PDF em MP3s por capítulo usando TTS - VERSÃO MELHORADA",
        epilog="Melhorias: estrutura de navegação original, progresso avançado, nomes estruturados"
    )
    
    parser.add_argument(
        "file_path", 
        type=Path, 
        help="Caminho do arquivo .epub ou .pdf"
    )
    
    parser.add_argument(
        "--engine", 
        choices=["edge", "coqui", "piper"], 
        default="edge",
        help="Engine TTS (padrão: edge)"
    )
    
    parser.add_argument(
        "--voice", 
        default="pt-BR-AntonioNeural",
        help="Voz específica Edge-TTS (padrão: pt-BR-AntonioNeural)"
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
    
    parser.add_argument(
        "--menu", 
        action="store_true", 
        help="Força exibição do menu de seleção"
    )
    
    parser.add_argument(
        "--show-structure", 
        action="store_true", 
        help="Mostra estrutura dos capítulos sem converter"
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
        print(f"args: {args}")
        ebook_reader = EbookReader()
        menu = MenuInterface()
        
        # Gerencia cache (melhorado)
        book_title_preview = args.file_path.stem
        existing_cache = cache_manager.check_existing_cache(book_title_preview)
        
        if existing_cache and not args.no_cache:
            print(f"📂 Usando cache existente: {existing_cache}")
            try:
                metadata, chapters = cache_manager.load_from_cache(existing_cache)
                book_title = metadata["title"]
                author = None
                chapter_structure = []  # Cache não tem estrutura detalhada
                print(f"✅ Cache carregado: {len(chapters)} capítulos")
            except Exception as e:
                print(f"⚠️ Erro no cache ({e}), reprocessando arquivo...")
                book_title, author, chapters = ebook_reader.read_ebook(args.file_path)
                chapter_structure = ebook_reader.get_chapter_structure()
                cache_manager.create_cache_structure(book_title, chapters)
        else:
            if args.no_cache and existing_cache:
                print(f"🔄 Flag --no-cache: ignorando cache e reprocessando arquivo")
            
            # Lê arquivo e cria/atualiza cache - COM ESTRUTURA MELHORADA
            print(f"📖 Extraindo estrutura de capítulos de {file_ext.upper()}...")
            book_title, author, chapters = ebook_reader.read_ebook(args.file_path)
            chapter_structure = ebook_reader.get_chapter_structure()
            
            # Mostra informações da estrutura extraída
            if chapter_structure:
                print(f"✅ Estrutura extraída: {len(chapter_structure)} capítulos")
                levels = set(ch['level'] for ch in chapter_structure)
                if len(levels) > 1:
                    print(f"📚 Níveis hierárquicos encontrados: {sorted(levels)}")
            
            cache_manager.create_cache_structure(book_title, chapters)
            print(f"✅ {file_ext.upper()} processado e cache atualizado")
        
        # NOVA: Opção para apenas mostrar estrutura
        if args.show_structure:
            show_chapter_structure(chapter_structure if chapter_structure else chapters)
            return
        
        # Seleção de engine e configuração (inalterada)
        if args.menu:
            args.engine = menu.show_engine_menu()
        
        # Mostra configuração padrão se não forçar menu
        if not args.menu:
            print(f"\n🎙️ CONFIGURAÇÃO PADRÃO")
            print("=" * 50)
            print(f"Engine: {args.engine.upper()}")
            if args.engine == "edge":
                voice_name = "Antonio - Masculino, padrão"
                for num, (voice_id, description) in EDGE_VOICES.items():
                    if voice_id == args.voice:
                        voice_name = description
                        break
                print(f"Voz: {voice_name}")
            print("💡 Use --menu para selecionar outras opções")
            print("💡 Use --show-structure para ver estrutura dos capítulos")
            print("=" * 50)
        
        # Configuração específica por engine (inalterada)
        tts_factory = TTSFactory()
        
        if args.engine == "edge":
            voice = args.voice if not args.menu else menu.get_edge_voice()
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
        
        # Validação (inalterada)
        if not args.skip_validation:
            try:
                tts_engine = tts_factory.create_engine(args.engine, engine_config)
                tts_engine.validate_dependencies()
            except Exception as e:
                print(f"\n❌ ERRO: {e}")
                print("\n💡 SOLUÇÕES:")
                if "edge-tts" in str(e).lower():
                    print("• pip install edge-tts")
                elif "ffmpeg" in str(e).lower():
                    print("• Ubuntu/Debian: sudo apt install ffmpeg")
                    print("• macOS: brew install ffmpeg")
                    print("• Windows: baixe de https://ffmpeg.org/")
                sys.exit(1)
        
        # Configuração global
        config = Config(
            engine=args.engine,
            engine_config=engine_config,
            book_title=book_title,
            author=author,
            chapters=chapters,
            output_format=file_ext.upper(),
            force_reprocess=args.no_cache
        )
        
        # Inicializa conversor COM ESTRUTURA
        converter = EbookToAudioConverter(config, tts_factory, cache_manager)
        
        # NOVA: Passa estrutura de capítulos para o conversor
        if chapter_structure:
            converter.set_chapter_structure(chapter_structure)
        
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


def show_chapter_structure(chapters_or_structure):
    """NOVA: Mostra estrutura dos capítulos."""
    print(f"\n📚 ESTRUTURA DOS CAPÍTULOS")
    print("=" * 60)
    
    if hasattr(chapters_or_structure[0], 'level') if chapters_or_structure else False:
        # Estrutura detalhada
        for i, chapter_info in enumerate(chapters_or_structure, 1):
            indent = "  " * (chapter_info.level - 1)
            level_icon = "📖" if chapter_info.level == 1 else "📄"
            
            print(f"{i:3d}. {indent}{level_icon} {chapter_info.title}")
            print(f"     {indent}   📊 {chapter_info.char_count:,} chars | "
                  f"~{chapter_info.estimated_duration:.1f}min | "
                  f"Level {chapter_info.level}")
            if chapter_info.original_id:
                print(f"     {indent}   🔗 {chapter_info.original_id}")
    else:
        # Estrutura simples (fallback)
        total_chars = 0
        for i, (title, text) in enumerate(chapters_or_structure, 1):
            char_count = len(text)
            total_chars += char_count
            duration = char_count / 1000 * 0.6  # Estimativa
            
            print(f"{i:3d}. 📖 {title}")
            print(f"     📊 {char_count:,} chars | ~{duration:.1f}min")
    
    if hasattr(chapters_or_structure[0], 'char_count') if chapters_or_structure else False:
        total_chars = sum(ch.char_count for ch in chapters_or_structure)
        total_duration = sum(ch.estimated_duration for ch in chapters_or_structure)
    else:
        total_chars = sum(len(text) for _, text in chapters_or_structure)
        total_duration = total_chars / 1000 * 0.6
    
    print("=" * 60)
    print(f"📊 TOTAL: {len(chapters_or_structure)} capítulos | "
          f"{total_chars:,} caracteres | ~{total_duration:.1f}min")
    print("=" * 60)


if __name__ == "__main__":
    main()