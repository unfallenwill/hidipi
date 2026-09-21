import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from hidpi_cli import cli, state


class StateTests(unittest.TestCase):
    def test_default_paths_do_not_depend_on_cwd(self):
        with patch.object(Path, 'home', return_value=Path('/users/example')), patch.object(
                Path, 'cwd', side_effect=AssertionError('must not depend on cwd')):
            self.assertEqual(state.config_dir(), Path('/users/example/.config/hidpi-cli'))
            self.assertEqual(state.backup_dir(), Path('/users/example/.config/hidpi-cli/backups'))

    def test_settings_are_private_and_atomically_replaced(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(state, 'config_dir', return_value=Path(folder)):
            state.save_settings({'enabled': True, 'install_backup': '/saved.json'})
            state.save_settings({'enabled': False, 'install_backup': '/saved.json'})
            path = Path(folder)/'autostart.json'
            self.assertFalse(json.loads(path.read_text())['enabled'])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertFalse(list(Path(folder).glob('.autostart-*')))

    def test_paths_command_does_not_access_displays(self):
        output = io.StringIO()
        with patch('sys.argv', ['hidpi', 'paths']), patch.object(
                cli, 'Mac', side_effect=AssertionError('read-only paths')), contextlib.redirect_stdout(output):
            self.assertEqual(cli.main(), 0)
        self.assertIn(str(state.backup_dir()), output.getvalue())


if __name__ == '__main__':
    unittest.main()
