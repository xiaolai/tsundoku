import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'scripts' / 'ux-ui'

# Labels and window names from the separate onboarding/guide flow that
# `Unify setup and recovery in Settings` replaced. A harness that presses one
# of these is driving a product that no longer exists.
REMOVED = [
    'Set Up Tsundoku',
    'Continue Anyway',
    'Grant Library Access',
    'Open Full Disk Access…',
    'Library Access FRAME',
]

A11Y_HARNESSES = ['library-setup-smoke.py', 'audit-recovery-smoke.py']
CURRENT_ACCESS_LABELS = [
    'Set up library imports',
    'Re-check Library Access',
]


class HarnessSelectorTests(unittest.TestCase):
    def test_no_harness_targets_removed_onboarding(self):
        for path in sorted(SCRIPTS.glob('*.py')):
            text = path.read_text()
            for label in REMOVED:
                self.assertNotIn(label, text, f'{path.name}: removed label {label!r}')

    def test_access_harnesses_target_the_current_settings_pane(self):
        for name in A11Y_HARNESSES:
            text = (SCRIPTS / name).read_text()
            for label in CURRENT_ACCESS_LABELS:
                self.assertIn(label, text, f'{name}: missing current label {label!r}')

    def test_library_setup_uses_the_return_action(self):
        text = (SCRIPTS / 'library-setup-smoke.py').read_text()
        self.assertIn('Return to Library', text)


if __name__ == '__main__':
    unittest.main()
