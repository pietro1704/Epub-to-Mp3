#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Bot de Telegram para conversão de EPUB/PDF para Audiobook MP3.
Interface intuitiva para usuários não-técnicos com todas as funcionalidades do CLI.
"""

import asyncio
import logging
import os
import sys
from pathlib import Path
from typing import Optional, Dict, Any

from telegram import (
    Update,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    ReplyKeyboardMarkup,
    ReplyKeyboardRemove,
)
from telegram.ext import (
    Application,
    CommandHandler,
    MessageHandler,
    CallbackQueryHandler,
    ConversationHandler,
    ContextTypes,
    filters,
)

# Importar módulos do conversor
sys.path.insert(0, str(Path(__file__).parent))
from src.config import ConversionConfig, VoiceConfigProvider
from src.ebook_reader import EbookReader
from src.converter import AudioConverter

# Configurar logging
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

# Estados da conversa
(
    WAITING_FILE,
    SELECT_ENGINE,
    SELECT_VOICE,
    SELECT_OPTIONS,
    SELECT_CHAPTERS,
    CONVERTING,
) = range(6)

# User data keys
USER_FILE = 'file_path'
USER_ENGINE = 'engine'
USER_VOICE = 'voice'
USER_MODEL = 'model'
USER_OPTIONS = 'options'
USER_CHAPTERS = 'chapters'


class TelegramBot:
    """Bot de Telegram para conversão de ebooks."""

    def __init__(self, token: str):
        self.token = token
        self.voice_provider = VoiceConfigProvider()
        self.temp_dir = Path("temp_telegram")
        self.temp_dir.mkdir(exist_ok=True)
        self.converter = AudioConverter()

    async def start_command(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
        """Handler para /start - boas-vindas e instruções."""
        welcome_text = (
            "📚 *Bem-vindo ao Conversor de Ebooks!*\n\n"
            "Transforme seus livros EPUB/PDF em audiobooks MP3!\n\n"
            "*Como usar:*\n"
            "1️⃣ Envie seu arquivo EPUB ou PDF\n"
            "2️⃣ Escolha o motor de voz (Edge/Coqui/Piper)\n"
            "3️⃣ Selecione a voz que preferir\n"
            "4️⃣ Configure as opções (capítulos, notas de rodapé, etc.)\n"
            "5️⃣ Receba seus capítulos em MP3!\n\n"
            "*Comandos disponíveis:*\n"
            "/start - Iniciar\n"
            "/cancel - Cancelar operação atual\n"
            "/help - Ajuda detalhada\n\n"
            "📎 *Envie seu arquivo para começar!*"
        )
        await update.message.reply_text(
            welcome_text,
            parse_mode='Markdown'
        )
        return WAITING_FILE

    async def help_command(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
        """Handler para /help - ajuda detalhada."""
        help_text = (
            "📖 *Ajuda Detalhada*\n\n"
            "*Motores de Voz:*\n"
            "• *Edge-TTS*: Online, rápido, 15+ vozes PT-BR\n"
            "• *Coqui TTS*: Local, IA avançada, clonagem de voz\n"
            "• *Piper*: Local, leve, rápido\n\n"
            "*Opções de Notas de Rodapé:*\n"
            "• *Inline*: Lê durante o texto\n"
            "• *Fim do capítulo*: Lê todas no final\n"
            "• *Ignorar*: Não lê notas\n\n"
            "*Seleção de Capítulos:*\n"
            "• Todos os capítulos\n"
            "• Capítulos específicos (ex: 1, 3, 5)\n"
            "• Intervalo (ex: 1-5)\n\n"
            "*Formatos Suportados:*\n"
            "• EPUB (.epub)\n"
            "• PDF (.pdf)\n\n"
            "Envie /start para começar!"
        )
        await update.message.reply_text(help_text, parse_mode='Markdown')

    async def cancel_command(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
        """Handler para /cancel - cancelar operação."""
        # Limpar dados do usuário
        if USER_FILE in context.user_data:
            file_path = Path(context.user_data[USER_FILE])
            if file_path.exists():
                file_path.unlink()

        context.user_data.clear()

        await update.message.reply_text(
            "❌ Operação cancelada. Envie /start para começar novamente.",
            reply_markup=ReplyKeyboardRemove()
        )
        return ConversationHandler.END

    async def handle_file(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
        """Handler para receber arquivo EPUB/PDF."""
        document = update.message.document

        if not document:
            await update.message.reply_text("❌ Por favor, envie um arquivo.")
            return WAITING_FILE

        # Verificar extensão
        file_name = document.file_name.lower()
        if not (file_name.endswith('.epub') or file_name.endswith('.pdf')):
            await update.message.reply_text(
                "❌ Formato não suportado. Envie arquivos .epub ou .pdf"
            )
            return WAITING_FILE

        # Download do arquivo
        await update.message.reply_text("📥 Baixando arquivo...")

        try:
            file = await context.bot.get_file(document.file_id)
            user_id = update.effective_user.id
            file_path = self.temp_dir / f"{user_id}_{document.file_name}"
            await file.download_to_drive(file_path)

            context.user_data[USER_FILE] = str(file_path)
            context.user_data[USER_OPTIONS] = {
                'footnote_mode': 'inline',
                'chapters': 'all',
                'parallel': 1
            }

            await update.message.reply_text(
                f"✅ Arquivo recebido: *{document.file_name}*\n\n"
                "Escolha o motor de voz:",
                parse_mode='Markdown'
            )

            return await self.show_engine_selection(update, context)

        except Exception as e:
            logger.error(f"Erro ao baixar arquivo: {e}")
            await update.message.reply_text(
                f"❌ Erro ao processar arquivo: {str(e)}\n"
                "Tente novamente."
            )
            return WAITING_FILE

    async def show_engine_selection(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
        """Mostrar seleção de engine TTS."""
        keyboard = [
            [InlineKeyboardButton("🌐 Edge-TTS (Online, Rápido)", callback_data="engine_edge")],
            [InlineKeyboardButton("🤖 Coqui TTS (Local, IA)", callback_data="engine_coqui")],
            [InlineKeyboardButton("⚡ Piper (Local, Leve)", callback_data="engine_piper")],
        ]
        reply_markup = InlineKeyboardMarkup(keyboard)

        if update.callback_query:
            await update.callback_query.edit_message_text(
                "🎙️ *Escolha o Motor de Voz:*\n\n"
                "• *Edge-TTS*: Rápido, requer internet\n"
                "• *Coqui*: Alta qualidade, local\n"
                "• *Piper*: Rápido e leve",
                reply_markup=reply_markup,
                parse_mode='Markdown'
            )
        else:
            await update.message.reply_text(
                "🎙️ *Escolha o Motor de Voz:*",
                reply_markup=reply_markup,
                parse_mode='Markdown'
            )

        return SELECT_ENGINE

    async def handle_engine_selection(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
        """Handler para seleção de engine."""
        query = update.callback_query
        await query.answer()

        engine = query.data.replace("engine_", "")
        context.user_data[USER_ENGINE] = engine

        return await self.show_voice_selection(update, context)

    async def show_voice_selection(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
        """Mostrar seleção de voz baseada no engine."""
        engine = context.user_data.get(USER_ENGINE, 'edge')

        keyboard = []

        if engine == 'edge':
            voices = self.voice_provider.edge_voices
            keyboard.append([InlineKeyboardButton(
                "🎤 Thalita (Recomendada)",
                callback_data="voice_pt-BR-ThalitaMultilingualNeural"
            )])
            keyboard.append([InlineKeyboardButton(
                "👨 Antonio",
                callback_data="voice_pt-BR-AntonioNeural"
            )])
            keyboard.append([InlineKeyboardButton(
                "🌍 Guy (English)",
                callback_data="voice_en-US-GuyNeural"
            )])

        elif engine == 'coqui':
            keyboard.append([InlineKeyboardButton(
                "🌟 XTTS v2 (Melhor qualidade)",
                callback_data="model_tts_models/multilingual/multi-dataset/xtts_v2"
            )])
            keyboard.append([InlineKeyboardButton(
                "⚡ VITS PT-BR (Rápido)",
                callback_data="model_tts_models/pt/cv/vits"
            )])

        elif engine == 'piper':
            models = self.voice_provider.get_piper_models()
            if models:
                for name, info in list(models.items())[:3]:
                    keyboard.append([InlineKeyboardButton(
                        f"🎵 {name}",
                        callback_data=f"piper_{info['path']}"
                    )])
            else:
                await update.callback_query.edit_message_text(
                    "❌ Nenhum modelo Piper encontrado.\n"
                    "Configure modelos em python_app/models/\n\n"
                    "Escolha outro engine:"
                )
                return await self.show_engine_selection(update, context)

        keyboard.append([InlineKeyboardButton("⬅️ Voltar", callback_data="back_to_engine")])

        reply_markup = InlineKeyboardMarkup(keyboard)

        await update.callback_query.edit_message_text(
            f"🗣️ *Escolha a Voz ({engine.upper()}):*",
            reply_markup=reply_markup,
            parse_mode='Markdown'
        )

        return SELECT_VOICE

    async def handle_voice_selection(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
        """Handler para seleção de voz."""
        query = update.callback_query
        await query.answer()

        if query.data == "back_to_engine":
            return await self.show_engine_selection(update, context)

        engine = context.user_data.get(USER_ENGINE)

        if query.data.startswith("voice_"):
            context.user_data[USER_VOICE] = query.data.replace("voice_", "")
        elif query.data.startswith("model_"):
            context.user_data[USER_MODEL] = query.data.replace("model_", "")
        elif query.data.startswith("piper_"):
            context.user_data[USER_MODEL] = query.data.replace("piper_", "")

        return await self.show_options_menu(update, context)

    async def show_options_menu(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
        """Mostrar menu de opções."""
        options = context.user_data.get(USER_OPTIONS, {})

        footnote_text = {
            'inline': 'Durante o texto',
            'chapter_end': 'Fim do capítulo',
            'skip': 'Ignorar'
        }.get(options.get('footnote_mode', 'inline'))

        chapters_text = options.get('chapters', 'all')
        if chapters_text == 'all':
            chapters_text = 'Todos'

        keyboard = [
            [InlineKeyboardButton(
                f"📝 Notas: {footnote_text}",
                callback_data="opt_footnotes"
            )],
            [InlineKeyboardButton(
                f"📖 Capítulos: {chapters_text}",
                callback_data="opt_chapters"
            )],
            [InlineKeyboardButton(
                "🔄 Limpar cache",
                callback_data="opt_clear_cache"
            )],
            [InlineKeyboardButton(
                "✅ Iniciar Conversão",
                callback_data="start_conversion"
            )],
            [InlineKeyboardButton("⬅️ Voltar", callback_data="back_to_voice")],
        ]

        reply_markup = InlineKeyboardMarkup(keyboard)

        engine = context.user_data.get(USER_ENGINE, 'edge')
        voice = context.user_data.get(USER_VOICE) or context.user_data.get(USER_MODEL, 'padrão')

        message_text = (
            f"⚙️ *Configurações:*\n\n"
            f"Motor: *{engine.upper()}*\n"
            f"Voz: *{voice.split('/')[-1]}*\n"
            f"Notas: *{footnote_text}*\n"
            f"Capítulos: *{chapters_text}*\n\n"
            "Configure ou inicie a conversão:"
        )

        # Check if this is from a callback query or regular message
        if update.callback_query:
            await update.callback_query.edit_message_text(
                message_text,
                reply_markup=reply_markup,
                parse_mode='Markdown'
            )
        else:
            await update.message.reply_text(
                message_text,
                reply_markup=reply_markup,
                parse_mode='Markdown'
            )

        return SELECT_OPTIONS

    async def handle_options(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
        """Handler para opções."""
        query = update.callback_query
        await query.answer()

        if query.data == "back_to_voice":
            return await self.show_voice_selection(update, context)

        if query.data == "start_conversion":
            return await self.start_conversion(update, context)

        if query.data == "opt_footnotes":
            keyboard = [
                [InlineKeyboardButton("📖 Durante o texto", callback_data="footnote_inline")],
                [InlineKeyboardButton("📚 Fim do capítulo", callback_data="footnote_chapter_end")],
                [InlineKeyboardButton("🚫 Ignorar", callback_data="footnote_skip")],
                [InlineKeyboardButton("⬅️ Voltar", callback_data="back_to_options")],
            ]
            reply_markup = InlineKeyboardMarkup(keyboard)
            await query.edit_message_text(
                "📝 *Como tratar notas de rodapé?*",
                reply_markup=reply_markup,
                parse_mode='Markdown'
            )
            return SELECT_OPTIONS

        if query.data.startswith("footnote_"):
            mode = query.data.replace("footnote_", "")
            context.user_data[USER_OPTIONS]['footnote_mode'] = mode
            return await self.show_options_menu(update, context)

        if query.data == "back_to_options":
            return await self.show_options_menu(update, context)

        if query.data == "opt_clear_cache":
            context.user_data[USER_OPTIONS]['clear_cache'] = True
            await query.answer("✅ Cache será limpo antes da conversão")
            return await self.show_options_menu(update, context)

        if query.data == "opt_chapters":
            await query.edit_message_text(
                "📖 *Seleção de Capítulos*\n\n"
                "Envie:\n"
                "• `all` - Todos os capítulos\n"
                "• `1,3,5` - Capítulos específicos\n"
                "• `1-5` - Intervalo\n"
                "• /skip - Pular (converter todos)",
                parse_mode='Markdown'
            )
            return SELECT_CHAPTERS

        return SELECT_OPTIONS

    async def handle_chapter_selection(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
        """Handler para seleção de capítulos."""
        text = update.message.text.strip().lower()

        context.user_data[USER_OPTIONS]['chapters'] = text

        await update.message.reply_text("✅ Capítulos configurados!")
        return await self.show_options_menu(update, context)

    async def start_conversion(self, update: Update, context: ContextTypes.DEFAULT_TYPE) -> int:
        """Iniciar processo de conversão."""
        query = update.callback_query
        await query.answer()

        await query.edit_message_text(
            "🔄 *Iniciando conversão...*\n"
            "Isso pode levar alguns minutos.",
            parse_mode='Markdown'
        )

        # Obter configurações
        file_path = Path(context.user_data[USER_FILE])
        engine = context.user_data[USER_ENGINE]
        voice = context.user_data.get(USER_VOICE)
        model = context.user_data.get(USER_MODEL)
        options = context.user_data.get(USER_OPTIONS, {})

        try:
            # Criar configuração com compressão otimizada para Telegram (limite 50MB)
            config = ConversionConfig(
                engine=engine,
                voice=voice,
                model_path=Path(model) if model else None,
                output_dir="output_telegram",
                footnote_mode=options.get('footnote_mode', 'inline'),
                clear_cache=options.get('clear_cache', False),
                # Compressão máxima para reduzir tamanho (limite Telegram 50MB)
                bitrate="8k",      # 8 kbps - boa qualidade para voz, ~3.6 MB/hora
                sample_rate=16_000,  # 16 kHz - suficiente para voz
                channels=1,         # Mono - audiobooks não precisam de stereo
            )

            # Ler ebook para obter metadados
            await query.edit_message_text("📚 Analisando livro...")
            reader = EbookReader(str(file_path))

            # Set book title in config for better organization
            config.book_title = reader.title or file_path.stem

            # Get chapter count
            chapters = list(reader.get_chapters())
            total_chapters = len(chapters)

            await query.edit_message_text(
                f"🎙️ Convertendo {total_chapters} capítulos...\n"
                "Progresso: 0%\n\n"
                "⏳ Isso pode levar alguns minutos..."
            )

            # Run conversion
            output_files = await self.run_conversion(config, file_path)

            # Enviar arquivos com validação de tamanho
            if output_files:
                await query.edit_message_text(
                    f"✅ Conversão concluída!\n"
                    f"Enviando {len(output_files)} arquivos...\n\n"
                    "⏳ Aguarde, isso pode levar alguns minutos..."
                )

                sent_count = 0
                skipped_count = 0
                too_large_files = []
                TELEGRAM_MAX_SIZE = 50 * 1024 * 1024  # 50 MB

                for i, audio_file in enumerate(output_files, 1):
                    try:
                        # Check file size
                        file_size = audio_file.stat().st_size

                        if file_size > TELEGRAM_MAX_SIZE:
                            # File too large for Telegram
                            skipped_count += 1
                            too_large_files.append({
                                'name': audio_file.name,
                                'size_mb': file_size / (1024 * 1024)
                            })
                            logger.warning(f"Arquivo muito grande para Telegram: {audio_file.name} ({file_size / 1024 / 1024:.1f} MB)")
                            continue

                        # Send file
                        with open(audio_file, 'rb') as f:
                            # Update progress every 5 files
                            if i % 5 == 0:
                                await context.bot.send_message(
                                    chat_id=update.effective_chat.id,
                                    text=f"📤 Enviando... {i}/{len(output_files)}"
                                )

                            await context.bot.send_audio(
                                chat_id=update.effective_chat.id,
                                audio=f,
                                title=audio_file.stem,
                                caption=f"🎧 {audio_file.name}\n📊 {file_size / (1024 * 1024):.1f} MB"
                            )
                            sent_count += 1

                    except Exception as e:
                        logger.error(f"Erro ao enviar {audio_file}: {e}")
                        skipped_count += 1

                # Summary message
                summary = f"✅ Envio concluído!\n\n"
                summary += f"📨 Enviados: {sent_count} arquivos\n"

                if too_large_files:
                    summary += f"\n⚠️ {len(too_large_files)} arquivo(s) > 50 MB (não enviados):\n"
                    for file_info in too_large_files[:5]:  # Mostrar até 5
                        summary += f"  • {file_info['name']} ({file_info['size_mb']:.1f} MB)\n"
                    if len(too_large_files) > 5:
                        summary += f"  ... e mais {len(too_large_files) - 5}\n"
                    summary += f"\n💡 Dica: Arquivos muito grandes ficam salvos no servidor.\n"
                    summary += f"Em breve: download via link web! 🚀"

                if skipped_count > len(too_large_files):
                    summary += f"\n❌ Erros: {skipped_count - len(too_large_files)} arquivo(s)"

                await context.bot.send_message(
                    chat_id=update.effective_chat.id,
                    text=summary
                )
            else:
                await query.edit_message_text("❌ Nenhum arquivo gerado.")

            # Limpar arquivo temporário
            if file_path.exists():
                file_path.unlink()

            await context.bot.send_message(
                chat_id=update.effective_chat.id,
                text="✅ Processo concluído!\n"
                "Envie /start para converter outro livro."
            )

            context.user_data.clear()
            return ConversationHandler.END

        except Exception as e:
            logger.error(f"Erro na conversão: {e}", exc_info=True)
            await context.bot.send_message(
                chat_id=update.effective_chat.id,
                text=f"❌ Erro durante conversão:\n{str(e)}\n\n"
                "Envie /start para tentar novamente."
            )
            return ConversationHandler.END

    async def run_conversion(self, config: ConversionConfig, file_path: Path) -> list[Path]:
        """Executar conversão e retornar lista de arquivos."""
        try:
            result = await self.converter.convert_book_async(str(file_path), config)
            if result.success:
                return result.output_files
            else:
                logger.error(f"Conversão falhou: {result.errors}")
                return []
        except Exception as e:
            logger.error(f"Erro na conversão: {e}", exc_info=True)
            return []

    def run(self):
        """Iniciar o bot."""
        # Criar aplicação
        application = Application.builder().token(self.token).build()

        # Conversation handler
        conv_handler = ConversationHandler(
            entry_points=[CommandHandler('start', self.start_command)],
            states={
                WAITING_FILE: [
                    MessageHandler(filters.Document.ALL, self.handle_file)
                ],
                SELECT_ENGINE: [
                    CallbackQueryHandler(self.handle_engine_selection, pattern="^engine_")
                ],
                SELECT_VOICE: [
                    CallbackQueryHandler(self.handle_voice_selection)
                ],
                SELECT_OPTIONS: [
                    CallbackQueryHandler(self.handle_options)
                ],
                SELECT_CHAPTERS: [
                    MessageHandler(filters.TEXT & ~filters.COMMAND, self.handle_chapter_selection),
                    CommandHandler('skip', self.show_options_menu)
                ],
            },
            fallbacks=[
                CommandHandler('cancel', self.cancel_command),
                CommandHandler('help', self.help_command)
            ],
        )

        application.add_handler(conv_handler)
        application.add_handler(CommandHandler('help', self.help_command))

        # Iniciar bot
        logger.info("Bot iniciado!")
        application.run_polling(allowed_updates=Update.ALL_TYPES)


def main():
    """Função principal."""
    token = os.getenv("TELEGRAM_BOT_TOKEN")

    if not token:
        logger.error(
            "❌ TELEGRAM_BOT_TOKEN não configurado!\n"
            "Configure: export TELEGRAM_BOT_TOKEN='seu_token_aqui'"
        )
        sys.exit(1)

    bot = TelegramBot(token)
    bot.run()


if __name__ == "__main__":
    main()
