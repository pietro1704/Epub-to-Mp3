# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an EBook to Audiobook converter that transforms EPUB/PDF files into MP3 audiobooks using multiple TTS (Text-to-Speech) engines. The project supports Portuguese Brazilian voices and includes intelligent caching, progress tracking, and chapter structure preservation.

## Common Development Commands

### Installation and Setup
```bash
# Install core dependencies
pip install -r requirements.txt

# Install specific TTS engines
pip install edge-tts          # Edge-TTS (Microsoft, online)
pip install TTS torch torchaudio  # Coqui TTS (local, AI-powered)

# Install system dependencies
# Ubuntu/Debian: sudo apt install ffmpeg
# macOS: brew install ffmpeg
```

### Running the Application
```bash
# Basic usage with interactive menu
python main.py book.epub

# Direct engine selection
python main.py book.epub --engine edge --voice pt-BR-FranciscaNeural
python main.py book.epub --engine coqui --coqui-model tts_models/multilingual/multi-dataset/xtts_v2
python main.py book.epub --engine piper --model-path ./models/pt_BR-faber-medium.onnx

# Show chapter structure without converting
python main.py book.epub --show-structure

# Force reprocessing (ignore cache)
python main.py book.epub --no-cache
```

### Testing and Debugging
```bash
# Test specific TTS engine dependencies
python -c "import edge_tts; print('Edge-TTS OK')"
python -c "import TTS; print('Coqui TTS OK')"

# Debug mode with verbose output
python -u main.py book.epub 2>&1 | tee debug.log

# Skip dependency validation if needed
python main.py book.epub --skip-validation
```

### Dependency Resolution
```bash
# Fix known dependency conflicts
python resolve_dependencies.py

# Manual dependency fixes (if needed)
pip uninstall transformers numpy pandas fsspec packaging -y
pip install transformers==4.40.2 --force-reinstall
```

## Architecture and Code Structure

### Core Components

**Main Entry Point**
- `main.py` - CLI interface, argument parsing, and conversion orchestration
- Supports both interactive menu and command-line parameters
- Handles file validation and basic error handling

**Configuration System**
- `src/config.py` - Centralized configuration with dataclass-based settings
- Contains voice definitions for all TTS engines (Edge, Coqui, Piper)
- Chapter detection patterns for PDF processing
- Audio format configurations

**TTS Engine Factory Pattern**
- `src/tts_factory.py` - Factory for creating TTS engine instances
- `src/tts/base.py` - Base interface for all TTS engines
- `src/tts/edge_engine.py` - Microsoft Edge-TTS implementation (online)
- `src/tts/coqui_engine.py` - Coqui TTS implementation (local AI)
- `src/tts/piper_engine.py` - Piper TTS implementation (local CLI)

**File Processing Pipeline**
- `src/ebook_reader.py` - EPUB/PDF parsing with chapter structure extraction
- `src/converter.py` - Main conversion logic with progress tracking
- `src/cache_manager.py` - Intelligent caching system for processed text
- `src/progress_tracker.py` - Real-time progress display with ETA calculations

**Utilities**
- `src/utils.py` - File sanitization, audio validation, duration estimation
- `src/ui/menu.py` - Interactive menu system for engine/voice selection

### Key Design Patterns

1. **Factory Pattern**: TTS engines are created through `TTSFactory` for loose coupling
2. **Dataclass Configuration**: All settings centralized in `Config` dataclass
3. **Intelligent Caching**: Parsed ebooks cached to avoid reprocessing when switching engines
4. **Chapter Structure Preservation**: Maintains original EPUB navigation hierarchy
5. **Progress Tracking**: Real-time progress with character count and time estimates

### File Processing Flow

1. **File Validation** → Check file exists and is EPUB/PDF
2. **Cache Check** → Look for existing processed text cache
3. **Text Extraction** → Parse EPUB/PDF and extract chapter structure  
4. **Cache Creation** → Save processed text for future use
5. **TTS Engine Setup** → Initialize selected TTS engine
6. **Chapter Conversion** → Convert each chapter with progress tracking
7. **File Output** → Generate structured MP3 files with proper naming

### Cache System

- **Location**: `.cache/Book_Title/`
- **Structure**: `metadata.json` + individual chapter text files
- **Benefits**: Switch between TTS engines without re-parsing ebooks
- **Invalidation**: Use `--no-cache` flag to force reprocessing

### Chapter Structure Support

The system preserves EPUB navigation structure:
- Extracts chapter hierarchy (levels 1-N)
- Maintains original titles and IDs
- Generates structured filenames (e.g., "001 - Chapter.mp3", "001.1 - Subsection.mp3")
- Provides chapter analysis with character counts and duration estimates

### TTS Engine Configurations

**Edge-TTS**: 15+ Portuguese voices, fastest conversion, requires internet
**Coqui TTS**: AI-powered local synthesis, supports voice cloning with `reference_voice.wav`
**Piper**: Lightweight local engine using ONNX models in `./models/` directory

### Error Handling and Validation

- Dependency validation for each TTS engine
- Audio file validation post-conversion
- Graceful fallbacks for missing dependencies
- Comprehensive error messages with solution suggestions

### Development Notes

- All text processing assumes UTF-8 encoding
- Audio output defaults to 22050Hz, 32k bitrate, mono
- Chapter text chunks limited to 8000 chars (Edge) or 1500 chars (others) for optimal TTS processing
- Temporary files automatically cleaned up after conversion
- FFmpeg required for audio format conversion across all engines

This architecture supports easy extension for additional TTS engines by implementing the base TTS interface and registering with the factory.

## Prompts

### system_prompt
```xml
<system_prompt>
<role>Senior Engineer especializado em arquitetura SOLID</role>
<context>
Projeto: EbookToAudio - Conversor EPUB/PDF para MP3 usando TTS engines (Edge-TTS, Coqui, Piper)
Arquitetura: Factory Pattern, Dependency Injection, Progress Tracking, Cache System
Stack: Python 3.8+, asyncio, subprocess, pathlib, dataclasses

Estrutura atual:
- src/tts/: Engines TTS (edge_engine.py, coqui_engine.py, piper_engine.py)
- src/: Core modules (converter.py, cache_manager.py, progress_tracker.py)
- main.py: Entry point com argparse
- config.py: Centralized configuration
</context>

<response_guidelines>
SEMPRE pergunte para esclarecimento antes de responder

Formato de resposta OBRIGATÓRIO:
1. **Pergunta de esclarecimento** (1 linha)
e depois de eu responder pergunta:

1. **Arquivo**: `caminho/arquivo.py`
2. **Linha X**: `código atual`
3. **Alteração**: 
```python
# Código novo com **alterações em negrito nos comentários**

<system>
You are an expert Python developer specializing in text-to-speech (TTS) applications and audiobook conversion. 

When working on this codebase:
- Follow the existing factory pattern for TTS engines
- Maintain the dataclass-based configuration system
- Preserve chapter structure and navigation hierarchy
- Implement proper error handling with graceful fallbacks
- Use intelligent caching to avoid reprocessing
- Follow the established naming conventions for generated audio files
- Always validate dependencies before using TTS engines
- Consider character limits for optimal TTS processing (8000 for Edge, 1500 for others)

Focus on code quality, maintainability, and user experience.
</system>
```

### code_review_prompt
```xml
<instructions>
When reviewing code changes:
1. Verify TTS engine implementations follow the base interface
2. Check that new configurations are added to the Config dataclass
3. Ensure proper error handling and dependency validation
4. Validate that chapter structure preservation is maintained
5. Confirm audio output follows established quality standards
6. Review that caching logic is properly implemented
7. Check for proper file sanitization and path handling
</instructions>
```