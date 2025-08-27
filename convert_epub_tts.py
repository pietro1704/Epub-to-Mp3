#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
convert_epub_tts.py

Converte um EPUB em arquivos MP3 por capítulo usando diferentes engines TTS:
- Edge-TTS (Microsoft - rápido e gratuito, mas online)
- Coqui TTS (100% local)
- Piper (100% local CLI)

Sistema de cache automático para retomar conversões e trocar modelos.
Com pausas naturais entre títulos, capítulos e parágrafos.
"""

import argparse
import re
import sys
import subprocess
import os
import asyncio
import json
from pathlib import Path
from typing import List, Tuple, Dict

import ebooklib
from ebooklib import epub
from bs4 import BeautifulSoup

try:
    import edge_tts
except ImportError:
    edge_tts = None

try:
    import TTS
    from TTS.api import TTS as CoquiTTS
except ImportError:
    TTS = None

FORBIDDEN_FS_CHARS = r"\\/:*?\"<>|\n\r\t"
_forbidden_re = re.compile(f"[{FORBIDDEN_FS_CHARS}]")
_multiple_space_re = re.compile(r"\s+")

def sanitize_filename(name: str, max_len: int = 120) -> str:
    """Sanitiza nome do arquivo removendo caracteres proibidos."""
    name = name.strip()
    name = _multiple_space_re.sub(" ", name)
    name = _forbidden_re.sub("-", name)
    if not name:
        name = "Sem título"
    return name[:max_len].rstrip(" .")

def zero_pad(i: int, total: int) -> str:
    """Retorna número com zero padding baseado no total."""
    width = max(2, len(str(total)))
    return str(i).zfill(width)

def _html_title(soup: BeautifulSoup) -> str | None:
    """Extrai título do HTML."""
    if soup.title and soup.title.string:
        t = soup.title.string.strip()
        if t:
            return t
    for tag in ("h1", "h2", "h3"):
        h = soup.find(tag)
        if h and h.get_text(strip=True):
            return h.get_text(strip=True)
    return None

def _is_subtitle(text: str) -> bool:
    """Detecta se um texto é subtítulo/data."""
    if len(text) > 200:  # Textos muito longos não são subtítulos
        return False
    
    # Padrões de data e subtítulos
    patterns = [
        r'^\d+\s*de\s+(janeiro|fevereiro|março|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)',
        r'^capítulo\s+[ivx\d]+',
        r'^diário\s+de',
        r'^\([^)]*\)$',  # Texto entre parênteses
        r'^\d+\s*$',     # Números isolados
        r'^[A-Z\s]{3,}$', # Texto todo maiúsculo (como TAQUIGRAFADO)
    ]
    
    text_lower = text.lower()
    for pattern in patterns:
        if re.search(pattern, text_lower):
            return True
    
    # Se tem poucas palavras e não é uma frase completa
    words = text.split()
    if len(words) <= 6 and not text.endswith('.'):
        return True
    
    return False

def _extract_text(html_bytes: bytes) -> Tuple[str | None, str]:
    """Extrai título e texto limpo do HTML preservando estrutura hierárquica."""
    soup = BeautifulSoup(html_bytes, "html.parser")
    title = _html_title(soup)
    
    # Remove scripts e styles
    for bad in soup(["script", "style"]):
        bad.decompose()
    
    # Lista para armazenar todos os elementos de texto em ordem
    text_elements = []
    
    # Função recursiva para extrair texto preservando ordem e estrutura
    def extract_recursive(element, depth=0):
        if hasattr(element, 'name') and element.name:
            # Elementos de título (h1-h6)
            if element.name in ['h1', 'h2', 'h3', 'h4', 'h5', 'h6']:
                text = element.get_text(strip=True)
                if text:
                    text_elements.append(('header', text, depth))
                    text_elements.append(('pause', '', depth))
                return
            
            # Parágrafos e divs
            elif element.name in ['p', 'div']:
                # Verifica se tem sub-elementos importantes
                has_children = any(child.name in ['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'div'] 
                                 for child in element.find_all() if hasattr(child, 'name'))
                
                if has_children:
                    # Processa filhos recursivamente
                    for child in element.children:
                        if hasattr(child, 'name'):
                            extract_recursive(child, depth + 1)
                        elif child.string and child.string.strip():
                            text_elements.append(('text', child.string.strip(), depth))
                else:
                    # Elemento folha, pega texto direto
                    text = element.get_text(strip=True)
                    if text:
                        # Verifica se é subtítulo/data
                        if _is_subtitle(text):
                            text_elements.append(('pause', '', depth))
                            text_elements.append(('subtitle', text, depth))
                            text_elements.append(('pause', '', depth))
                        else:
                            text_elements.append(('text', text, depth))
                return
            
            # Quebras de linha
            elif element.name == 'br':
                text_elements.append(('pause', '', depth))
                return
        
        # Para elementos sem tag ou outros casos, processa filhos
        if hasattr(element, 'children'):
            for child in element.children:
                if hasattr(child, 'name'):
                    extract_recursive(child, depth)
                elif hasattr(child, 'string') and child.string and child.string.strip():
                    text = child.string.strip()
                    if text:
                        if _is_subtitle(text):
                            text_elements.append(('pause', '', depth))
                            text_elements.append(('subtitle', text, depth))
                            text_elements.append(('pause', '', depth))
                        else:
                            text_elements.append(('text', text, depth))
    
    # Processa o documento inteiro
    extract_recursive(soup.body if soup.body else soup)
    
    # Se não capturou nada estruturado, usa método tradicional
    if not text_elements:
        all_text = soup.get_text(" ", strip=True)
        if all_text:
            text_elements = [('text', all_text, 0)]
    
    # Monta texto final com pausas
    final_parts = []
    last_type = None
    
    for elem_type, text, depth in text_elements:
        if elem_type == 'pause':
            # Evita pausas duplas
            if last_type != 'pause':
                final_parts.append('... ...')
        elif elem_type in ['header', 'subtitle']:
            final_parts.append(text)
        elif elem_type == 'text':
            final_parts.append(text)
        
        last_type = elem_type
    
    # Junta tudo
    result_text = ' '.join(final_parts)
    
    # Limpeza final
    result_text = re.sub(r'(\.\.\. \.\.\.){3,}', '... ... ...', result_text)  # Max 3 pausas
    result_text = re.sub(r'\s+', ' ', result_text)  # Remove espaços múltiplos
    result_text = result_text.strip()
    
    return title, result_text

def read_epub(epub_path: Path) -> Tuple[str, str | None, List[Tuple[str, str]]]:
    """Lê EPUB e extrai metadados e capítulos."""
    print(f"[INFO] Lendo arquivo '{epub_path.name}' com extensão '{epub_path.suffix}'")
    
    try:
        book = epub.read_epub(str(epub_path))
    except Exception as e:
        raise RuntimeError(f"Erro ao ler EPUB: {e}")
    
    # Metadados
    md_title = None
    md_author = None
    
    titles = book.get_metadata('DC', 'title')
    if titles:
        md_title = titles[0][0]
    
    creators = book.get_metadata('DC', 'creator')
    if creators:
        md_author = creators[0][0]
    
    chapters: List[Tuple[str, str]] = []
    
    # Primeira tentativa: usar spine (ordem correta)
    for idx, (idref, _) in enumerate(book.spine, start=1):
        item = book.get_item_with_id(idref)
        if item and item.get_type() == ebooklib.ITEM_DOCUMENT:
            title, text = _extract_text(item.get_content())
            if text and len(text.strip()) > 50:
                ch_title = title or f"Capítulo {idx}"
                chapters.append((ch_title, text))
    
    # Fallback: se não achou capítulos via spine
    if not chapters:
        print("[AVISO] Não encontrou capítulos via spine, tentando todos os documentos...")
        for item in book.get_items_of_type(ebooklib.ITEM_DOCUMENT):
            title, text = _extract_text(item.get_content())
            if text and len(text.strip()) > 50:
                ch_title = title or f"Capítulo {len(chapters)+1}"
                chapters.append((ch_title, text))
    
    return md_title or epub_path.stem, md_author, chapters

# ========== SISTEMA DE CACHE ==========

def create_cache_structure(book_title: str, chapters: List[Tuple[str, str]]) -> Path:
    """Cria/atualiza estrutura de cache com textos separados."""
    cache_dir = Path(".cache") / sanitize_filename(book_title)
    cache_dir.mkdir(parents=True, exist_ok=True)
    
    # Salva metadados
    metadata = {
        "title": book_title,
        "total_chapters": len(chapters),
        "chapters": [],
        "created_at": str(Path.cwd()),
        "epub_processed": True
    }
    
    # Remove arquivos antigos se existirem
    for old_file in cache_dir.glob("*.txt"):
        try:
            old_file.unlink()
        except:
            pass
    
    # Salva cada capítulo como .txt
    for idx, (title, text) in enumerate(chapters, start=1):
        index_str = zero_pad(idx, len(chapters))
        safe_title = sanitize_filename(title)
        txt_name = f"{index_str} - {safe_title}.txt"
        txt_path = cache_dir / txt_name
        
        # Salva texto do capítulo
        with open(txt_path, 'w', encoding='utf-8') as f:
            f.write(text)
        
        metadata["chapters"].append({
            "index": idx,
            "title": title,
            "txt_file": txt_name,
            "char_count": len(text)
        })
    
    # Salva metadados
    with open(cache_dir / "metadata.json", 'w', encoding='utf-8') as f:
        json.dump(metadata, f, indent=2, ensure_ascii=False)
    
    print(f"📁 Cache atualizado: {cache_dir} ({len(chapters)} capítulos)")
    return cache_dir

def load_from_cache(cache_dir: Path) -> Tuple[Dict, List[Tuple[str, str]]]:
    """Carrega capítulos do cache."""
    metadata_file = cache_dir / "metadata.json"
    if not metadata_file.exists():
        raise FileNotFoundError("Cache metadata não encontrado")
    
    with open(metadata_file, 'r', encoding='utf-8') as f:
        metadata = json.load(f)
    
    chapters = []
    missing_files = []
    
    for ch_meta in metadata["chapters"]:
        txt_path = cache_dir / ch_meta["txt_file"]
        if txt_path.exists():
            with open(txt_path, 'r', encoding='utf-8') as f:
                text = f.read()
            chapters.append((ch_meta["title"], text))
        else:
            missing_files.append(ch_meta["txt_file"])
    
    if missing_files:
        raise FileNotFoundError(f"Arquivos de cache em falta: {missing_files}")
    
    return metadata, chapters

def check_existing_cache(book_title: str) -> Path | None:
    """Verifica se já existe cache para o livro."""
    cache_dir = Path(".cache") / sanitize_filename(book_title)
    if cache_dir.exists() and (cache_dir / "metadata.json").exists():
        return cache_dir
    return None

# ========== PREVIEW DE VOZES ==========

async def preview_edge_voice(voice: str) -> None:
    """Gera preview de 5 segundos da voz do Edge-TTS."""
    if not edge_tts:
        return
    
    preview_text = "Olá, esta é uma demonstração da voz selecionada para o seu audiolivro. A qualidade será mantida durante toda a conversão."
    preview_file = Path(f".preview-{voice.split('-')[-1]}.mp3")
    
    try:
        communicate = edge_tts.Communicate(preview_text, voice)
        await communicate.save(str(preview_file))
        
        # Tenta reproduzir automaticamente (macOS/Linux)
        try:
            if sys.platform == "darwin":  # macOS
                subprocess.run(["afplay", str(preview_file)], check=False)
            elif sys.platform.startswith("linux"):  # Linux
                subprocess.run(["aplay", str(preview_file)], check=False)
            else:  # Windows ou outros
                print(f"🎵 Preview salvo em: {preview_file}")
                print("   Reproduza manualmente para ouvir a voz")
        except:
            print(f"🎵 Preview salvo em: {preview_file}")
            
    except Exception as e:
        print(f"❌ Erro ao gerar preview: {e}")

def preview_coqui_voice(model_name: str) -> None:
    """Gera preview da voz do Coqui TTS."""
    if not TTS:
        return
    
    preview_text = "Esta é uma demonstração da voz Coqui selecionada."
    preview_file = Path(".preview-coqui.wav")
    
    try:
        tts = CoquiTTS(model_name=model_name)
        tts.tts_to_file(text=preview_text, file_path=str(preview_file))
        
        # Tenta reproduzir
        try:
            if sys.platform == "darwin":
                subprocess.run(["afplay", str(preview_file)], check=False)
            elif sys.platform.startswith("linux"):
                subprocess.run(["aplay", str(preview_file)], check=False)
            else:
                print(f"🎵 Preview salvo em: {preview_file}")
        except:
            print(f"🎵 Preview salvo em: {preview_file}")
            
    except Exception as e:
        print(f"❌ Erro ao gerar preview Coqui: {e}")

def chunk_text(text: str, max_chars: int = 1500) -> List[str]:
    """Divide texto em chunks menores respeitando pontuação e pausas naturais."""
    if len(text) <= max_chars:
        return [text]
    
    chunks = []
    
    # Primeiro divide por pausas longas (títulos/subtítulos)
    major_sections = re.split(r'(\.\.\. \.\.\.)', text)
    current_chunk = ""
    
    for section in major_sections:
        if section == "... ...":
            # Preserva pausas nos chunks
            if current_chunk:
                current_chunk += " " + section
            continue
            
        section = section.strip()
        if not section:
            continue
        
        # Se seção cabe no chunk atual
        if len(current_chunk) + len(section) + 10 <= max_chars:
            if current_chunk:
                current_chunk += " " + section
            else:
                current_chunk = section
        else:
            # Salva chunk atual se não vazio
            if current_chunk:
                chunks.append(current_chunk.strip())
                current_chunk = ""
            
            # Se seção é maior que limite, divide por parágrafos
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
                        
                        # Se parágrafo ainda é muito grande, divide por frases
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

# ========== ENGINES TTS ==========

async def synthesize_with_edge_tts(text: str, voice: str, output_path: Path, 
                                  bitrate: str = "32k", ar: int = 22050, ac: int = 1) -> None:
    """Sintetiza texto usando Edge-TTS e converte para MP3 comprimido."""
    if not edge_tts:
        raise RuntimeError("Edge-TTS não instalado. Execute: pip install edge-tts")
    
    chunks = chunk_text(text, max_chars=8000)
    
    if len(chunks) == 1:
        # Para chunk único, gera direto e converte
        temp_raw = output_path.with_suffix('.tmp.mp3')
        try:
            communicate = edge_tts.Communicate(text, voice)
            await communicate.save(str(temp_raw))
            
            # Converte para MP3 comprimido
            cmd = [
                "ffmpeg", "-y",
                "-i", str(temp_raw),
                "-ar", str(ar),
                "-ac", str(ac),
                "-b:a", bitrate,
                "-loglevel", "error",
                str(output_path)
            ]
            result = subprocess.run(cmd, capture_output=True, timeout=120)
            if result.returncode != 0:
                raise RuntimeError(f"Erro na conversão: {result.stderr.decode()}")
                
        finally:
            if temp_raw.exists():
                temp_raw.unlink()
    else:
        # Para múltiplos chunks
        temp_files = []
        try:
            # Gera chunks individuais
            for i, chunk in enumerate(chunks):
                temp_raw = output_path.parent / f".tmp-edge-raw-{i}.mp3"
                temp_compressed = output_path.parent / f".tmp-edge-{i}.mp3"
                
                # Gera áudio bruto
                communicate = edge_tts.Communicate(chunk, voice)
                await communicate.save(str(temp_raw))
                
                # Comprime chunk
                cmd = [
                    "ffmpeg", "-y",
                    "-i", str(temp_raw),
                    "-ar", str(ar),
                    "-ac", str(ac),
                    "-b:a", bitrate,
                    "-loglevel", "error",
                    str(temp_compressed)
                ]
                subprocess.run(cmd, capture_output=True, check=True)
                
                temp_files.append(temp_compressed)
                
                # Remove arquivo bruto
                if temp_raw.exists():
                    temp_raw.unlink()
            
            # Junta chunks comprimidos
            if len(temp_files) > 1:
                concat_list = output_path.parent / ".tmp-edge-concat.txt"
                with open(concat_list, 'w') as f:
                    for temp_file in temp_files:
                        f.write(f"file '{temp_file.name}'\n")
                
                cmd = ["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(concat_list), "-c", "copy", str(output_path)]
                subprocess.run(cmd, capture_output=True, check=True)
                
                if concat_list.exists():
                    concat_list.unlink()
            else:
                temp_files[0].rename(output_path)
                temp_files = []
                
        finally:
            # Limpa arquivos temporários
            for temp_file in temp_files:
                if temp_file.exists():
                    temp_file.unlink()
            # Limpa possíveis arquivos brutos restantes
            for temp_raw in output_path.parent.glob(".tmp-edge-raw-*.mp3"):
                try:
                    temp_raw.unlink()
                except:
                    pass

def synthesize_with_coqui(text: str, model_name: str, output_path: Path) -> None:
    """Sintetiza texto usando Coqui TTS local (100% privado)."""
    if not TTS:
        raise RuntimeError("Coqui TTS não instalado. Execute: pip install TTS")
    
    chunks = chunk_text(text, max_chars=1500)
    
    if len(chunks) == 1:
        try:
            tts = CoquiTTS(model_name=model_name)
            wav_tmp = output_path.with_suffix('.wav')
            tts.tts_to_file(text=text, file_path=str(wav_tmp))
            convert_wav_to_mp3(wav_tmp, output_path)
        finally:
            if wav_tmp.exists():
                wav_tmp.unlink()
    else:
        temp_files = []
        try:
            tts = CoquiTTS(model_name=model_name)
            
            for i, chunk in enumerate(chunks):
                temp_wav = output_path.parent / f".tmp-coqui-{i}.wav"
                temp_mp3 = output_path.parent / f".tmp-coqui-{i}.mp3"
                
                tts.tts_to_file(text=chunk, file_path=str(temp_wav))
                convert_wav_to_mp3(temp_wav, temp_mp3)
                temp_files.append(temp_mp3)
                
                if temp_wav.exists():
                    temp_wav.unlink()
            
            if len(temp_files) > 1:
                concat_list = output_path.parent / ".tmp-coqui-concat.txt"
                with open(concat_list, 'w') as f:
                    for temp_file in temp_files:
                        f.write(f"file '{temp_file.name}'\n")
                
                cmd = ["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(concat_list), "-c", "copy", str(output_path)]
                subprocess.run(cmd, capture_output=True, check=True)
                
                if concat_list.exists():
                    concat_list.unlink()
            else:
                temp_files[0].rename(output_path)
                temp_files = []
                
        finally:
            for temp_file in temp_files:
                if temp_file.exists():
                    temp_file.unlink()

def synthesize_with_piper(text: str, model_path: Path, output_path: Path) -> None:
    """Sintetiza texto usando Piper CLI (100% local)."""
    wav_tmp = output_path.with_suffix('.wav')
    
    cmd = [
        "piper",
        "--model", str(model_path),
        "--output_file", str(wav_tmp)
    ]
    
    try:
        result = subprocess.run(
            cmd, 
            input=text, 
            text=True, 
            capture_output=True, 
            timeout=300
        )
        
        if result.returncode != 0:
            raise RuntimeError(f"Piper falhou: {result.stderr}")
            
        convert_wav_to_mp3(wav_tmp, output_path)
        
    finally:
        if wav_tmp.exists():
            wav_tmp.unlink()

def convert_wav_to_mp3(wav_path: Path, mp3_path: Path, ar: int = 22050, ac: int = 1, bitrate: str = "32k") -> None:
    """Converte WAV para MP3 usando ffmpeg."""
    cmd = [
        "ffmpeg", "-y",
        "-i", str(wav_path),
        "-ar", str(ar),
        "-ac", str(ac),
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

def synthesize_chapter(text: str, engine: str, output_path: Path, **kwargs) -> None:
    """Sintetiza um capítulo usando o engine especificado."""
    
    if engine == "edge":
        # Passa parâmetros de compressão para Edge-TTS
        bitrate = kwargs.get('bitrate', '32k')
        ar = kwargs.get('ar', 22050)
        ac = kwargs.get('ac', 1)
        asyncio.run(synthesize_with_edge_tts(text, kwargs['voice'], output_path, bitrate, ar, ac))
    elif engine == "coqui":
        synthesize_with_coqui(text, kwargs['model_name'], output_path)
    elif engine == "piper":
        synthesize_with_piper(text, kwargs['model_path'], output_path)
    else:
        raise ValueError(f"Engine não suportado: {engine}")

# ========== SELEÇÃO DE VOZES/MODELOS ==========

def show_menu() -> str:
    """Mostra menu de seleção de engine TTS."""
    print("\n" + "="*60)
    print("🎙️  SELEÇÃO DE ENGINE TTS")
    print("="*60)
    
    engines = []
    
    # Verifica Edge-TTS
    if edge_tts:
        engines.append(("edge", "Edge-TTS (Microsoft)", "🌐 Online, rápido, gratuito"))
        print("1️⃣  Edge-TTS (Microsoft)")
        print("    🌐 Online (Microsoft processa o texto)")
        print("    ⚡ Muito rápido | 🎯 Boa qualidade | 💰 Gratuito")
    else:
        print("1️⃣  Edge-TTS (Microsoft) - ❌ Não instalado")
        print("    Execute: pip install edge-tts")
    
    print()
    
    # Verifica Coqui
    if TTS:
        engines.append(("coqui", "Coqui TTS", "🔒 100% local e privado"))
        print("2️⃣  Coqui TTS")
        print("    🔒 100% Local (seus dados não saem do computador)")
        print("    🐌 Mais lento | 🎯 Boa qualidade | 💰 Gratuito")
    else:
        print("2️⃣  Coqui TTS - ❌ Não instalado")
        print("    Execute: pip install TTS")
    
    print()
    
    # Piper - verifica modelos disponíveis
    models_dir = Path("./models")
    piper_models = []
    if models_dir.exists():
        piper_models = list(models_dir.glob("*.onnx"))
    
    if piper_models:
        engines.append(("piper", "Piper", "🔧 Local, rápido, vários modelos"))
        print("3️⃣  Piper")
        print("    🔧 100% Local | ⚡ Rápido | 🎯 Qualidade boa")
        print(f"    📁 {len(piper_models)} modelo(s) encontrado(s)")
    else:
        print("3️⃣  Piper - ❌ Nenhum modelo encontrado")
        print("    Baixe modelos .onnx em: ./models/")
        print("    https://github.com/rhasspy/piper/releases")
    
    print("\n" + "="*60)
    print("🔐 PRIVACIDADE:")
    print("   Edge-TTS: Microsoft processa seu texto online")
    print("   Coqui/Piper: 100% local, seus dados não saem do PC")
    print("="*60)
    
    if not engines:
        print("❌ ERRO: Nenhum engine TTS disponível!")
        print("\nInstale pelo menos um:")
        print("• pip install edge-tts  (mais rápido)")
        print("• pip install TTS       (mais privado)")
        sys.exit(1)
    
    while True:
        try:
            choice = input("\n🎯 Escolha o engine (1-3): ").strip()
            
            if choice == "1" and any(e[0] == "edge" for e in engines):
                return "edge"
            elif choice == "2" and any(e[0] == "coqui" for e in engines):
                return "coqui"
            elif choice == "3" and any(e[0] == "piper" for e in engines):
                return "piper"
            else:
                print("❌ Opção inválida ou engine não disponível!")
                
        except KeyboardInterrupt:
            print("\n\n👋 Cancelado pelo usuário")
            sys.exit(0)

def get_edge_voice() -> str:
    """Permite selecionar voz do Edge-TTS em português."""
    voices_pt = {
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
    
    print("\n" + "="*70)
    print("🎭 SELEÇÃO DE VOZ (Edge-TTS)")
    print("="*70)
    print("👩 VOZES FEMININAS:")
    for num in ["1", "2", "3", "4", "5", "6", "7", "8"]:
        voice_id, description = voices_pt[num]
        print(f"  {num:>2}️⃣  {description}")
    
    print("\n👨 VOZES MASCULINAS:")
    for num in ["9", "10", "11", "12", "13", "14", "15"]:
        voice_id, description = voices_pt[num]
        print(f"  {num:>2}️⃣  {description}")
    
    print("="*70)
    
    while True:
        try:
            choice = input("\n🎯 Escolha a voz (1-15, padrão=1): ").strip()
            if not choice:
                choice = "1"
            
            if choice in voices_pt:
                voice_id, description = voices_pt[choice]
                print(f"\n🎵 Voz selecionada: {description}")
                
                # Pergunta se quer ouvir preview
                preview = input("🎧 Quer ouvir um exemplo? (s/N): ").strip().lower()
                if preview in ['s', 'sim', 'y', 'yes']:
                    print("🎵 Gerando exemplo...")
                    asyncio.run(preview_edge_voice(voice_id))
                
                return voice_id
            else:
                print("❌ Opção inválida! Digite um número de 1 a 15")
                
        except KeyboardInterrupt:
            print("\n\n👋 Cancelado pelo usuário")
            sys.exit(0)

def get_coqui_model() -> str:
    """Permite selecionar modelo do Coqui TTS."""
    models = {
        "1": ("tts_models/pt/cv/vits", "Português CV-VITS", "Padrão, rápido, boa qualidade ⭐"),
        "2": ("tts_models/multilingual/multi-dataset/xtts_v2", "XTTS v2 Multilíngue", "Melhor qualidade, mais lento"),
        "3": ("tts_models/pt/cv/tacotron2", "Português Tacotron2", "Alternativo, voz mais robótica")
    }
    
    print("\n" + "="*70)
    print("🤖 SELEÇÃO DE MODELO (Coqui TTS)")
    print("="*70)
    
    for num, (model_id, name, description) in models.items():
        print(f"{num}️⃣  {name}")
        print(f"    📝 {description}")
        print()
    
    print("="*70)
    
    while True:
        try:
            choice = input("🎯 Escolha o modelo (1-3, padrão=1): ").strip()
            if not choice:
                choice = "1"
            
            if choice in models:
                model_id, name, description = models[choice]
                print(f"\n🤖 Modelo selecionado: {name}")
                print(f"📝 {description}")
                
                # Preview
                preview = input("\n🎧 Quer ouvir um exemplo? (s/N): ").strip().lower()
                if preview in ['s', 'sim', 'y', 'yes']:
                    print("🎵 Gerando exemplo (pode demorar na primeira vez)...")
                    preview_coqui_voice(model_id)
                
                return model_id
            else:
                print("❌ Opção inválida!")
                
        except KeyboardInterrupt:
            print("\n\n👋 Cancelado pelo usuário")
            sys.exit(0)

def get_piper_model() -> Path:
    """Permite selecionar modelo do Piper TTS."""
    models_dir = Path("./models")
    
    # Procura modelos .onnx na pasta
    onnx_files = []
    if models_dir.exists():
        onnx_files = list(models_dir.glob("*.onnx"))
    
    # Modelos conhecidos em português
    known_models = {
        "pt_BR-faber-medium.onnx": "Faber - Masculino, médio ⭐",
        "pt_BR-faber-low.onnx": "Faber - Masculino, rápido",
        "pt_BR-edresson-low.onnx": "Edresson - Masculino, alternativo",
        "pt-br_male-edresson-low.onnx": "Edresson - Masculino BR",
    }
    
    print("\n" + "="*70)
    print("🔧 SELEÇÃO DE MODELO (Piper TTS)")
    print("="*70)
    
    available_models = {}
    counter = 1
    
    # Lista modelos encontrados
    for onnx_file in onnx_files:
        model_name = onnx_file.name
        description = known_models.get(model_name, "Modelo personalizado")
        available_models[str(counter)] = (onnx_file, model_name, description)
        print(f"{counter}️⃣  {model_name}")
        print(f"    📝 {description}")
        print(f"    📁 {onnx_file}")
        print()
        counter += 1
    
    if not available_models:
        print("❌ Nenhum modelo .onnx encontrado em ./models/")
        print("\n💡 Download modelos em:")
        print("   https://github.com/rhasspy/piper/releases")
        print("   Exemplo: pt_BR-faber-medium.onnx")
        sys.exit(1)
    
    print("="*70)
    
    while True:
        try:
            choice = input(f"🎯 Escolha o modelo (1-{len(available_models)}, padrão=1): ").strip()
            if not choice:
                choice = "1"
            
            if choice in available_models:
                model_path, model_name, description = available_models[choice]
                print(f"\n🔧 Modelo selecionado: {model_name}")
                print(f"📝 {description}")
                
                return model_path
            else:
                print("❌ Opção inválida!")
                
        except KeyboardInterrupt:
            print("\n\n👋 Cancelado pelo usuário")
            sys.exit(0)

def validate_dependencies(engine: str, **kwargs) -> None:
    """Valida dependências do engine escolhido."""
    
    if engine == "edge":
        if not edge_tts:
            raise RuntimeError("Edge-TTS não instalado. Execute: pip install edge-tts")
        # Edge-TTS sempre precisa ffmpeg para conversão
        try:
            subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            raise RuntimeError("ffmpeg não encontrado no PATH (necessário para Edge-TTS)")
            
    elif engine == "piper":
        model_path = kwargs.get('model_path')
        if not model_path or not model_path.exists():
            raise FileNotFoundError(f"Modelo Piper não encontrado: {model_path}")
        try:
            subprocess.run(["piper", "--help"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            raise RuntimeError("Piper não encontrado no PATH")
        try:
            subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            raise RuntimeError("ffmpeg não encontrado no PATH")
            
    elif engine == "coqui":
        if not TTS:
            raise RuntimeError("Coqui TTS não instalado. Execute: pip install TTS")
        try:
            subprocess.run(["ffmpeg", "-version"], capture_output=True, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError):
            raise RuntimeError("ffmpeg não encontrado no PATH")

def main() -> None:
    ap = argparse.ArgumentParser(description="Converte EPUB em MP3s por capítulo usando TTS")
    ap.add_argument("input_path", type=Path, help="Caminho do arquivo .epub")
    ap.add_argument("--engine", choices=["edge", "coqui", "piper"], 
                    help="Engine TTS (se não especificado, mostra menu)")
    ap.add_argument("--voice", help="Voz específica (Edge-TTS)")
    ap.add_argument("--model-path", type=Path, default=Path("./models/pt_BR-faber-medium.onnx"),
                    help="Modelo Piper (.onnx)")
    ap.add_argument("--coqui-model", help="Modelo Coqui TTS")
    ap.add_argument("--no-cache", action="store_true", help="Força reprocessamento do EPUB (ignora cache)")
    ap.add_argument("--bitrate", default="32k", help="Bitrate MP3")
    ap.add_argument("--ar", type=int, default=22050, help="Sample rate")
    ap.add_argument("--ac", type=int, default=1, help="Canais de áudio")
    ap.add_argument("--skip-validation", action="store_true", help="Pula validação")
    
    args = ap.parse_args()

    if not args.epub_path.exists():
        ap.error(f"Arquivo não encontrado: {args.epub_path}")

    # Sistema de cache inteligente (padrão: sempre usar cache)
    book_title_preview = args.epub_path.stem
    existing_cache = check_existing_cache(book_title_preview)
    
    if existing_cache and not args.no_cache:
        print(f"📁 Usando cache existente: {existing_cache}")
        try:
            metadata, chapters = load_from_cache(existing_cache)
            book_title = metadata["title"]
            author = None  # Cache não tem autor separado
            print(f"✅ Cache carregado: {len(chapters)} capítulos")
        except Exception as e:
            print(f"⚠️  Erro no cache ({e}), reprocessando EPUB...")
            book_title, author, chapters = read_epub(args.epub_path)
            cache_dir = create_cache_structure(book_title, chapters)
    else:
        if args.no_cache and existing_cache:
            print(f"🔄 Flag --no-cache: ignorando cache e reprocessando EPUB")
        
        # Lê EPUB e cria/atualiza cache
        book_title, author, chapters = read_epub(args.epub_path)
        cache_dir = create_cache_structure(book_title, chapters)
        print(f"✅ EPUB processado e cache atualizado")

    # Seleção de engine via menu se não especificado
    if not args.engine:
        args.engine = show_menu()

    # Configuração específica por engine
    engine_kwargs = {}
    
    if args.engine == "edge":
        voice = args.voice or get_edge_voice()
        engine_kwargs = {
            "voice": voice,
            "bitrate": args.bitrate,
            "ar": args.ar,
            "ac": args.ac
        }
        
    elif args.engine == "coqui":
        model_name = args.coqui_model or get_coqui_model()
        engine_kwargs = {"model_name": model_name}
        
    elif args.engine == "piper":
        model_path = args.model_path
        # Se modelo padrão não existe, mostra seleção
        if not model_path.exists():
            model_path = get_piper_model()
        engine_kwargs = {"model_path": model_path}

    # Validação
    if not args.skip_validation:
        try:
            validate_dependencies(args.engine, **engine_kwargs)
        except (FileNotFoundError, RuntimeError) as e:
            print(f"\n❌ ERRO: {e}")
            sys.exit(1)

    print(f"\n📖 INFORMAÇÕES DO LIVRO")
    print("="*60)
    print(f"Engine: {args.engine.upper()}")
    if 'author' in locals():
        print(f"Autor: {author or 'Desconhecido'}")
    print(f"Título: {book_title}")
    print(f"Capítulos: {len(chapters)}")
    
    if args.engine == "edge":
        voice_name = engine_kwargs['voice'].split('-')[-1].replace('Neural', '')
        print(f"Voz: {voice_name}")
    elif args.engine == "coqui":
        model_short = engine_kwargs['model_name'].split('/')[-1]
        print(f"Modelo: {model_short}")
    elif args.engine == "piper":
        print(f"Modelo: {engine_kwargs['model_path'].name}")

    if not chapters:
        print("\n❌ ERRO: Nenhum capítulo encontrado")
        sys.exit(1)

    # Pasta de saída
    outdir = Path(sanitize_filename(book_title))
    outdir.mkdir(parents=True, exist_ok=True)
    print(f"Pasta: {outdir.resolve()}")
    
    # Info sobre cache
    if existing_cache:
        print(f"Cache: {existing_cache}")
    
    print("="*60)

    total = len(chapters)
    success_count = 0
    
    print(f"\n🎙️  CONVERTENDO {total} CAPÍTULOS")
    print("-" * 60)
    
    for idx, (title, text) in enumerate(chapters, start=1):
        chap_title_clean = sanitize_filename(title)
        index_str = zero_pad(idx, total)
        mp3_name = f"{index_str} - {chap_title_clean}.mp3"
        mp3_path = outdir / mp3_name
        
        # Verifica se já existe
        if mp3_path.exists():
            print(f"⏭️  [{index_str}/{total}] '{title}' - arquivo já existe")
            success_count += 1
            continue
            
        print(f"🎙️  [{index_str}/{total}] '{title[:50]}{'...' if len(title) > 50 else ''}")
        print(f"    📝 {len(text)} caracteres", end="")
        
        if len(text) > 1500:
            chunk_count = len(chunk_text(text, 1500))
            print(f" | {chunk_count} partes")
        else:
            print()
        
        try:
            synthesize_chapter(text, args.engine, mp3_path, **engine_kwargs)
            file_size = mp3_path.stat().st_size / 1024 / 1024  # MB
            duration_est = len(text) / 1000 * 0.6  # Estimativa: ~0.6 min por 1000 chars
            print(f"    ✅ Criado: {mp3_path.name} ({file_size:.1f}MB, ~{duration_est:.1f}min)")
            success_count += 1
        except Exception as e:
            print(f"    ❌ ERRO: {e}")
        
        print()

    print("=" * 60)
    print(f"🎉 CONVERSÃO FINALIZADA")
    print("=" * 60)
    print(f"✅ Sucessos: {success_count}/{total} capítulos")
    print(f"📁 Pasta: {outdir.resolve()}")
    
    if success_count < total:
        print(f"⚠️  {total - success_count} capítulos falharam")
        print("💡 Dica: Execute novamente para tentar os que falharam")
    
    # Info sobre cache
    cache_dir = Path(".cache") / sanitize_filename(book_title)
    if cache_dir.exists():
        print(f"📁 Cache mantido: {cache_dir}")
        print("💡 Para reprocessar EPUB: use --no-cache")
    
    print("=" * 60)
    
    # Limpeza de arquivos temporários de preview
    for preview_file in Path(".").glob(".preview-*.mp3"):
        try:
            preview_file.unlink()
        except:
            pass
    for preview_file in Path(".").glob(".preview-*.wav"):
        try:
            preview_file.unlink()
        except:
            pass

if __name__ == "__main__":
    main()