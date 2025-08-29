#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
EBook to Audiobook Converter - Versão SOLID Expert
Conversor EPUB/PDF para MP3 usando múltiplos engines TTS

Funcionalidades:
- Menu interativo para seleção de engine/voz  
- Múltiplos engines: Edge-TTS, Coqui TTS, Piper TTS
- Estrutura hierárquica de capítulos preservada
- Cache inteligente de ebooks processados
- Progress tracking com ETA
- Arquitetura SOLID e extensível

Uso:
    python main.py book.epub                    # Menu interativo
    python main.py book.epub --engine edge      # Engine específico
    python main.py book.epub --show-structure   # Apenas mostra estrutura
"""

import argparse
import asyncio
import sys
import os
from pathlib import Path
from datetime import datetime

# Adiciona src ao path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))

from src.ui import show_tts_menu, show_quick_menu
from src.converter import convert_ebook_to_audio, ConversionConfig
from src.ebook_reader import EbookReader
from src.tts import get_tts_factory
from src.utils import validate_file_exists, sanitize_filename


class EbookConverterCLI:
    """CLI principal do conversor - seguindo princípios SOLID"""
    
    def __init__(self):
        self.tts_factory = get_tts_factory()
    
    def create_argument_parser(self) -> argparse.ArgumentParser:
        """Cria parser de argumentos"""
        parser = argparse.ArgumentParser(
            description="EBook to Audiobook Converter - TTS engines múltiplos",
            formatter_class=argparse.RawDescriptionHelpFormatter,
            epilog="""
Exemplos de uso:
  %(prog)s book.epub                           # Menu interativo
  %(prog)s book.epub --engine edge             # Edge-TTS direto  
  %(prog)s book.epub --engine coqui --voice tts_models/multilingual/multi-dataset/xtts_v2
  %(prog)s book.epub --engine piper --model-path ./models/pt_BR-faber-medium.onnx
  %(prog)s book.epub --show-structure          # Apenas estrutura do livro
  %(prog)s book.epub --no-cache                # Força reprocessamento
  %(prog)s book.epub --output ./meu_audiobook  # Diretório customizado

Engines disponíveis:
  edge     - Microsoft Edge-TTS (online, alta qualidade)
  coqui    - Coqui TTS (local, IA neural com voice cloning)  
  piper    - Piper TTS (local, leve e rápido)
            """
        )
        
        # Argumentos principais
        parser.add_argument(
            "ebook_file",
            help="Caminho para arquivo EPUB ou PDF"
        )
        
        parser.add_argument(
            "--engine", "-e",
            choices=['edge', 'coqui', 'piper'],
            help="Engine TTS (se não especificado, abre menu interativo)"
        )
        
        parser.add_argument(
            "--voice", "-v",
            help="Voz específica do engine (se não especificado, abre seletor)"
        )
        
        parser.add_argument(
            "--output", "-o",
            type=Path,
            help="Diretório de saída (padrão: nome do livro)"
        )
        
        parser.add_argument(
            "--show-structure",
            action="store_true",
            help="Apenas mostra estrutura de capítulos sem converter"
        )
        
        parser.add_argument(
            "--split-long-chapters",
            type=int,
            metavar="MINUTES",
            help="Divide capítulos longos automaticamente (especifica duração máxima em minutos)"
        )
        
        parser.add_argument(
            "--no-cache",
            action="store_true", 
            help="Não usa cache, força reprocessamento do EPUB"
        )
        
        parser.add_argument(
            "--skip-validation",
            action="store_true",
            help="Pula validação de dependências"
        )
        
        # Argumentos específicos por engine
        engine_group = parser.add_argument_group('Configurações de Engine')
        
        engine_group.add_argument(
            "--model-path",
            help="Caminho para modelo Piper TTS (.onnx)"
        )
        
        engine_group.add_argument(
            "--reference-voice", 
            help="Arquivo de referência para voice cloning (Coqui TTS)"
        )
        
        engine_group.add_argument(
            "--speaker",
            type=int,
            help="ID do speaker para modelos multi-speaker"
        )
        
        engine_group.add_argument(
            "--chunk-size",
            type=int,
            help="Tamanho máximo de texto por síntese"
        )
        
        # Argumentos de controle
        control_group = parser.add_argument_group('Controle de Execução')
        
        control_group.add_argument(
            "--max-retries",
            type=int,
            default=3,
            help="Máximo de tentativas por capítulo (padrão: 3)"
        )
        
        control_group.add_argument(
            "--no-skip-existing", 
            action="store_true",
            help="Reprocessa arquivos existentes"
        )
        
        control_group.add_argument(
            "--quiet", "-q",
            action="store_true",
            help="Modo silencioso (menos output)"
        )
        
        return parser
    
    def _natural_sort_key(self, text: str) -> list:
        """Cria chave para ordenação natural de números (1, 2, 10 vs 1, 10, 2)"""
        import re
        return [int(part) if part.isdigit() else part.lower() for part in re.split(r'(\d+)', text)]
    
    def validate_dependencies(self, engine: str) -> bool:
        """Valida se engine tem dependências disponíveis"""
        try:
            available_engines = self.tts_factory.get_available_engines()
            return available_engines.get(engine, False)
        except Exception as e:
            print(f"❌ Erro na validação: {e}")
            return False
    
    async def show_ebook_structure(self, ebook_path: Path) -> None:
        """Mostra estrutura do ebook exatamente como será convertida (1 arquivo por capítulo)"""
        print(f"📖 Analisando estrutura: {ebook_path.name}")
        print("="*60)
        
        try:
            reader = EbookReader(ebook_path)
            
            print(f"📚 Título: {reader.title}")
            print(f"✍️  Autor: {reader.author}")
            
            # Verifica se existe cache físico para mostrar exatamente os mesmos arquivos
            cache_dir = Path(".cache") / ebook_path.stem
            cached_files = []
            
            if cache_dir.exists() and list(cache_dir.glob("*.txt")):
                print("✅ Usando estrutura do cache existente para máxima precisão")
                # Lê TODOS os arquivos .txt do cache em ordem
                txt_files = sorted(cache_dir.glob("*.txt"), key=lambda x: self._natural_sort_key(x.stem))
                
                for txt_file in txt_files:
                    filename = txt_file.stem
                    # Extrai título completo do nome do arquivo
                    if ' - ' in filename:
                        parts = filename.split(' - ', 1)
                        if len(parts) > 1:
                            index_part = parts[0]
                            title_part = parts[1]
                            
                            # Lê o conteúdo do arquivo para contar caracteres
                            try:
                                with open(txt_file, 'r', encoding='utf-8') as f:
                                    content = f.read()
                                # Remove o cabeçalho "# Título" se existir
                                if content.startswith('#'):
                                    lines = content.split('\n', 1)
                                    if len(lines) > 1:
                                        content = lines[1].strip()
                                
                                from src.ebook_reader import Chapter
                                cached_files.append(Chapter(
                                    index=index_part,
                                    name=title_part,
                                    source_path=str(txt_file),
                                    text=content
                                ))
                            except Exception as e:
                                print(f"⚠️ Erro ao ler {txt_file}: {e}")
                
                flat_chapters = cached_files
            else:
                # Fallback: usa estrutura hierárquica
                chapters = reader.get_chapter_structure()
                
                if not chapters:
                    print("❌ Nenhum capítulo encontrado")
                    return
                
                # Achata hierarquia igual ao conversor (usando mesma lógica)
                flat_chapters = self._flatten_chapter_hierarchy(chapters, reader)
            
            # Se solicitado, divide capítulos longos
            if hasattr(self, '_split_long_chapters_minutes') and self._split_long_chapters_minutes:
                split_chapters = []
                for chapter in flat_chapters:
                    split_result = self._split_long_chapter(chapter, self._split_long_chapters_minutes)
                    split_chapters.extend(split_result)
                flat_chapters = split_chapters
            
            if not flat_chapters:
                print("❌ Nenhum capítulo com conteúdo encontrado")
                return
            
            print(f"\n📑 ESTRUTURA DE CONVERSÃO ({len(flat_chapters)} arquivos)")
            print("📄 Cada linha = 1 arquivo TXT + 1 arquivo MP3")
            print("="*60)
            
            total_chars = 0
            
            for i, chapter in enumerate(flat_chapters, 1):
                # Usa o nome completo do capítulo (igual ao que será salvo no cache)
                # Formato: "001 - Livro primeiro - Capítulo 1 - É no início que"
                chapter_title = chapter.name
                
                # Se for um nome de arquivo (.html), tenta extrair um título melhor
                if chapter_title.endswith('.html') or len(chapter_title.strip()) < 5:
                    # Extrai primeiras palavras do conteúdo como título
                    if chapter.text and len(chapter.text.strip()) > 0:
                        from src.ebook_reader import _extract_first_words
                        try:
                            first_words = _extract_first_words(chapter.text, max_words=6)
                            if first_words:
                                chapter_title = first_words
                            else:
                                chapter_title = f"Capítulo {chapter.index}"
                        except:
                            chapter_title = f"Capítulo {chapter.index}"
                    else:
                        chapter_title = f"Capítulo {chapter.index}"
                
                # Cria nome do arquivo igual ao que o sistema criará
                safe_title = sanitize_filename(chapter_title)
                filename = f"{str(chapter.index).zfill(3)} - {safe_title}"
                
                chars = len(chapter.text) if chapter.text else 0
                duration = chars / 1000 * 0.6  # Mesmo cálculo do sistema
                
                print(f"{i:3d}. {filename}")
                print(f"     📊 {chars:,} chars | ~{duration:.1f} min")
                
                total_chars += chars
            
            print("="*60)
            print(f"📊 RESUMO DA CONVERSÃO")
            print(f"   Arquivos que serão gerados: {len(flat_chapters)}")
            print(f"   Total de caracteres: {total_chars:,}")
            print(f"   Duração estimada: ~{total_chars/1000*0.6/60:.1f} horas")
            print("="*60)
            
        except Exception as e:
            print(f"❌ Erro ao analisar ebook: {e}")
    
    def _split_long_chapter(self, chapter, max_minutes: int) -> list:
        """Divide capítulo longo em subcapítulos baseado em quebras naturais."""
        max_chars = max_minutes * 1000 / 0.6  # Conversão inversa da estimativa
        
        if len(chapter.text) <= max_chars:
            return [chapter]  # Não precisa dividir
        
        # Procura por quebras naturais no texto
        text = chapter.text
        paragraphs = text.split('\n\n')
        
        subchapters = []
        current_text = ""
        current_chars = 0
        part_num = 1
        
        for paragraph in paragraphs:
            paragraph_chars = len(paragraph)
            
            # Se adicionar este parágrafo ultrapassar o limite
            if current_chars + paragraph_chars > max_chars and current_text:
                # Cria subcapítulo
                from src.ebook_reader import Chapter
                
                # Extrai título do início do texto atual
                from src.ebook_reader import _extract_first_words
                title_preview = _extract_first_words(current_text, max_words=4)
                if not title_preview:
                    title_preview = f"Parte {part_num}"
                else:
                    title_preview = f"Parte {part_num} - {title_preview}"
                
                subchapter = Chapter(
                    index=f"{chapter.index}.{part_num}",
                    name=title_preview,
                    source_path=chapter.source_path,
                    text=current_text.strip()
                )
                subchapters.append(subchapter)
                
                # Reset para próximo subcapítulo
                current_text = paragraph
                current_chars = paragraph_chars
                part_num += 1
            else:
                # Adiciona parágrafo ao subcapítulo atual
                if current_text:
                    current_text += "\n\n" + paragraph
                else:
                    current_text = paragraph
                current_chars += paragraph_chars
        
        # Adiciona último subcapítulo se houver texto restante
        if current_text.strip():
            from src.ebook_reader import Chapter
            
            from src.ebook_reader import _extract_first_words
            title_preview = _extract_first_words(current_text, max_words=4)
            if not title_preview:
                title_preview = f"Parte {part_num}"
            else:
                title_preview = f"Parte {part_num} - {title_preview}"
            
            subchapter = Chapter(
                index=f"{chapter.index}.{part_num}",
                name=title_preview,
                source_path=chapter.source_path,
                text=current_text.strip()
            )
            subchapters.append(subchapter)
        
        return subchapters if len(subchapters) > 1 else [chapter]

    def _flatten_chapter_hierarchy(self, chapters, reader=None):
        """Achata hierarquia de capítulos em lista linear (mesmo código do conversor)"""
        flat_chapters = []
        
        # Mapeia capítulos originais por index para buscar texto
        original_chapters = {}
        if reader and reader.book and reader.book.chapters:
            for ch in reader.book.chapters:
                original_chapters[ch.index] = ch
        
        def flatten_recursive(chapter_list):
            for chapter in chapter_list:
                # Tenta obter texto do capítulo original se não tiver no hierárquico
                chapter_text = ""
                if hasattr(chapter, 'text') and chapter.text:
                    chapter_text = chapter.text
                elif chapter.index in original_chapters:
                    chapter_text = original_chapters[chapter.index].text
                elif hasattr(chapter, 'char_count') and chapter.char_count > 0:
                    chapter_text = f"Capítulo: {chapter.title}\n\n[Conteúdo será carregado durante conversão]"
                
                # Adiciona capítulo se tem conteúdo
                if chapter_text and len(chapter_text.strip()) > 0:
                    from src.ebook_reader import Chapter
                    
                    chapter_wrapper = Chapter(
                        index=chapter.index,
                        name=chapter.title,
                        source_path=getattr(chapter, 'src', ''),
                        text=chapter_text
                    )
                    flat_chapters.append(chapter_wrapper)
                
                # Processa filhos se existirem
                if hasattr(chapter, 'children') and chapter.children:
                    flatten_recursive(chapter.children)
        
        flatten_recursive(chapters)
        return flat_chapters
    
    async def run_conversion(self, args) -> None:
        """Executa conversão completa"""
        ebook_path = Path(args.ebook_file)
        
        # Valida arquivo
        if not validate_file_exists(ebook_path):
            print(f"❌ Arquivo não encontrado: {ebook_path}")
            return
        
        # Menu de seleção (se necessário)
        if not args.engine or not args.voice:
            try:
                engine, voice = show_tts_menu()
                if not args.engine:
                    args.engine = engine
                if not args.voice:
                    args.voice = voice
            except KeyboardInterrupt:
                print("\n👋 Cancelado pelo usuário")
                return
            except SystemExit:
                return
        
        # Valida dependências
        if not args.skip_validation:
            if not self.validate_dependencies(args.engine):
                print(f"❌ Engine '{args.engine}' não disponível ou dependências ausentes")
                self._show_installation_help(args.engine)
                return
        
        # Configura diretório de saída
        if args.output:
            output_dir = args.output
        else:
            # Nome baseado no arquivo na pasta output
            book_name = sanitize_filename(ebook_path.stem)
            output_dir = Path("output") / f"{book_name}_audiobook"
        
        # Configurações do engine
        engine_config = {}
        if args.model_path:
            engine_config['model_path'] = args.model_path
        if args.reference_voice:
            engine_config['reference_voice'] = args.reference_voice
        if args.speaker is not None:
            engine_config['speaker'] = args.speaker
        
        # Configuração de conversão
        conversion_config = ConversionConfig(
            engine=args.engine,
            voice=args.voice,
            output_dir=output_dir,
            chunk_size=args.chunk_size,
            use_cache=not args.no_cache,
            skip_existing=not args.no_skip_existing,
            max_retries=args.max_retries,
            engine_config=engine_config
        )
        
        # Callback de progresso
        def progress_callback(message):
            if not args.quiet:
                print(message)
        
        # Executa conversão
        print(f"\n🚀 INICIANDO CONVERSÃO")
        print("="*60)
        
        results = await convert_ebook_to_audio(
            ebook_path=ebook_path,
            engine=args.engine,
            voice=args.voice,
            output_dir=output_dir,
            progress_callback=progress_callback,
            **engine_config
        )
        
        # Mostra resultados
        self._show_conversion_results(results)
    
    def _show_installation_help(self, engine: str) -> None:
        """Mostra ajuda de instalação para engine"""
        install_commands = {
            'edge': 'pip install edge-tts',
            'coqui': 'pip install TTS torch torchaudio',
            'piper': 'Baixe de: https://github.com/rhasspy/piper/releases'
        }
        
        print(f"\n💡 Para usar o engine '{engine}':")
        print(f"   {install_commands.get(engine, 'Dependências não especificadas')}")
        
        if engine == 'piper':
            print("   Configure --model-path com o caminho para o modelo .onnx")
    
    def _show_conversion_results(self, results: dict) -> None:
        """Mostra resultados da conversão"""
        print(f"\n📊 RESULTADO DA CONVERSÃO")
        print("="*60)
        
        if results['success']:
            print(f"✅ Conversão concluída com sucesso!")
        else:
            print(f"⚠️  Conversão concluída com problemas")
        
        print(f"📈 Sucessos: {results['converted_chapters']}/{results['total_chapters']}")
        print(f"⏱️  Tempo total: {results['duration']:.1f}s")
        print(f"📁 Arquivos salvos em: {results['output_dir']}")
        
        if results['errors']:
            print(f"\n❌ Erros encontrados ({len(results['errors'])}):")
            for error in results['errors'][:5]:  # Mostra até 5 erros
                print(f"   • {error}")
            if len(results['errors']) > 5:
                print(f"   ... e mais {len(results['errors']) - 5} erros")
        
        print("="*60)
    
    async def main(self):
        """Função principal"""
        parser = self.create_argument_parser()
        args = parser.parse_args()
        
        try:
            # Configura divisão de capítulos longos se solicitado
            if args.split_long_chapters:
                self._split_long_chapters_minutes = args.split_long_chapters
            
            # Apenas estrutura
            if args.show_structure:
                await self.show_ebook_structure(Path(args.ebook_file))
            else:
                # Conversão completa
                await self.run_conversion(args)
                
        except KeyboardInterrupt:
            print("\n\n👋 Operação cancelada pelo usuário")
        except Exception as e:
            print(f"\n❌ Erro crítico: {e}")
            if not args.quiet:
                import traceback
                traceback.print_exc()


if __name__ == "__main__":
    print(f"""
🎵 EBook to Audiobook Converter v2.0 - Expert SOLID Edition
══════════════════════════════════════════════════════════
Arquitetura: Factory Pattern, Strategy Pattern, Dependency Injection
Engines: Edge-TTS (online) | Coqui TTS (AI local) | Piper TTS (leve)
Data: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
══════════════════════════════════════════════════════════
""")
    
    cli = EbookConverterCLI()
    asyncio.run(cli.main())