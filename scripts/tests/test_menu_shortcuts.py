"""Every menu-bar shortcut in the app means exactly one command.

Two commands sharing a key is invisible until someone presses it: the menu
draws both, and which one wins depends on ordering. ⌘O once meant "Library" in
the status menu and "Open Book Annotations" in the main menu. This reads the
commands file and fails on a repeated key, so the next duplicate is caught by
the gate rather than by a reader.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
COMMANDS = ROOT / 'Sources' / 'TsundokuApp' / 'Companion' / 'TsundokuCommands.swift'

SHORTCUT = re.compile(
    r'\.keyboardShortcut\(\s*"([^"]+)"\s*(?:,\s*modifiers:\s*\[([^\]]*)\])?\s*\)')
MODIFIER = re.compile(r'\.(\w+)')


def shortcuts(source):
    """Every `.keyboardShortcut("x"[, modifiers: [...]])` as (key, set)."""
    found = []
    for key, modifiers in SHORTCUT.findall(source):
        names = set(MODIFIER.findall(modifiers or ''))
        # A missing modifiers argument means ⌘, SwiftUI's default.
        if not names:
            names = {'command'}
        found.append((key, frozenset(names)))
    return found


class MenuShortcutTests(unittest.TestCase):
    def test_commands_file_exists(self):
        self.assertTrue(COMMANDS.is_file(), f'missing {COMMANDS}')

    def test_no_two_commands_share_a_shortcut(self):
        source = COMMANDS.read_text()
        seen = {}
        for key, modifiers in shortcuts(source):
            label = '+'.join(sorted(modifiers)) + '+' + key
            self.assertNotIn(
                label, seen,
                f'shortcut {label} is assigned twice, to '
                f'"{seen.get(label)}" as well')
            seen[label] = label
        self.assertTrue(seen, 'no shortcuts parsed; the pattern no longer matches')

    def test_the_parser_sees_a_known_shortcut(self):
        # Guards the test itself: a regex that stops matching would make the
        # duplicate check pass by finding nothing.
        self.assertIn(('o', frozenset({'command'})), shortcuts(
            '.keyboardShortcut("o")'))
        self.assertIn(
            ('o', frozenset({'command', 'shift'})),
            shortcuts('.keyboardShortcut("o", modifiers: [.command, .shift])'))


if __name__ == '__main__':
    unittest.main()
