---
title: EPUB to MP3 Audiobook Converter
emoji: 📚
colorFrom: blue
colorTo: purple
sdk: gradio
sdk_version: 4.0.0
app_file: app.py
pinned: false
license: mit
tags:
  - audiobook
  - text-to-speech
  - epub
  - portuguese
  - tts
  - edge-tts
---

# 📚 EPUB to MP3 Audiobook Converter

Converta seus livros EPUB/PDF em audiobooks MP3 com **vozes naturais em Português Brasileiro**.

## ✨ Características

- 🎙️ **15 vozes portuguesas naturais** (Microsoft Edge-TTS)
- 📖 **Suporte para EPUB e PDF**
- 🎵 **MP3 otimizado** (8kbps, ideal para audiobooks)
- 🚀 **Processamento rápido** (sem necessidade de GPU)
- 💾 **Leve** (~50MB de dependências, sem PyTorch)

## 🎤 Vozes Disponíveis

### Vozes Femininas
- **Francisca** 🇧🇷 (recomendada)
- Brenda
- Elza
- Giovanna
- Leila
- Leticia
- Manuela
- Thalita
- Yara

### Vozes Masculinas
- **Antonio** 🇧🇷 (recomendado)
- Donato
- Fabio
- Humberto
- Julio
- Nicolau

## 🚀 Como Usar

1. **Envie seu arquivo** EPUB ou PDF
2. **Escolha a voz** (teste com Francisca ou Antonio)
3. **Clique em "Converter"**
4. **Baixe os MP3s** gerados

## 📊 Qualidade de Áudio

- **Bitrate**: 8 kbps (otimizado para voz)
- **Sample Rate**: 16 kHz
- **Canais**: Mono
- **Tamanho estimado**: ~3.6 MB por hora de áudio

## ⚠️ Limitações

- Arquivos grandes podem levar alguns minutos
- Limite recomendado: ~100MB por arquivo
- Apenas livros em português
- Cada capítulo vira um arquivo MP3 separado

## 📝 Dicas

- **EPUB funciona melhor que PDF** (preserva estrutura de capítulos)
- **Teste com um arquivo pequeno primeiro** (< 5MB)
- **Baixe todos os arquivos** com o botão de download múltiplo
- **Combine os MP3s** depois, se preferir um único arquivo

## 🛠️ Tecnologias

- [Edge-TTS](https://github.com/rany2/edge-tts) - Microsoft Text-to-Speech
- [Gradio](https://gradio.app) - Interface web
- [ebooklib](https://github.com/aerkalov/ebooklib) - Parser EPUB
- [pypdf](https://github.com/py-pdf/pypdf) - Parser PDF

## 📜 Licença

MIT License

## 🔗 Links

- [Código fonte](https://github.com/pietropugliesi/Epub-to-Mp3)
- [Reportar problema](https://github.com/pietropugliesi/Epub-to-Mp3/issues)

---

**Desenvolvido com ❤️ usando Edge-TTS e Gradio**
