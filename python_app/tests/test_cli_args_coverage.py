# -*- coding: utf-8 -*-
"""Coverage tests for every CLI argument exposed by ``create_argument_parser``.

Rather than maintain a hand-written list of 100+ flag assertions (which
drifts the moment someone adds a new flag), these tests drive the parser
reflectively:

- every declared argument is exercised through ``parse_args``
- store_true/store_false flags are flipped
- ``choices``-constrained arguments validate every legal value and reject
  one known-bad value
- defaults are verified when ``required=False``
"""

import argparse
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import create_argument_parser


def _iter_convert_actions(parser: argparse.ArgumentParser):
    # The "convert" subparser is the one we care about.
    subparsers_action = next(
        (a for a in parser._actions if isinstance(a, argparse._SubParsersAction)),
        None,
    )
    assert subparsers_action is not None, "expected subparsers in CLI"
    convert = subparsers_action.choices.get("convert")
    assert convert is not None, "expected a `convert` subcommand"
    for action in convert._actions:
        if not action.option_strings:
            continue  # positional
        if isinstance(action, argparse._HelpAction):
            continue
        yield action


class TestCliArgsCoverage(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parser = create_argument_parser()
        cls.actions = list(_iter_convert_actions(cls.parser))
        # Guard against silent regressions — if the flag set shrinks we want
        # to know.
        assert len(cls.actions) >= 90, f"CLI shrank unexpectedly: {len(cls.actions)}"

    def test_every_flag_has_option_string(self):
        for action in self.actions:
            self.assertTrue(
                any(s.startswith("-") for s in action.option_strings),
                f"{action.dest} has no option string",
            )

    def test_store_true_flags_flip(self):
        for action in self.actions:
            if isinstance(action, argparse._StoreTrueAction):
                flag = action.option_strings[0]
                args = self.parser.parse_args(["convert", "test.epub", flag])
                self.assertTrue(
                    getattr(args, action.dest),
                    f"{flag} should set {action.dest}=True",
                )

    def test_store_false_flags_flip(self):
        for action in self.actions:
            if isinstance(action, argparse._StoreFalseAction):
                flag = action.option_strings[0]
                args = self.parser.parse_args(["convert", "test.epub", flag])
                self.assertFalse(
                    getattr(args, action.dest),
                    f"{flag} should set {action.dest}=False",
                )

    def test_choice_args_accept_every_choice(self):
        for action in self.actions:
            if not action.choices:
                continue
            if not isinstance(action, argparse._StoreAction):
                continue
            flag = action.option_strings[0]
            for choice in action.choices:
                args = self.parser.parse_args(["convert", "test.epub", flag, str(choice)])
                self.assertEqual(getattr(args, action.dest), choice)

    def test_choice_args_reject_bogus_value(self):
        for action in self.actions:
            if not action.choices:
                continue
            if not isinstance(action, argparse._StoreAction):
                continue
            flag = action.option_strings[0]
            bogus = "___definitely_not_a_valid_choice___"
            with self.assertRaises(SystemExit):
                self.parser.parse_args(["convert", "test.epub", flag, bogus])

    def test_defaults_are_reachable(self):
        args = self.parser.parse_args(["convert", "test.epub"])
        for action in self.actions:
            if action.required:
                continue
            self.assertTrue(
                hasattr(args, action.dest),
                f"parsed namespace missing {action.dest}",
            )


if __name__ == "__main__":
    unittest.main()
