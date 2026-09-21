"""Opt-in desktop smoke tests; never call GUI APIs in the test runner itself."""
import os
from pathlib import Path
import subprocess
import sys
import unittest


@unittest.skipUnless(
    sys.platform == 'darwin' and os.environ.get('HIDPI_NATIVE_TESTS') == '1',
    'requires HIDPI_NATIVE_TESTS=1 in an unsandboxed macOS desktop session',
)
class NativeDesktopTests(unittest.TestCase):
    def test_hide_dock_icon_completes_in_child_process(self):
        source = Path(__file__).resolve().parents[1] / 'src'
        env = dict(os.environ, PYTHONPATH=str(source))
        result = subprocess.run(
            [sys.executable, '-c',
             'from hidipi.macos import hide_dock_icon; hide_dock_icon()'],
            env=env, capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0,
                         f'Native Dock call exited with {result.returncode}. '
                         'Run only in an unsandboxed macOS desktop session.\n'
                         f'{result.stdout}{result.stderr}')


if __name__ == '__main__':
    unittest.main()
