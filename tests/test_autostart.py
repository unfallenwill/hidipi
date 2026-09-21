import argparse
import contextlib
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from hidipi import autostart, backup as backups, cli, display, errors, macos, state
from test_cli import FakeMac, mode, snapshot


class AutostartTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        override = patch.object(state, 'config_dir', return_value=Path(folder.name)/'config')
        override.start()
        self.addCleanup(override.stop)

    def test_plist_uses_absolute_venv_and_stable_uuid(self):
        data = autostart.make_plist(Path('/project with space/.venv/bin/python'),
            Path('/project with space'), Path('/backups'), snapshot()['displays'][0]['uuid'],
            mode(scale=2, hz=50), Path('/backups/original.json'))
        data = plistlib.loads(plistlib.dumps(data))
        argv = data['ProgramArguments']
        self.assertEqual(argv[1:4], ['-u', '-m', 'hidipi'])
        self.assertEqual(argv[0], '/project with space/.venv/bin/python')
        self.assertIn('--display-uuid', argv)
        self.assertNotIn('--display', argv)
        self.assertIn('--keep', argv)
        self.assertEqual(argv[argv.index('--refresh')+1], '50')
        self.assertTrue(data['RunAtLoad'])
        self.assertFalse(data['KeepAlive'])
        self.assertEqual(data['WorkingDirectory'], '/project with space')
        self.assertEqual(data['StandardOutPath'], '/project with space/logs/autostart.log')
        self.assertEqual(data['EnvironmentVariables']['HIDPI_INSTALL_BACKUP'], '/backups/original.json')

    def test_bootstrap_failure_preserves_plist_and_recovery_record(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = argparse.Namespace(backup_dir=root/'backups', display=None,
                                      size=(1920, 1080), refresh=None, dry_run=False)
            path = root/'LaunchAgents'/'test.plist'
            def launch(*args, **kwargs):
                if args[0] == 'bootstrap':
                    raise errors.HiDPIError('failure')
            with patch.object(autostart, 'agent_path', return_value=path), patch.object(
                macos, 'Mac', return_value=FakeMac()), patch.object(
                autostart, 'launchctl', side_effect=launch), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(errors.HiDPIError):
                    autostart.install(args)
            self.assertTrue(path.exists())
            self.assertEqual(state.load_settings()['phase'], 'start_pending')
            self.assertEqual(len(list(args.backup_dir.glob('*.json'))), 1)

    def test_unknown_refresh_plist_runs_without_invalid_refresh_argument(self):
        data = autostart.make_plist(Path('/python'), Path('/config'), Path('/backups'),
            snapshot()['displays'][0]['uuid'], mode(scale=2, hz=0), Path('/backup.json'))
        argv = data['ProgramArguments'][4:]
        self.assertNotIn('--refresh', argv)
        with patch('sys.argv', ['hidipi', *argv]), patch.object(macos, 'Mac'), patch.object(
                display, 'wait_for_display', return_value=True), patch.object(display, 'enable_hidpi') as enable:
            self.assertEqual(cli.main(), 0)
        self.assertIsNone(enable.call_args.args[1].refresh)

    def test_uninstall_stops_service_even_when_backup_is_unusable(self):
        for contents in (None, '{broken', '{"schema": 99}'):
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                backup = root / 'original.json'
                if contents is not None:
                    backup.write_text(contents)
                path = root / 'agent.plist'
                path.write_bytes(plistlib.dumps(autostart.make_virtual_plist(
                    Path('/python'), root, root, mode(scale=2), backup)))
                state.save_settings({'enabled': True})
                with patch.object(autostart, 'agent_path', return_value=path), patch.object(
                        autostart, 'launchctl', return_value=subprocess.CompletedProcess([], 0, '', '')) as launch, patch.object(
                        macos, 'Mac') as mac, contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(
                        errors.HiDPIError, '自启动已卸载，但无法恢复'):
                    autostart.uninstall(argparse.Namespace(backup_dir=root))
                launch.assert_any_call('bootout', autostart.service())
                mac.assert_not_called()
                self.assertFalse(path.exists())
                self.assertFalse(json.loads((state.config_dir() / 'autostart.json').read_text())['enabled'])
                self.assertEqual(state.load_settings()['phase'], 'restore_pending')
                if contents is not None:
                    self.assertEqual(backup.read_text(), contents)

    def test_dry_run_does_not_write_backup_or_install(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = argparse.Namespace(backup_dir=root/'backups', display=None,
                                      size=(1920, 1080), refresh=None, dry_run=True)
            with patch.object(autostart, 'agent_path', return_value=root/'agent.plist'), patch.object(
                macos, 'Mac', return_value=FakeMac()), patch.object(
                autostart, 'launchctl') as launch, contextlib.redirect_stdout(io.StringIO()):
                autostart.install(args)
                launch.assert_not_called()
            self.assertFalse((root/'agent.plist').exists())
            self.assertFalse(args.backup_dir.exists())

    def test_wait_handles_changed_display_id(self):
        mac = FakeMac()
        mac.original['displays'][0]['id'] = 99
        args = argparse.Namespace(wait_display=1, display=None,
            display_uuid=mac.original['displays'][0]['uuid'], size=(1920,1080), refresh=50)
        self.assertTrue(display.wait_for_display(mac, args))

    def test_uninstall_does_not_delete_agent_if_bootout_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            backup = backups.write_backup(snapshot(), root)
            path = root/'agent.plist'
            path.write_bytes(plistlib.dumps(autostart.make_plist(Path('/python'), root, root,
                snapshot()['displays'][0]['uuid'], mode(), backup)))
            def launch(*args, **kwargs):
                if args[0] == 'bootout':
                    raise errors.HiDPIError('denied')
                return subprocess.CompletedProcess(args, 0, '', '')
            with patch.object(autostart, 'agent_path', return_value=path), patch.object(
                autostart, 'launchctl', side_effect=launch), self.assertRaises(errors.HiDPIError):
                autostart.uninstall(argparse.Namespace(backup_dir=root))
            self.assertTrue(path.exists())
            self.assertTrue(backup.exists())

    def test_uninstall_restores_install_backup_and_keeps_history(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            backup = backups.write_backup(snapshot(), root)
            path = root/'agent.plist'
            path.write_bytes(plistlib.dumps(autostart.make_plist(Path('/python'), root, root,
                snapshot()['displays'][0]['uuid'], mode(), backup)))
            mac = FakeMac()
            with patch.object(autostart, 'agent_path', return_value=path), patch.object(
                autostart, 'launchctl', return_value=subprocess.CompletedProcess([], 0, '', '')), patch.object(
                macos, 'Mac', return_value=mac), contextlib.redirect_stdout(io.StringIO()):
                autostart.uninstall(argparse.Namespace(backup_dir=root))
            self.assertEqual(mac.restorations, [snapshot()])
            self.assertFalse(path.exists())
            self.assertEqual(len(list(root.glob('*.json'))), 2)


if __name__ == '__main__':
    unittest.main()
