#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
main.py

Ponto de entrada principal - VERSÃO MELHORADA com estrutura de navegação.
"""

import argparse
import sys
import os
import re
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
        help="Caminho do arquivo .epub, .pdf ou use --from-txt para arquivo .txt"
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
        "--from-txt", 
        type=Path,
        help="Gera MP3 a partir de um arquivo TXT (modo direto de conversão)"
    )
    
    parser.add_argument(
        "--show-structure", 
        action="store_true", 
        help="Mostra estrutura dos capítulos sem converter"
    )
    
    return parser.parse_args()


def convert_txt_to_mp3(args):
    """Converte um arquivo TXT diretamente para MP3."""
    txt_file = args.from_txt
    
    # Valida arquivo TXT
    if not txt_file.exists():
        print(f"❌ ERRO: Arquivo TXT não encontrado: {txt_file}")
        sys.exit(1)
    
    if txt_file.suffix.lower() != '.txt':
        print(f"❌ ERRO: Arquivo deve ser .txt, recebido: {txt_file.suffix}")
        sys.exit(1)
    
    # Lê conteúdo do arquivo TXT
    try:
        with open(txt_file, 'r', encoding='utf-8') as f:
            text_content = f.read().strip()
    except Exception as e:
        print(f"❌ ERRO ao ler arquivo TXT: {e}")
        sys.exit(1)
    
    if not text_content:
        print(f"❌ ERRO: Arquivo TXT está vazio: {txt_file}")
        sys.exit(1)
    
    # Nome do arquivo MP3 de saída
    mp3_output = txt_file.with_suffix('.mp3')
    
    print(f"🎵 Convertendo TXT para MP3:")
    print(f"📄 Entrada: {txt_file}")
    print(f"🎵 Saída: {mp3_output}")
    print(f"📊 Tamanho: {len(text_content):,} caracteres")
    print(f"🔧 Engine: {args.engine}")
    
    # Inicializa TTS engine
    from src.tts_factory import TTSFactory
    
    factory = TTSFactory()
    
    # Configuração simples para TXT direto
    engine_config = {}
    if args.engine == "edge":
        engine_config = {"voice": args.voice}
    elif args.engine == "piper":
        engine_config = {"model_path": str(args.model_path)}
    elif args.engine == "coqui":
        engine_config = {"model": args.coqui_model}
    
    try:
        tts_engine = factory.create_engine(
            engine_type=args.engine,
            config=engine_config
        )
    except Exception as e:
        print(f"❌ ERRO ao inicializar TTS engine: {e}")
        sys.exit(1)
    
    # Converte texto para áudio
    try:
        print("🔄 Gerando áudio...")
        tts_engine.synthesize(text_content, mp3_output)  # Pass Path object directly
        print(f"✅ Conversão concluída: {mp3_output}")
    except Exception as e:
        print(f"❌ ERRO na conversão: {e}")
        sys.exit(1)


def main():
    """Função principal do programa."""
    try:
        args = parse_arguments()
        
        # Modo especial: conversão direta de TXT para MP3
        if args.from_txt:
            convert_txt_to_mp3(args)
            return
        
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
                # Verifica se é lista de HierarchicalChapter ou dicionários
                if hasattr(chapter_structure[0], 'level'):
                    levels = set(ch.level for ch in chapter_structure)
                elif isinstance(chapter_structure[0], dict):
                    levels = set(ch['level'] for ch in chapter_structure)
                else:
                    levels = {1}  # fallback
                
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
    
    if not chapters_or_structure:
        print("❌ Nenhum capítulo encontrado!")
        return
    
    # Format duration in human-readable format
    def format_duration(minutes):
        if minutes < 1:
            seconds = int(minutes * 60)
            return f"{seconds}s"
        elif minutes < 60:
            return f"{minutes:.1f}min"
        elif minutes < 1440:  # less than 24 hours
            hours = int(minutes // 60)
            remaining_minutes = int(minutes % 60)
            if remaining_minutes == 0:
                return f"{hours}h"
            return f"{hours}h {remaining_minutes}min"
        else:  # 24 hours or more
            days = int(minutes // 1440)
            remaining_hours = int((minutes % 1440) // 60)
            remaining_minutes = int(minutes % 60)
            
            parts = [f"{days}d"]
            if remaining_hours > 0:
                parts.append(f"{remaining_hours}h")
            if remaining_minutes > 0:
                parts.append(f"{remaining_minutes}min")
            
            return " ".join(parts)
    
    # Check if it's a list of HierarchicalChapter objects
    if hasattr(chapters_or_structure[0], 'title') and hasattr(chapters_or_structure[0], 'level'):
        # Estrutura hierárquica do toc.ncx
        total_chars = 0
        
        def print_hierarchical_chapter(hier_chapter, parent_index=""):
            """Recursivamente imprime capítulos hierárquicos."""
            nonlocal total_chars
            
            char_count = hier_chapter.char_count
            total_chars += char_count
            level = hier_chapter.level
            indent = "  " * (level - 1)
            level_icon = "📖" if level == 1 else "📄"
            
            # Usa o índice hierárquico ou gera um sequencial
            display_index = hier_chapter.index if hier_chapter.index else parent_index
            
            print(f"{str(display_index):>6s}. {indent}{level_icon} {hier_chapter.title}")
            formatted_duration = format_duration(hier_chapter.estimated_duration)
            print(f"        {indent}   📊 {char_count:,} chars | ~{formatted_duration}")
            
            # Nome do arquivo MP3 que seria gerado (apenas para folhas da árvore)
            if not hier_chapter.children:
                sanitized_name = hier_chapter.title.replace("/", "-").replace("\\", "-")
                # Remove caracteres especiais problemáticos
                sanitized_name = re.sub(r'[<>:"|?*]', '', sanitized_name)
                # Usa mesmo formato do conversor
                if isinstance(hier_chapter.index, str) and '.' in str(hier_chapter.index):
                    # Índice hierárquico (ex: "1.2" -> "001-2")
                    index_parts = str(hier_chapter.index).split('.')
                    main_idx = int(index_parts[0])
                    sub_idx = int(index_parts[1])
                    filename_index = f"{main_idx:03d}-{sub_idx}"
                else:
                    # Índice simples
                    filename_index = f"{int(hier_chapter.index):03d}"
                
                mp3_name = f"{filename_index} - {sanitized_name}.mp3"
                print(f"        {indent}   🎵 {mp3_name}")
            print()
            
            # Imprime filhos recursivamente
            for child in hier_chapter.children:
                print_hierarchical_chapter(child)
        
        for hier_chapter in chapters_or_structure:
            print_hierarchical_chapter(hier_chapter)
            
    elif isinstance(chapters_or_structure[0], dict):
        # Estrutura detalhada de dicionários (fallback antigo)
        total_chars = 0
        for item in chapters_or_structure:
            char_count = item.get('char_count', 0)
            total_chars += char_count
            duration = char_count / 1000 * 0.6  # Estimativa
            level = item.get('level', 1)
            indent = "  " * (level - 1)
            level_icon = "📖" if level == 1 else "📄"
            
            print(f"{item['index']:3d}. {indent}{level_icon} {item['name']}")
            formatted_duration = format_duration(duration)
            print(f"     {indent}   📊 {char_count:,} chars | ~{formatted_duration}")
            
            # Nome do arquivo MP3 que seria gerado
            sanitized_name = item['name'].replace("/", "-").replace("\\", "-")
            mp3_name = f"{item['index']:03d} - {sanitized_name}.mp3"
            print(f"     {indent}   🎵 {mp3_name}")
            print()
    elif hasattr(chapters_or_structure[0], 'name'):
        # Estrutura de Chapter objects
        total_chars = 0
        for chapter in chapters_or_structure:
            char_count = len(chapter.text)
            total_chars += char_count
            duration = char_count / 1000 * 0.6  # Estimativa
            
            print(f"{chapter.index:3d}. 📖 {chapter.name}")
            formatted_duration = format_duration(duration)
            print(f"     📊 {char_count:,} chars | ~{formatted_duration}")
            
            # Nome do arquivo MP3 que seria gerado
            sanitized_name = chapter.name.replace("/", "-").replace("\\", "-")
            mp3_name = f"{chapter.index:03d} - {sanitized_name}.mp3"
            print(f"     🎵 {mp3_name}")
            print()
    else:
        print(f"❌ Formato de estrutura não reconhecido: {type(chapters_or_structure[0])}")
        return
    
    # Calculate totals based on the structure type
    if isinstance(chapters_or_structure[0], dict):
        total_chars = sum(item.get('char_count', 0) for item in chapters_or_structure)
    elif hasattr(chapters_or_structure[0], 'text'):
        total_chars = sum(len(ch.text) for ch in chapters_or_structure)
    elif hasattr(chapters_or_structure[0], 'char_count'):
        # HierarchicalChapter objects - sum char_count recursively
        def sum_hierarchical_chars(chapters):
            total = 0
            for ch in chapters:
                total += ch.char_count
                if hasattr(ch, 'children') and ch.children:
                    total += sum_hierarchical_chars(ch.children)
            return total
        total_chars = sum_hierarchical_chars(chapters_or_structure)
    else:
        total_chars = 0
    
    total_duration_minutes = total_chars / 1000 * 0.6
    formatted_duration = format_duration(total_duration_minutes)
    
    print("=" * 60)
    print(f"📊 TOTAL: {len(chapters_or_structure)} capítulos | "
          f"{total_chars:,} caracteres | ~{formatted_duration}")
    print("=" * 60)


if __name__ == "__main__":
    main()