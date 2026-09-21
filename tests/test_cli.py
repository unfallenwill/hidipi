import argparse
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from hidpi_cli import cli


def mode(width=1920, height=1080, scale=1, hz=60, mode_id=1):
    return dict(width=width, height=height, pixel_width=width*scale,
                pixel_height=height*scale, hz=hz, mode_id=mode_id, flags=0, usable=True)


def snapshot():
    return dict(schema=1, created='test', macos='27.0', displays=[dict(
        id=3, uuid='ED40079C-8DA0-44AB-98D6-ED5012B553FB', vendor=1, model=2,
        serial=0, builtin=False, main=True, mirror_of=0, in_mirror_set=False,
        origin=[0, 0], millimeters=[500, 300], mode=mode())])


class FakeMac:
    def __init__(self, fail_switch=False, ignore_switch=False):
        self.original = snapshot()
        self.actual = mode()
        self.changes = []
        self.restorations = []
        self.fail_switch = fail_switch
        self.ignore_switch = ignore_switch

    def snapshot(self):
        return copy.deepcopy(self.original)

    @contextlib.contextmanager
    def modes(self, display):
        yield [mode(), mode(scale=2, hz=50, mode_id=2)]

    def info(self, ptr):
        return ptr

    def set_mode(self, display, expected):
        self.changes.append(expected)
        if self.fail_switch:
            # Simulate partial application followed by an OS error.
            self.actual = expected
            raise cli.HiDPIError('simulated transaction failure')
        if not self.ignore_switch:
            self.actual = expected

    def current(self, display):
        return self.actual

    def wait_until(self, predicate, error, timeout):
        if not predicate():
            raise cli.HiDPIError(error)

    def restore(self, saved):
        self.restorations.append(saved)
        self.actual = saved['displays'][0]['mode']


class Backups(unittest.TestCase):
    def test_backup_is_durable_unique_private_and_roundtrips(self):
        with tempfile.TemporaryDirectory() as folder:
            first = cli.write_backup(snapshot(), Path(folder))
            second = cli.write_backup(snapshot(), Path(folder))
            self.assertNotEqual(first, second)
            self.assertEqual(json.loads(first.read_text()), snapshot())
            self.assertEqual(first.stat().st_mode & 0o777, 0o600)
            self.assertFalse(list(Path(folder).glob('.backup-*')))

    def test_invalid_backups_rejected(self):
        corruptions = [
            lambda s: s.update(schema=2),
            lambda s: s['displays'][0].update(mode=None),
            lambda s: s['displays'][0].update(uuid='not-a-uuid'),
            lambda s: s['displays'][0].update(mirror_of=99),
            lambda s: s['displays'][0].update(origin=[2**40, 0]),
            lambda s: s['displays'][0]['mode'].update(pixel_width=-1),
            lambda s: s['displays'][0]['mode'].update(hz=float('nan')),
            lambda s: s['displays'].append(copy.deepcopy(s['displays'][0])),
        ]
        for corrupt in corruptions:
            saved = snapshot()
            corrupt(saved)
            with self.subTest(saved=saved), self.assertRaises(cli.HiDPIError):
                cli.validate_backup(saved)

    def test_atomic_rename_failure_leaves_existing_backups(self):
        with tempfile.TemporaryDirectory() as folder:
            old = cli.write_backup(snapshot(), Path(folder))
            with patch.object(cli.os, 'replace', side_effect=OSError('disk error')):
                with self.assertRaises(OSError):
                    cli.write_backup(snapshot(), Path(folder))
            self.assertEqual(json.loads(old.read_text()), snapshot())
            self.assertFalse(list(Path(folder).glob('.backup-*')))

    def test_single_instance_across_backup_directories(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(cli.tempfile, 'gettempdir', return_value=folder), cli.single_instance(Path('/unused/a')):
            with self.assertRaises(cli.HiDPIError):
                with cli.single_instance(Path('/unused/b')):
                    pass


class Selection(unittest.TestCase):
    def test_only_real_two_axis_hidpi_selected(self):
        almost = mode(scale=2)
        almost['pixel_height'] = 1080
        with self.assertRaises(cli.HiDPIError):
            cli.choose_mode([mode(), almost], (1920, 1080), mode())

    def test_prefer_current_refresh_over_higher_refresh(self):
        sixty, fast = mode(scale=2), mode(scale=2, hz=120)
        self.assertEqual(cli.choose_mode([fast, sixty], (1920, 1080), mode()), sixty)

    def test_explicit_refresh_cannot_silently_fall_back(self):
        with self.assertRaises(cli.HiDPIError):
            cli.choose_mode([mode(scale=2, hz=50)], (1920, 1080), mode(), 60)

    def test_changed_mode_ids_do_not_prevent_matching(self):
        self.assertTrue(cli.mode_matches(mode(mode_id=99), mode(mode_id=1)))
        self.assertFalse(cli.mode_matches(mode(scale=2), mode()))


class DockIcon(unittest.TestCase):
    def test_long_running_preview_demotes_dock_icon(self):
        mac = FakeMac()
        with patch.object(cli, 'hide_dock_icon') as hide, patch.object(cli.sys, 'stdin') as stdin:
            stdin.isatty.return_value = False
            with contextlib.redirect_stdout(io.StringIO()):
                cli.preview(mac, 3, mode(scale=2, hz=50), 5, True, {'stop': True})
        hide.assert_called_once()

    def test_hide_dock_icon_never_raises(self):
        cli.hide_dock_icon()


class Rollback(unittest.TestCase):
    def run_enable(self, mac, directory):
        args = argparse.Namespace(display=None, size=(1920, 1080), refresh=None,
                                  backup_dir=Path(directory), seconds=5, keep=False)
        with contextlib.redirect_stdout(io.StringIO()):
            cli.enable_hidpi(mac, args)

    def test_backup_failure_prevents_display_change(self):
        mac = FakeMac()
        with tempfile.TemporaryDirectory() as folder, patch.object(
                cli, 'write_backup', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.run_enable(mac, folder)
        self.assertEqual(mac.changes, [])

    def test_os_switch_error_restores_original(self):
        mac = FakeMac(fail_switch=True)
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(cli.HiDPIError):
                self.run_enable(mac, folder)
            self.assertEqual(len(list(Path(folder).glob('*.json'))), 1)
        self.assertEqual(mac.actual, mode())
        self.assertEqual(len(mac.restorations), 1)

    def test_os_silent_noop_is_detected_and_rolled_back(self):
        mac = FakeMac(ignore_switch=True)
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(cli.HiDPIError):
                self.run_enable(mac, folder)
        self.assertEqual(len(mac.restorations), 1)

    def test_preview_completion_restores_original(self):
        mac = FakeMac()
        with tempfile.TemporaryDirectory() as folder, patch.object(cli, 'preview'):
            self.run_enable(mac, folder)
        self.assertEqual(len(mac.changes), 1)
        self.assertEqual(mac.actual, mode())

    def test_interruption_in_preview_restores_original(self):
        mac = FakeMac()
        with tempfile.TemporaryDirectory() as folder, patch.object(
                cli, 'preview', side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.run_enable(mac, folder)
        self.assertEqual(mac.actual, mode())

    def test_restore_failure_preserves_recovery_file(self):
        mac = FakeMac()
        with tempfile.TemporaryDirectory() as folder, patch.object(cli, 'preview'), patch.object(
                mac, 'restore', side_effect=cli.HiDPIError('display disconnected')):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(cli.HiDPIError):
                self.run_enable(mac, folder)
            saved = list(Path(folder).glob('*.json'))
            self.assertEqual(len(saved), 1)
            self.assertEqual(json.loads(saved[0].read_text()), snapshot())


if __name__ == '__main__':
    unittest.main()
