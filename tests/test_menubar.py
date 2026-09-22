"""Menu-bar controller behaviour with a fake ObjC bridge."""
import os
import unittest
from unittest.mock import patch

from hidipi import menubar


class FakeRuntime:
    def __init__(self, calls):
        self.calls = calls

    def sel_registerName(self, name):
        self.calls.append(('sel', name))
        return 9000

    def objc_allocateClassPair(self, superclass, name, extra):
        self.calls.append(('allocate', name))
        return 7000

    def class_addMethod(self, klass, selector, imp, types):
        self.calls.append(('addMethod', types))
        return True

    def objc_registerClassPair(self, klass):
        self.calls.append(('register', klass))


class FakeBridge:
    def __init__(self):
        self.calls = []
        self.runtime = FakeRuntime(self.calls)
        self.counter = 1000

    def _next(self):
        self.counter += 1
        return self.counter

    def cls(self, name):
        self.calls.append(('cls', name))
        return self._next()

    def sel(self, name):
        return self.runtime.sel_registerName(name)

    def send(self, receiver, selector, result=None, types=(), values=()):
        if selector == 'respondsToSelector:':
            return 1
        self.calls.append(('send', selector, values))
        return self._next()

    def new(self, name):
        self.calls.append(('new', name))
        return self._next()

    def release(self, obj):
        self.calls.append(('release', obj))

    def string(self, text):
        self.calls.append(('string', text))
        return self._next()


def sent(calls, selector):
    return [record[2] for record in calls
            if len(record) == 3 and record[:2] == ('send', selector)]


class MenuBarTests(unittest.TestCase):
    def setUp(self):
        self.bridge = FakeBridge()
        overrides = (
            patch.object(menubar, '_bridge', return_value=self.bridge),
            patch.object(menubar, '_asset_paths',
                         return_value=['/a.png', '/b.png', '/c.png']),
        )
        for override in overrides:
            override.__enter__()
            self.addCleanup(override.__exit__, None, None, None)

    def selectors(self, selector):
        return [record[1] for record in self.bridge.calls
                if len(record) == 2 and record[0] == selector]

    def test_start_loads_template_icon_and_builds_menu(self):
        controller = menubar.start('1920×1080，渲染 3840×2160，60 Hz，HiDPI', lambda: None)
        self.assertIsNotNone(controller)
        calls = self.bridge.calls
        self.assertEqual(sent(calls, 'statusItemWithLength:'), [(-1.0,)])
        self.assertEqual(sent(calls, 'setTemplate:'), [(True,)])
        self.assertEqual(sent(calls, 'setActivationPolicy:'), [(1,)])
        # One point-size init for the image plus one per representation.
        sizes = [value.x for values in sent(calls, 'initWithSize:') for value in values] + \
                [value.x for values in sent(calls, 'setSize:') for value in values]
        self.assertEqual(sizes, [18.0, 18.0, 18.0, 18.0])
        self.assertEqual(len(sent(calls, 'addRepresentation:')), 3)
        strings = self.selectors('string')
        self.assertIn('hidipi', strings)  # tooltip + accessibility label
        self.assertIn('恢复原始设置并退出', strings)
        self.assertIn(('addMethod', b'v@:@'), calls)
        self.assertIn(('register', 7000), calls)

    def test_menu_action_runs_restore_callback(self):
        stopped = []
        controller = menubar.start('status', lambda: stopped.append(True))
        controller.restore()
        self.assertEqual(stopped, [True])

    def test_stop_removes_item_and_tolerates_none(self):
        controller = menubar.start('status', lambda: None)
        menubar.stop(controller)
        self.assertEqual(len(sent(self.bridge.calls, 'removeStatusItem:')), 1)
        menubar.stop(None)

    def test_environment_switch_disables_icon(self):
        with patch.dict(os.environ, {'HIDIPI_MENUBAR': '0'}):
            self.assertIsNone(menubar.start('status', lambda: None))

    def test_non_darwin_disables_icon(self):
        with patch.object(menubar.sys, 'platform', 'linux'):
            self.assertIsNone(menubar.start('status', lambda: None))

    def test_bridge_failure_degrades_to_none(self):
        with patch.object(menubar, '_bridge', side_effect=OSError('no window server')):
            self.assertIsNone(menubar.start('status', lambda: None))
