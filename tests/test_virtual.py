import argparse
import contextlib
import copy
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from hidpi_cli import autostart, backup as backups, errors, runtime, virtual
from test_cli import mode, snapshot


class VirtualTests(unittest.TestCase):
    def test_late_refresh_reporting_does_not_look_like_mode_change(self):
        expected = mode(scale=2, hz=60)
        self.assertTrue(virtual.mode_matches(mode(scale=2, hz=0), expected))
        self.assertTrue(virtual.mode_matches(mode(scale=2, hz=60), expected))
        self.assertFalse(virtual.mode_matches(mode(scale=2, hz=50), expected))
        self.assertFalse(virtual.mode_matches(mode(scale=1, hz=0), expected))

    def test_fallback_is_not_replayed_as_physical_hardware(self):
        original = snapshot()
        original['displays'][0].update(vendor=0x756E6B6E, model=0x76697274)
        mac = MagicMock()
        mac.snapshot.return_value = original
        saved = virtual.capture_original(mac)
        self.assertEqual(saved['displays'], [])
        self.assertTrue(saved['headless'])
        self.assertEqual(saved['system_fallback'], original['displays'])
        self.assertEqual(backups.validate_backup(saved), saved)

    def test_truly_empty_headless_backup_roundtrips(self):
        mac = MagicMock()
        mac.snapshot.return_value = dict(schema=2, headless=True, displays=[])
        with tempfile.TemporaryDirectory() as folder:
            saved = virtual.capture_original(mac)
            path = backups.write_backup(saved, Path(folder))
            self.assertTrue(path.exists())

    def test_empty_legacy_backup_still_rejected(self):
        with self.assertRaises(errors.HiDPIError):
            backups.validate_backup(dict(schema=1, displays=[]))
        with self.assertRaises(errors.HiDPIError):
            backups.validate_backup(dict(schema=2, headless=False, displays=[]))

    def test_unplugged_physical_display_does_not_block_virtual_cleanup(self):
        mac = MagicMock()
        mac.ids.return_value = []
        with contextlib.redirect_stdout(io.StringIO()):
            virtual.restore_connected(mac, snapshot())
        mac.restore.assert_not_called()

    def test_connected_physical_screen_is_restored(self):
        mac = MagicMock()
        mac.ids.return_value = [99]
        mac.identity.return_value = snapshot()['displays'][0]['uuid']
        virtual.restore_connected(mac, snapshot())
        mac.restore.assert_called_once_with(snapshot())

    def test_invalid_mode_sizes_and_refresh_rejected(self):
        for size, refresh in [((7680, 4320), 60), ((1920, 1080), float('nan')),
                              ((1920, 1080), 0), ((1920,1080), 1000)]:
            with self.subTest(size=size, refresh=refresh), self.assertRaises(errors.HiDPIError):
                virtual.validate_options(argparse.Namespace(size=size, refresh=refresh, seconds=20))

    def test_failed_start_still_closes_owned_display(self):
        mac, display = MagicMock(), MagicMock()
        mac.snapshot.return_value = dict(schema=2, headless=True, displays=[])
        mac.ids.return_value = []
        display.start.side_effect = errors.HiDPIError('mode not available')
        with tempfile.TemporaryDirectory() as folder, patch.object(
                virtual, 'VirtualDisplay', return_value=display), contextlib.redirect_stdout(io.StringIO()):
            args = argparse.Namespace(size=(1920,1080), refresh=60, seconds=5,
                                      keep=False, backup_dir=Path(folder))
            with self.assertRaisesRegex(errors.HiDPIError, 'mode not available'):
                virtual.run(mac, args)
            self.assertEqual(len(list(Path(folder).glob('*.json'))), 1)
        display.close.assert_called_once()

    def test_backup_failure_prevents_virtual_creation(self):
        mac = MagicMock()
        mac.snapshot.return_value = dict(schema=2, headless=True, displays=[])
        args = argparse.Namespace(size=(1920,1080), refresh=60, seconds=5,
                                  keep=False, backup_dir=Path('/unused'))
        with patch.object(backups, 'write_backup', side_effect=OSError('disk full')), patch.object(
                virtual, 'VirtualDisplay') as create:
            with self.assertRaises(OSError):
                virtual.run(mac, args)
            create.assert_not_called()

    def test_virtual_service_has_no_physical_device_dependency(self):
        data = autostart.make_virtual_plist(Path('/tools/python'), Path('/config'),
            Path('/backups'), mode(scale=2), Path('/backups/original.json'))
        argv = data['ProgramArguments']
        self.assertIn('virtual', argv)
        self.assertIn('--keep', argv)
        self.assertNotIn('--display-uuid', argv)
        self.assertNotIn('--wait-display', argv)
        self.assertEqual(data['EnvironmentVariables']['HIDPI_MODE'], 'virtual')

    def test_virtual_preview_completion_removes_screen(self):
        mac, display = MagicMock(), MagicMock()
        mac.snapshot.return_value = dict(schema=2, headless=True, displays=[])
        mac.ids.return_value = []
        mac.current.return_value = mode(scale=2)
        with tempfile.TemporaryDirectory() as folder, patch.object(
                virtual, 'VirtualDisplay', return_value=display), patch.object(runtime, 'preview'), contextlib.redirect_stdout(io.StringIO()):
            virtual.run(mac, argparse.Namespace(size=(1920,1080), refresh=60,
                seconds=5, keep=False, backup_dir=Path(folder)))
        display.close.assert_called_once()


if __name__ == '__main__':
    unittest.main()
