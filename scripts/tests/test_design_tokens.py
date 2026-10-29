"""A view may not carry a hand-written design value.

Every distance, radius, type size, opacity, duration and colour in the app's
views must come from `DesignTokens.swift`. That is easy to say and easy to
break: one `.padding(.horizontal, 12)` added in a hurry is invisible in review
and permanent in the code. This test reads the view sources and fails on any
literal in a design position.

Tokens and the theme are the two files allowed to hold numbers — that is where
the numbers live on purpose.
"""

import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
UI = ROOT / 'Sources' / 'TsundokuUI'

# Files that are allowed to name values: the token system itself, and the
# theme, which builds a dynamic colour out of appearance components.
TOKEN_FILES = {'DesignTokens.swift', 'Theme.swift', 'CompanionTheme.swift'}

# A design position followed by a bare number.
PATTERNS = [
    ('padding', re.compile(r'\.padding\((?:\.\w+, )?[0-9]')),
    ('spacing', re.compile(r'\bspacing: [0-9]')),
    ('radius', re.compile(r'cornerRadius: [0-9]')),
    ('font size', re.compile(r'\.system\(size: [0-9]')),
    ('opacity', re.compile(r'\.opacity\((?!0\)|1\))0?\.[0-9]+\)')),
    ('colour', re.compile(r'Color\((?:red|\.sRGB, red): [0-9]')),
    # Zero is structure, not design: a hidden host is sized 0 on purpose.
    ('frame', re.compile(r'\.frame\((?:\w+): (?!0\b)[0-9]')),
    ('line width', re.compile(r'lineWidth: [0-9]')),
    ('shadow', re.compile(r'\.shadow\([^)]*radius: [0-9]')),
    ('motion', re.compile(r'duration: [0-9]')),
    ('offset', re.compile(r'\.offset\((?:\w+): [0-9]')),
]


def violations():
    found = []
    for path in sorted(UI.rglob('*.swift')):
        if path.name in TOKEN_FILES:
            continue
        for number, line in enumerate(
            path.read_text().splitlines(), start=1
        ):
            stripped = line.strip()
            # A comment may say "24 points" and should be allowed to.
            if stripped.startswith('//') or stripped.startswith('///'):
                continue
            for name, pattern in PATTERNS:
                if pattern.search(line):
                    found.append(
                        f'{path.relative_to(ROOT)}:{number}: {name}: '
                        f'{stripped[:100]}')
    return found


class DesignTokenTests(unittest.TestCase):
    def test_views_hold_no_design_literals(self):
        found = violations()
        self.assertEqual(
            found, [],
            'Hand-written design values; use DesignTokens:\n'
            + '\n'.join(found))

    def test_the_scan_sees_a_literal_when_there_is_one(self):
        # Guards the test itself: a regex that stopped matching would make the
        # rule pass by finding nothing, which is how a rule dies.
        for line in [
            '    .padding(.horizontal, 12)',
            '    HStack(spacing: 8) {',
            '        RoundedRectangle(cornerRadius: 10)',
            '        .font(.system(size: 13))',
            '        .opacity(0.25)',
            '        Color(red: 0.1, green: 0.2, blue: 0.3)',
            '        .frame(width: 320)',
            '        .strokeBorder(.black, lineWidth: 1)',
        ]:
            self.assertTrue(
                any(p.search(line) for _, p in PATTERNS), line)


if __name__ == '__main__':
    unittest.main()
