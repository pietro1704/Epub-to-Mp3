#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Hugging Face Space: EPUB to MP3 Audiobook Converter
Converts EPUB/PDF files to MP3 audiobooks using Edge-TTS (Portuguese Brazilian voices)
"""

import asyncio
import gradio as gr
import shutil
import tempfile
from pathlib import Path
from typing import List, Optional, Tuple

# Import converter modules
import sys
sys.path.insert(0, str(Path(__file__).parent / "python_app"))

from python_app.src.converter import AudioConverter
from python_app.src.config import ConversionConfig
from python_app.src.ebook_reader import EbookReader

# Edge-TTS Portuguese voices
VOICES = {
    "Francisca (Mulher) 🇧🇷": "pt-BR-FranciscaNeural",
    "Antonio (Homem) 🇧🇷": "pt-BR-AntonioNeural",
    "Brenda (Mulher) 🇧🇷": "pt-BR-BrendaNeural",
    "Donato (Homem) 🇧🇷": "pt-BR-DonatoNeural",
    "Elza (Mulher) 🇧🇷": "pt-BR-ElzaNeural",
    "Fabio (Homem) 🇧🇷": "pt-BR-FabioNeural",
    "Giovanna (Mulher) 🇧🇷": "pt-BR-GiovannaNeural",
    "Humberto (Homem) 🇧🇷": "pt-BR-HumbertoNeural",
    "Julio (Homem) 🇧🇷": "pt-BR-JulioNeural",
    "Leila (Mulher) 🇧🇷": "pt-BR-LeilaNeural",
    "Leticia (Mulher) 🇧🇷": "pt-BR-LeticiaNeural",
    "Manuela (Mulher) 🇧🇷": "pt-BR-ManuelaNeural",
    "Nicolau (Homem) 🇧🇷": "pt-BR-NicolauNeural",
    "Thalita (Mulher) 🇧🇷": "pt-BR-ThalitaNeural",
    "Yara (Mulher) 🇧🇷": "pt-BR-YaraNeural",
}


async def convert_ebook_to_audio(
    ebook_file: str,
    voice_name: str,
    progress=gr.Progress()
) -> Tuple[List[str], str]:
    """
    Convert EPUB/PDF to MP3 audiobook

    Args:
        ebook_file: Path to uploaded EPUB/PDF file
        voice_name: Selected voice name (display name)
        progress: Gradio progress tracker

    Returns:
        Tuple of (list of MP3 file paths, status message)
    """
    if not ebook_file:
        return [], "❌ Por favor, envie um arquivo EPUB ou PDF"

    # Get Edge-TTS voice ID
    voice_id = VOICES.get(voice_name)
    if not voice_id:
        return [], f"❌ Voz inválida: {voice_name}"

    # Create temp directory for outputs
    temp_dir = Path(tempfile.mkdtemp(prefix="epub2audio_"))
    output_dir = temp_dir / "output"
    output_dir.mkdir(exist_ok=True)

    try:
        progress(0.1, desc="📖 Lendo arquivo...")

        # Parse ebook (async to avoid blocking)
        ebook_path = Path(ebook_file)
        reader = EbookReader()
        await asyncio.to_thread(reader.load, ebook_path)

        if not reader.book or not reader.book.chapters:
            return [], "❌ Nenhum capítulo encontrado no arquivo"

        progress(0.2, desc=f"📚 {len(reader.book.chapters)} capítulos encontrados")

        # Setup converter
        config = ConversionConfig(
            engine="edge",
            voice=voice_id,
            output_dir=str(output_dir),
            bitrate="8k",
            sample_rate=16_000,
            channels=1,
        )

        converter = AudioConverter()
        converter.verbose = False

        progress(0.3, desc="🎙️ Iniciando conversão...")

        # Convert chapters
        result = await converter.convert(reader, config)

        if not result.success:
            error_msg = "\n".join(result.errors) if result.errors else "Erro desconhecido"
            return [], f"❌ Falha na conversão:\n{error_msg}"

        progress(0.9, desc="✅ Preparando arquivos...")

        # Collect MP3 files
        mp3_files = sorted(output_dir.glob("*.mp3"))

        if not mp3_files:
            return [], "❌ Nenhum arquivo MP3 gerado"

        progress(1.0, desc="✅ Concluído!")

        # Return paths as strings for Gradio
        mp3_paths = [str(f) for f in mp3_files]

        status = (
            f"✅ **Conversão completa!**\n\n"
            f"📊 **Estatísticas:**\n"
            f"- Capítulos totais: {result.total_chapters}\n"
            f"- Capítulos convertidos: {result.converted_chapters}\n"
            f"- Arquivos MP3: {len(mp3_files)}\n"
            f"- Voz: {voice_name}\n"
        )

        return mp3_paths, status

    except Exception as e:
        import traceback
        error_detail = traceback.format_exc()
        return [], f"❌ Erro durante conversão:\n```\n{error_detail}\n```"


def convert_wrapper(ebook_file, voice_name, progress=gr.Progress()):
    """Synchronous wrapper for async convert function"""
    return asyncio.run(convert_ebook_to_audio(ebook_file, voice_name, progress))


# Gradio Interface
with gr.Blocks(title="EPUB to MP3 Converter", theme=gr.themes.Soft()) as demo:
    gr.Markdown(
        """
        # 📚 EPUB to MP3 Audiobook Converter

        Converta seus livros EPUB/PDF em audiobooks MP3 com vozes naturais em Português Brasileiro.

        **✨ Características:**
        - 🎙️ 15 vozes portuguesas naturais (Microsoft Edge-TTS)
        - 📖 Suporte para EPUB e PDF
        - 🎵 MP3 otimizado (8kbps, ideal para audiobooks)
        - 🚀 Processamento rápido

        **⚠️ Limitações:**
        - Arquivos grandes podem levar alguns minutos
        - Limite de ~100MB por arquivo
        - Apenas livros em português
        """
    )

    with gr.Row():
        with gr.Column():
            ebook_input = gr.File(
                label="📁 Envie seu arquivo EPUB ou PDF",
                file_types=[".epub", ".pdf"],
                type="filepath"
            )

            voice_dropdown = gr.Dropdown(
                choices=list(VOICES.keys()),
                value="Francisca (Mulher) 🇧🇷",
                label="🎙️ Escolha a voz",
                info="Selecione a voz que narrará o audiobook"
            )

            convert_btn = gr.Button("🎵 Converter para Audiobook", variant="primary", size="lg")

        with gr.Column():
            status_output = gr.Markdown(label="Status")
            audio_output = gr.File(
                label="📥 Arquivos MP3 gerados",
                file_count="multiple"
            )

    # Examples
    gr.Markdown("### 📝 Dicas:")
    gr.Markdown(
        """
        - **EPUB funciona melhor que PDF** (preserva estrutura de capítulos)
        - **Teste com um arquivo pequeno primeiro** (< 5MB)
        - **Cada capítulo vira um arquivo MP3 separado**
        - **Download todos os arquivos** com o botão de download múltiplo
        """
    )

    # Event handler
    convert_btn.click(
        fn=convert_wrapper,
        inputs=[ebook_input, voice_dropdown],
        outputs=[audio_output, status_output],
    )

# Launch
if __name__ == "__main__":
    demo.queue(max_size=3)  # Limit concurrent conversions
    demo.launch()
