"""Pure display-mode selection, comparison and size parsing."""
import argparse
from . import errors


def mode_matches(actual, expected):
    return bool(actual) and all(actual[k] == expected[k] for k in
                               ("width", "height", "pixel_width", "pixel_height")) and (
        abs(actual["hz"] - expected["hz"]) < 0.6)


def is_hidpi(mode):
    return bool(mode) and mode["pixel_width"] >= 2 * mode["width"] and (
        mode["pixel_height"] >= 2 * mode["height"])


def describe(mode):
    if not mode:
        return "模式暂不可用"
    rate = f'{mode["hz"]:g} Hz' if mode['hz'] else '刷新率未报告'
    return (f'{mode["width"]}×{mode["height"]}，渲染 {mode["pixel_width"]}×'
            f'{mode["pixel_height"]}，{rate}，'
            f'{"HiDPI" if is_hidpi(mode) else "普通 DPI"}')


def size_value(value):
    try:
        w, h = map(int, value.lower().replace('×', 'x').split('x'))
        if not (640 <= w <= 7680 and 480 <= h <= 4320):
            raise ValueError()
        return w, h
    except ValueError:
        raise argparse.ArgumentTypeError("请使用 1920x1080 格式；宽 640–7680、高 480–4320。")


def choose_mode(modes, size, current, refresh=None):
    candidates = [m for m in modes if m['usable'] and is_hidpi(m) and
                  (m['width'], m['height']) == tuple(size) and
                  (refresh is None or abs(m['hz'] - refresh) < 0.6)]
    if not candidates:
        requested = f'{size[0]}×{size[1]}' + (f' @ {refresh:g} Hz' if refresh else '')
        raise errors.HiDPIError(f'系统没有提供 {requested} 的 HiDPI 模式；未修改设置。'
                         '请运行 list 选择已有模式。本工具不会伪造显示器配置。')
    # Preserve the existing refresh rate when possible; otherwise use the
    # highest available refresh rate. Never silently select a LoDPI variant.
    return min(candidates, key=lambda m: (abs(m['hz'] - current['hz']) >= 0.6, -m['hz']))
