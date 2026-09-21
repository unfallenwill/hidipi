"""Physical display workflows, independent of CLI parsing."""
import sys
import time
from . import backup as backups, errors, modes as display_modes, runtime


def enable_hidpi(mac, args):
    original = mac.snapshot()
    if getattr(args, 'display_uuid', None):
        target = next((d for d in original['displays'] if
                       d['uuid'].lower() == args.display_uuid.lower()), None)
        if not target:
            raise errors.HiDPIError('指定 UUID 的显示器未连接。')
    elif args.display is None:
        if len(original['displays']) != 1:
            raise errors.HiDPIError('检测到多台显示器，请通过 --display 指定 list 中的 ID。')
        target = original['displays'][0]
    else:
        target = next((d for d in original['displays'] if d['id'] == args.display), None)
        if not target:
            raise errors.HiDPIError('指定显示器未连接。')
    if target['in_mirror_set']:
        raise errors.HiDPIError('目标显示器正在镜像。请先在系统设置中解除镜像，再切换 HiDPI。')
    if not target['mode']:
        raise errors.HiDPIError('无法读取原始模式，不能安全备份；取消操作。')
    display = target['id']
    size = args.size or (target['mode']['width'], target['mode']['height'])
    with mac.modes(display) as pointers:
        wanted = display_modes.choose_mode([mac.info(p) for p in pointers], size, target['mode'], args.refresh)
    print('原始：' + display_modes.describe(target['mode']))
    print('目标：' + display_modes.describe(wanted))
    if display_modes.mode_matches(target['mode'], wanted):
        print('已处于指定 HiDPI 模式，无需修改。')
        return
    if abs(wanted['hz'] - target['mode']['hz']) >= 0.6:
        print(f'注意：刷新率将从 {target["mode"]["hz"]:g} Hz 变为 {wanted["hz"]:g} Hz。')
    backup = backups.write_backup(original, args.backup_dir)
    print(f'已备份并回读核验：{backup.resolve()}', flush=True)
    print(f'独立恢复命令：hidipi restore {backup.resolve()}', flush=True)
    # Install handlers before modifying anything. Signals set a flag instead
    # of interrupting a CoreGraphics transaction or the finally restoration.
    with runtime.stop_signals() as stopping:
        try:
            mac.set_mode(display, wanted)
            mac.wait_until(lambda: display_modes.mode_matches(mac.current(display), wanted),
                           '系统未切换到指定 HiDPI 模式，正在恢复', 5)
            print('已核验：' + display_modes.describe(mac.current(display)), flush=True)
            runtime.preview(mac, display, wanted, args.seconds, args.keep, stopping)
        finally:
            print('\n正在恢复原设置……', flush=True)
            try:
                mac.restore(original)
            except Exception as error:
                print(f'自动恢复未完成：{error}\n备份保留在：{backup.resolve()}\n'
                      f'请重新连接原显示器后运行：hidipi restore {backup.resolve()}', file=sys.stderr)
                raise
            print('已恢复并核验原始分辨率、刷新率、镜像与排列。', flush=True)


def list_displays(mac, all_modes=False):
    snapshot = mac.snapshot()
    for display in snapshot["displays"]:
        did = display['id']
        print(f'显示器 {did}  UUID={display["uuid"]}  '
              f'{"主屏" if display["main"] else "副屏"}  '
              f'vendor={display["vendor"]} model={display["model"]}')
        print('  当前：' + display_modes.describe(display['mode']))
        with mac.modes(did) as pointers:
            modes = [mac.info(p) for p in pointers]
        seen = set()
        for mode in sorted(modes, key=lambda m: (m['width'], m['height'], m['hz'], m['pixel_width'])):
            signature = tuple(mode[k] for k in ('width', 'height', 'pixel_width', 'pixel_height', 'hz'))
            if mode['usable'] and signature not in seen and (all_modes or display_modes.is_hidpi(mode)):
                print('    ' + display_modes.describe(mode))
                seen.add(signature)
        if not seen:
            if display['vendor'] == 0xF0F0:
                print('  HiDPI Virtual Display：虚拟屏幕按创建参数运行，无可切换模式列表。')
            else:
                print('  系统未提供可用的 HiDPI 模式；本工具不会伪造不支持的模式。')


def wait_for_display(mac, args):
    deadline = time.monotonic() + args.wait_display
    last_error = '显示器尚未就绪'
    with runtime.stop_signals() as stopping:
        while not stopping['stop']:
            try:
                saved = mac.snapshot()
                matches = [d for d in saved['displays'] if
                    (not args.display_uuid or d['uuid'].lower() == args.display_uuid.lower()) and
                    (args.display is None or d['id'] == args.display)]
                if len(matches) == 1 and matches[0]['mode']:
                    d = matches[0]
                    with mac.modes(d['id']) as modes:
                        display_modes.choose_mode([mac.info(m) for m in modes], args.size or
                            (d['mode']['width'], d['mode']['height']), d['mode'], args.refresh)
                    return True
            except errors.HiDPIError as error:
                last_error = str(error)
            if time.monotonic() >= deadline:
                raise errors.HiDPIError(f'等待显示器超时：{last_error}')
            mac.pump(0.5)
    return False
