"""
src/utils.py

Utilitários gerais para o sistema.
"""

import re
from pathlib import Path


def sanitize_filename(name: str, max_len: int = 120) -> str:
    """
    Sanitiza nome do arquivo removendo caracteres proibidos.
    
    Args:
        name: Nome para sanitizar
        max_len: Comprimento máximo do nome
        
    Returns:
        Nome sanitizado
    """
    forbidden_chars = r"\\/:*?\"<>|\n\r\t"
    forbidden_re = re.compile(f"[{forbidden_chars}]")
    multiple_space_re = re.compile(r"\s+")
    
    name = name.strip()
    name = multiple_space_re.sub(" ", name)
    name = forbidden_re.sub("-", name)
    
    if not name:
        name = "Sem título"
    
    return name[:max_len].rstrip(" .")


def zero_pad(i: int, total: int) -> str:
    """
    Retorna número com zero padding baseado no total.
    
    Args:
        i: Número atual
        total: Número total (para determinar padding)
        
    Returns:
        String com padding de zeros
    """
    width = max(2, len(str(total)))
    return str(i).zfill(width)


def format_file_size(size_bytes: int) -> str:
    """
    Formata tamanho de arquivo em formato legível.
    
    Args:
        size_bytes: Tamanho em bytes
        
    Returns:
        String formatada (ex: "1.5MB", "234KB")
    """
    if size_bytes == 0:
        return "0B"
    
    size_names = ["B", "KB", "MB", "GB"]
    i = 0
    size = float(size_bytes)
    
    while size >= 1024.0 and i < len(size_names) - 1:
        size /= 1024.0
        i += 1
    
    return f"{size:.1f}{size_names[i]}"


def format_duration(seconds: float) -> str:
    """
    Formata duração em formato legível.
    
    Args:
        seconds: Duração em segundos
        
    Returns:
        String formatada (ex: "1h 23m", "45s")
    """
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    
    if hours > 0:
        return f"{hours}h {minutes}m"
    elif minutes > 0:
        return f"{minutes}m {secs}s"
    else:
        return f"{secs}s"


def estimate_audio_duration(char_count: int, chars_per_minute: int = 1000) -> float:
    """
    Estima duração do áudio baseado no número de caracteres.
    
    Args:
        char_count: Número de caracteres
        chars_per_minute: Caracteres por minuto (velocidade de fala)
        
    Returns:
        Duração estimada em minutos
    """
    return char_count / chars_per_minute


def clean_temp_files(directory: Path, pattern: str = ".tmp-*") -> int:
    """
    Remove arquivos temporários de um diretório.
    
    Args:
        directory: Diretório para limpar
        pattern: Padrão dos arquivos temporários
        
    Returns:
        Número de arquivos removidos
    """
    removed_count = 0
    
    try:
        for temp_file in directory.glob(pattern):
            try:
                temp_file.unlink()
                removed_count += 1
            except Exception:
                pass
    except Exception:
        pass
    
    return removed_count


def validate_audio_file(file_path: Path) -> bool:
    """
    Valida se um arquivo de áudio existe e tem tamanho razoável.
    
    Args:
        file_path: Caminho do arquivo de áudio
        
    Returns:
        True se o arquivo for válido
    """
    if not file_path.exists():
        return False
    
    try:
        size = file_path.stat().st_size
        # Arquivo deve ter pelo menos 1KB (muito pequeno indica erro)
        return size > 1024
    except Exception:
        return False


def get_chapter_filename(index: int, total: int, title: str, extension: str = "mp3") -> str:
    """
    Gera nome de arquivo padronizado para capítulos.
    
    Args:
        index: Índice do capítulo
        total: Total de capítulos
        title: Título do capítulo
        extension: Extensão do arquivo
        
    Returns:
        Nome do arquivo formatado
    """
    index_str = zero_pad(index, total)
    clean_title = sanitize_filename(title)
    return f"{index_str} - {clean_title}.{extension}"


def print_book_info(title: str, author: str, chapters: list, engine: str, 
                   model_info: str, format_type: str) -> None:
    """
    Imprime informações formatadas do livro.
    
    Args:
        title: Título do livro
        author: Autor do livro
        chapters: Lista de capítulos
        engine: Engine TTS usado
        model_info: Informações do modelo/voz
        format_type: Tipo do arquivo original
    """
    total_chars = sum(len(text) for _, text in chapters)
    
    print(f"\n📖 INFORMAÇÕES DO LIVRO")
    print("=" * 60)
    print(f"Formato: {format_type}")
    print(f"Engine: {engine.upper()}")
    if author:
        print(f"Autor: {author}")
    print(f"Título: {title}")
    print(f"Capítulos: {len(chapters)}")
    print(f"Total de caracteres: {total_chars:,}")
    print(f"Modelo/Voz: {model_info}")
    print("=" * 60)


def print_conversion_summary(success_count: int, total_count: int, 
                           output_dir: Path, elapsed_time: str, 
                           total_size_mb: float, estimated_duration: str) -> None:
    """
    Imprime resumo da conversão.
    
    Args:
        success_count: Número de sucessos
        total_count: Total de capítulos
        output_dir: Diretório de saída
        elapsed_time: Tempo decorrido
        total_size_mb: Tamanho total em MB
        estimated_duration: Duração estimada
    """
    print("=" * 60)
    print(f"🎉 CONVERSÃO FINALIZADA")
    print("=" * 60)
    print(f"✅ Sucessos: {success_count}/{total_count} capítulos")
    print(f"📁 Pasta: {output_dir.resolve()}")
    print(f"⏱️ Tempo total: {elapsed_time}")
    print(f"💾 Tamanho total: {total_size_mb:.1f}MB")
    print(f"⏰ Duração estimada: {estimated_duration}")
    
    if success_count < total_count:
        print(f"⚠️ {total_count - success_count} capítulos falharam")
        print("💡 Dica: Execute novamente para tentar os que falharam")
    
    print("=" * 60)