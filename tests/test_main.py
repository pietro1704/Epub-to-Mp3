# -*- coding: utf-8 -*-
"""
Unit tests for main application
"""

import unittest
import tempfile
import os
from pathlib import Path
from unittest.mock import patch, Mock, MagicMock
from argparse import Namespace

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from main import ConverterApplication, create_argument_parser, main


class TestConverterApplication(unittest.TestCase):
    """Test cases for ConverterApplication"""

    def setUp(self):
        """Set up test fixtures"""
        self.temp_dir = tempfile.mkdtemp()
        self.test_file = os.path.join(self.temp_dir, "test.epub")
        
        # Create dummy file
        with open(self.test_file, 'w') as f:
            f.write("dummy content")
        
        self.app = ConverterApplication()

    def tearDown(self):
        """Clean up test fixtures"""
        if os.path.exists(self.test_file):
            os.remove(self.test_file)
        os.rmdir(self.temp_dir)

    def test_init(self):
        """Test application initialization"""
        self.assertIsNotNone(self.app.config)
        self.assertIsNotNone(self.app.menu)
        self.assertIsNotNone(self.app.converter)

    @patch('main.EbookReader')
    def test_run_file_not_found(self, mock_reader):
        """Test running with non-existent file"""
        args = Namespace(
            input_file="/nonexistent/file.epub",
            show_structure=False,
            engine=None,
            voice=None,
            model=None,
            output_dir=None,
            filter_chapters=False,
            parallel=None
        )
        
        result = self.app.run(args)
        self.assertEqual(result, 1)
        mock_reader.assert_not_called()

    @patch('main.asyncio.run')
    @patch('main.EbookReader')
    def test_run_with_show_structure(self, mock_reader, mock_asyncio_run):
        """Test running with show structure option"""
        # Mock reader
        mock_reader_instance = Mock()
        mock_reader_instance.title = "Test Book"
        mock_reader_instance.author = "Test Author"
        mock_reader_instance.get_chapters.return_value = [
            Mock(name="Chapter 1", text="Content 1"),
            Mock(name="Chapter 2", text="Content 2")
        ]
        mock_reader.return_value = mock_reader_instance
        
        args = Namespace(
            input_file=self.test_file,
            show_structure=True,
            engine=None,
            voice=None,
            model=None,
            output_dir=None,
            filter_chapters=False,
            parallel=None
        )
        
        result = self.app.run(args)
        
        self.assertEqual(result, 0)
        mock_reader.assert_called_once_with(self.test_file)
        mock_asyncio_run.assert_not_called()

    @patch('main.asyncio.run')
    @patch('main.EbookReader')
    def test_run_with_engine_specified(self, mock_reader, mock_asyncio_run):
        """Test running with specific engine"""
        mock_reader_instance = Mock()
        mock_reader_instance.title = "Test Book"
        mock_reader.return_value = mock_reader_instance
        
        mock_asyncio_run.return_value = 0
        
        args = Namespace(
            input_file=self.test_file,
            show_structure=False,
            engine="edge",
            voice="test-voice",
            model=None,
            output_dir="test_output",
            filter_chapters=False,
            parallel=None
        )
        
        with patch.object(self.app, '_create_config_from_args') as mock_config:
            mock_config.return_value = Mock()
            
            result = self.app.run(args)
            
            self.assertEqual(result, 0)
            mock_config.assert_called_once()
            mock_asyncio_run.assert_called_once()

    @patch('main.EbookReader')
    def test_run_with_menu(self, mock_reader):
        """Test running with interactive menu"""
        mock_reader_instance = Mock()
        mock_reader_instance.title = "Test Book"
        mock_reader.return_value = mock_reader_instance
        
        args = Namespace(
            input_file=self.test_file,
            show_structure=False,
            engine=None,
            voice=None,
            model=None,
            output_dir=None,
            filter_chapters=False,
            parallel=None,
            menu=True
        )

        with patch.object(self.app.menu, 'get_conversion_config') as mock_menu:
            mock_menu.return_value = None  # User cancelled

            result = self.app.run(args)

            self.assertEqual(result, 1)
            mock_menu.assert_called_once_with(
                mock_reader_instance,
                language_profile=self.app.language_profile,
            )

    def test_create_config_from_args(self):
        """Test creating config from command line arguments"""
        mock_reader = Mock()
        mock_reader.title = "Test Book"
        
        args = Namespace(
            engine="edge",
            voice="test-voice",
            model=None,
            output_dir="test_output",
            filter_chapters=True,
            parallel=5
        )
        
        with patch.object(self.app.config, 'create_conversion_config') as mock_create:
            mock_create.return_value = Mock()
            
            config = self.app._create_config_from_args(args, mock_reader)
            
            self.assertIsNotNone(config)
            mock_create.assert_called_once()
            called_kwargs = mock_create.call_args.kwargs
            self.assertEqual(called_kwargs["engine"], "edge")
            self.assertEqual(called_kwargs["voice"], "test-voice")
            self.assertIsNone(called_kwargs["model"])
            self.assertEqual(called_kwargs["output_dir"], "test_output")
            self.assertEqual(called_kwargs["book_title"], "Test Book")
            self.assertFalse(called_kwargs["preserve_all_chapters"])
            self.assertEqual(called_kwargs["parallel"], 5)
            self.assertFalse(called_kwargs["listen"])
            self.assertIsNone(called_kwargs["cache_dir"])
            self.assertFalse(called_kwargs["clear_cache"])
            self.assertEqual(called_kwargs["footnote_mode"], "inline")
            self.assertEqual(called_kwargs["footnote_context_words"], self.app.FOOTNOTE_CONTEXT_WORDS)

    def test_run_with_exception(self):
        """Test running with exception"""
        args = Namespace(
            input_file=self.test_file,
            show_structure=False,
            engine=None,
            voice=None,
            model=None,
            output_dir=None,
            filter_chapters=False,
            parallel=None
        )

        with patch('main.EbookReader') as mock_reader:
            mock_reader.side_effect = Exception("Test exception")

            result = self.app.run(args)

            self.assertEqual(result, 1)

    def test_deduplicate_heading(self):
        """Ensure duplicate heading lines are removed."""
        text = "Capítulo Um\nCAPÍTULO UM\nConteúdo"  # duplicate heading with different casing
        result = self.app._deduplicate_heading(text, "Capítulo Um")
        self.assertEqual(result, "CAPÍTULO UM\nConteúdo")

        text2 = "\n\nPrólogo\nPrólogo\nTexto"
        result2 = self.app._deduplicate_heading(text2, "")
        self.assertEqual(result2, "Prólogo\nTexto")


class TestArgumentParser(unittest.TestCase):
    """Test cases for argument parser"""

    def test_create_argument_parser(self):
        """Test argument parser creation"""
        parser = create_argument_parser()
        
        # Test required argument
        args = parser.parse_args(["convert", "test.epub"])
        self.assertEqual(args.input_file, "test.epub")
        
        # Test optional arguments
        args = parser.parse_args([
            "convert",
            "test.epub",
            "--engine", "edge",
            "--voice", "test-voice",
            "--model", "test-model",
            "--output-dir", "test-output",
            "--show-structure",
            "--filter-chapters"
        ])
        
        self.assertEqual(args.engine, "edge")
        self.assertEqual(args.voice, "test-voice")
        self.assertEqual(args.model, "test-model")
        self.assertEqual(args.output_dir, "test-output")
        self.assertTrue(args.show_structure)
        self.assertTrue(args.filter_chapters)

    def test_parser_engine_choices(self):
        """Test engine choices validation"""
        parser = create_argument_parser()
        
        # Valid engines
        for engine in ["edge", "coqui", "piper"]:
            args = parser.parse_args(["convert", "test.epub", "--engine", engine])
            self.assertEqual(args.engine, engine)


class TestMainFunction(unittest.TestCase):
    """Test cases for main function"""

    @patch('main.ConverterApplication')
    @patch('sys.argv', ['main.py', 'convert', 'test.epub'])
    def test_main_function(self, mock_app_class):
        """Test main function"""
        mock_app = Mock()
        mock_app.run.return_value = 0
        mock_app_class.return_value = mock_app
        
        result = main()
        self.assertEqual(result, 0)
        mock_app.run.assert_called_once()

    @patch('main.ConverterApplication')
    @patch('sys.argv', ['main.py', 'convert', 'test.epub'])
    def test_main_function_with_error(self, mock_app_class):
        """Test main function with error"""
        mock_app = Mock()
        mock_app.run.return_value = 1
        mock_app_class.return_value = mock_app
        
        result = main()
        self.assertEqual(result, 1)
        mock_app.run.assert_called_once()


if __name__ == '__main__':
    unittest.main()
