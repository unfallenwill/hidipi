"""Failure injection for persistent LaunchAgent lifecycle transitions."""
import argparse
import contextlib
import io
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from hidipi import autostart, backup, errors, macos, runtime, state
from test_cli import FakeMac, mode, snapshot


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.path = self.root / 'LaunchAgents' / 'agent.plist'
        self.args = argparse.Namespace(backup_dir=self.root / 'backups', display=None,
            size=(1920, 1080), refresh=None, dry_run=False)
        for override in (
            patch.object(state, 'config_dir', return_value=self.root / 'config'),
            patch.object(autostart, 'agent_path', return_value=self.path),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            override.__enter__()
            self.addCleanup(override.__exit__, None, None, None)

    def prepare_agent(self):
        saved = backup.write_backup(snapshot(), self.args.backup_dir)
        data = autostart.make_plist(Path('/python'), self.root, self.args.backup_dir,
            snapshot()['displays'][0]['uuid'], mode(), saved)
        autostart.write_agent(self.path, data)
        return saved

    def result(self, code=0):
        return subprocess.CompletedProcess([], code, '', '')

    def test_bootstrap_timeout_keeps_manageable_service_and_can_uninstall(self):
        mac = FakeMac()
        calls = []
        def launch(argv, **kwargs):
            calls.append(argv[1])
            if argv[1] == 'bootstrap':
                # Model launchd accepting the job before the client times out.
                raise subprocess.TimeoutExpired(argv, 30)
            return self.result()
        with patch.object(macos, 'Mac', return_value=mac), patch.object(
                autostart.subprocess, 'run', side_effect=launch):
            with self.assertRaisesRegex(errors.HiDPIError, '配置和备份已保留'):
                autostart.install(self.args)
            self.assertTrue(self.path.exists())
            self.assertEqual(state.load_settings()['phase'], 'start_pending')
            autostart.uninstall(self.args)
        self.assertIn('bootout', calls)
        self.assertFalse(self.path.exists())
        self.assertEqual(state.load_settings()['phase'], 'uninstalled')
        self.assertEqual(mac.restorations, [snapshot()])

    def test_install_releases_display_lock_but_keeps_lifecycle_lock_at_bootstrap(self):
        def launch(command, *args, **kwargs):
            if command == 'bootstrap':
                with runtime.single_instance():
                    pass
                with self.assertRaises(errors.HiDPIError):
                    with runtime.autostart_lock():
                        pass
            return self.result()
        with patch.object(macos, 'Mac', return_value=FakeMac()), patch.object(
                autostart, 'launchctl', side_effect=launch):
            autostart.install(self.args)
        self.assertEqual(state.load_settings()['phase'], 'submitted')

    def test_plist_publish_failure_never_starts_service_or_leaves_partial_file(self):
        with patch.object(macos, 'Mac', return_value=FakeMac()), patch.object(
                autostart.os, 'link', side_effect=OSError('disk failure')), patch.object(
                autostart, 'launchctl') as launch:
            with self.assertRaises(OSError):
                autostart.install(self.args)
        launch.assert_not_called()
        self.assertFalse(self.path.exists())
        self.assertFalse(list(self.path.parent.glob('.hidipi-agent-*')))
        self.assertTrue(Path(state.load_settings()['install_backup']).exists())

    def test_atomic_publish_refuses_existing_file(self):
        self.path.parent.mkdir(parents=True)
        self.path.write_bytes(b'existing configuration')
        with self.assertRaises(FileExistsError):
            autostart.write_agent(self.path, {'Label': autostart.LABEL})
        self.assertEqual(self.path.read_bytes(), b'existing configuration')

    def test_settings_write_failure_prevents_installation(self):
        with patch.object(macos, 'Mac', return_value=FakeMac()), patch.object(
                state, 'save_settings', side_effect=OSError('disk full')), patch.object(
                autostart, 'launchctl') as launch:
            with self.assertRaises(OSError):
                autostart.install(self.args)
        launch.assert_not_called()
        self.assertFalse(self.path.exists())

    def test_bootout_timeout_preserves_configuration_and_retry_handles_absent_job(self):
        saved = self.prepare_agent()
        def launch(command, *args, **kwargs):
            if command == 'bootout':
                raise errors.HiDPIError('timeout')
            return self.result()
        with patch.object(autostart, 'launchctl', side_effect=launch):
            with self.assertRaisesRegex(errors.HiDPIError, 'timeout'):
                autostart.uninstall(self.args)
        self.assertTrue(self.path.exists())
        self.assertTrue(saved.exists())
        self.assertEqual(state.load_settings()['phase'], 'stop_pending')
        with patch.object(autostart, 'launchctl', return_value=self.result(113)) as launch, patch.object(
                macos, 'Mac', return_value=FakeMac()):
            autostart.uninstall(self.args)
        launch.assert_called_once_with('print', autostart.service(), checked=False)
        self.assertEqual(state.load_settings()['phase'], 'uninstalled')

    def test_restore_failure_is_retryable_after_plist_removal(self):
        saved = self.prepare_agent()
        mac = FakeMac()
        with patch.object(autostart, 'launchctl', return_value=self.result(113)), patch.object(
                macos, 'Mac', return_value=mac):
            with patch.object(mac, 'restore', side_effect=errors.HiDPIError('disconnected')):
                with self.assertRaisesRegex(errors.HiDPIError, '重试 autostart uninstall'):
                    autostart.uninstall(self.args)
            self.assertFalse(self.path.exists())
            self.assertEqual(state.load_settings()['phase'], 'restore_pending')
            with self.assertRaisesRegex(errors.HiDPIError, '上次卸载尚未完成恢复'):
                autostart.install(self.args)
            autostart.uninstall(self.args)
        self.assertEqual(mac.restorations, [snapshot()])
        self.assertEqual(state.load_settings()['phase'], 'uninstalled')
        self.assertTrue(saved.exists())

    def test_corrupt_settings_can_be_reconstructed_from_plist(self):
        self.prepare_agent()
        state.config_dir().mkdir()
        (state.config_dir() / 'autostart.json').write_text('{broken')
        with patch.object(autostart, 'launchctl', return_value=self.result(113)), patch.object(
                macos, 'Mac', return_value=FakeMac()):
            autostart.uninstall(self.args)
        self.assertFalse(self.path.exists())
        self.assertEqual(state.load_settings()['phase'], 'uninstalled')

    def test_journal_failure_keeps_plist_for_retry(self):
        self.prepare_agent()
        with patch.object(state, 'save_settings', side_effect=OSError('disk full')), patch.object(
                autostart, 'launchctl') as launch:
            with self.assertRaises(OSError):
                autostart.uninstall(self.args)
        launch.assert_not_called()
        self.assertTrue(self.path.exists())

    def test_display_cleanup_timeout_preserves_pending_restore(self):
        self.prepare_agent()
        with patch.object(autostart, 'launchctl', return_value=self.result(113)), patch.object(
                runtime, 'single_instance', side_effect=errors.HiDPIError('busy')), patch.object(
                macos, 'Mac') as mac:
            with self.assertRaisesRegex(errors.HiDPIError, '恢复记录已保留'):
                autostart.uninstall(self.args)
        mac.assert_not_called()
        self.assertFalse(self.path.exists())
        self.assertEqual(state.load_settings()['phase'], 'restore_pending')

    def test_pending_restore_is_visible_in_status(self):
        state.save_settings(dict(phase='restore_pending', install_backup='/saved.json'))
        with patch.object(autostart, 'launchctl', return_value=self.result(113)), contextlib.redirect_stdout(io.StringIO()) as output:
            autostart.status()
        self.assertIn('恢复未完成', output.getvalue())
        self.assertIn('/saved.json', output.getvalue())

    def test_renamed_project_can_uninstall_legacy_agent(self):
        saved = self.prepare_agent()
        data = plistlib.loads(self.path.read_bytes())
        data['Label'] = 'local.hidpi-cli.agent'
        data['ProgramArguments'][3] = 'hidpi_cli'
        self.path.write_bytes(plistlib.dumps(data))
        mac = FakeMac()
        with patch.object(autostart, 'launchctl', return_value=self.result()) as launch, patch.object(
                macos, 'Mac', return_value=mac):
            autostart.uninstall(self.args)
        launch.assert_any_call('bootout', autostart.service())
        self.assertFalse(self.path.exists())
        self.assertTrue(saved.exists())
        self.assertEqual(mac.restorations, [snapshot()])
