# -*- coding: utf-8 -*-
"""CLI accepts --engine auto as an alias for edge."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import create_argument_parser


class TestEngineAutoAlias(unittest.TestCase):
    def test_auto_is_accepted(self):
        parser = create_argument_parser()
        args = parser.parse_args(["convert", "book.epub", "--engine", "auto"])
        self.assertEqual(args.engine, "auto")

    def test_edge_still_accepted(self):
        parser = create_argument_parser()
        args = parser.parse_args(["convert", "book.epub", "--engine", "edge"])
        self.assertEqual(args.engine, "edge")

    def test_invalid_engine_still_rejected(self):
        parser = create_argument_parser()
        with self.assertRaises(SystemExit):
            parser.parse_args(["convert", "book.epub", "--engine", "bogus"])


if __name__ == "__main__":
    unittest.main()
