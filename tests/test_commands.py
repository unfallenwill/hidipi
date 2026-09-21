import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from hidipi import backup, cli, macos, state
from test_cli import FakeMac, snapshot


class CommandTests(unittest.TestCase):
    def test_backup_and_restore_dispatch_use_extracted_modules(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            mac = FakeMac()
            with patch.object(state, 'config_dir', return_value=root / 'config'), patch.object(
                    macos, 'Mac', return_value=mac), contextlib.redirect_stdout(io.StringIO()):
                with patch('sys.argv', ['hidipi', '--backup-dir', str(root / 'backups'), 'backup']):
                    self.assertEqual(cli.main(), 0)
                saved = next((root / 'backups').glob('*.json'))
                with patch('sys.argv', ['hidipi', '--backup-dir', str(root / 'backups'), 'restore', str(saved)]):
                    self.assertEqual(cli.main(), 0)
            self.assertEqual(mac.restorations, [snapshot()])
            self.assertEqual(len(list((root / 'backups').glob('*.json'))), 2)

    def test_list_dispatch_uses_extracted_display_workflow(self):
        with patch('sys.argv', ['hidipi', 'list']), patch.object(
                macos, 'Mac', return_value=FakeMac()), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(cli.main(), 0)
        self.assertIn('1920×1080', output.getvalue())
        self.assertIn('HiDPI', output.getvalue())

    def test_library_imports_do_not_load_cli_or_native_frameworks(self):
        script = '''
import ctypes
import importlib
import sys
from unittest.mock import patch
with patch.object(ctypes, 'CDLL', side_effect=AssertionError('native load at import')):
    for module in ('backup', 'modes', 'macos', 'runtime', 'display', 'virtual', 'autostart'):
        importlib.import_module('hidipi.' + module)
assert 'hidipi.cli' not in sys.modules
'''
        env = dict(os.environ, PYTHONPATH=str(Path(cli.__file__).resolve().parents[1]))
        result = subprocess.run([sys.executable, '-c', script], env=env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
