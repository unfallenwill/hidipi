"""Command-line parsing and dispatch for hidipi."""
import argparse
import json
import math
from pathlib import Path
import sys
from . import autostart, backup as backups, display, errors, macos, modes as display_modes, runtime, state, virtual


def main():
    parser = argparse.ArgumentParser(description='免费 macOS HiDPI 工具：自动备份、限时预览、退出恢复。')
    parser.add_argument('--backup-dir', type=Path, default=state.backup_dir(),
                        help='备份目录（默认 ~/.config/hidpi-cli/backups）')
    sub = parser.add_subparsers(dest='command', required=True)
    listing = sub.add_parser('list', help='只读：列出显示器和 HiDPI 模式')
    listing.add_argument('--all', action='store_true', help='也显示普通 DPI 模式')
    sub.add_parser('backup', help='只备份，不修改')
    sub.add_parser('paths', help='显示用户配置、备份和日志目录')
    restore = sub.add_parser('restore', help='从指定 JSON 备份恢复')
    restore.add_argument('file', type=Path)
    enable = sub.add_parser('enable', help='备份后开启 HiDPI，退出自动恢复')
    selection = enable.add_mutually_exclusive_group()
    selection.add_argument('--display', type=int, help='list 命令中的显示器 ID；只有一台时可省略')
    selection.add_argument('--display-uuid', help='跨重启稳定的显示器 UUID')
    enable.add_argument('--size', type=display_modes.size_value, help='界面逻辑尺寸，如 1920x1080；默认保持当前界面尺寸')
    enable.add_argument('--refresh', type=float, help='指定刷新率；不支持时直接报错，不降低刷新率')
    enable.add_argument('--seconds', type=int, default=20, help='预览秒数（5–120，默认 20）')
    enable.add_argument('--keep', action='store_true', help='跳过预览倒计时，保持运行直到 Ctrl+C')
    enable.add_argument('--wait-display', type=int, default=0, help='启动时等待指定显示器就绪的秒数（0–120）')
    autostart.add_parser(sub)
    virtual.add_parser(sub)
    args = parser.parse_args()
    try:
        if args.command == 'paths':
            state.show_paths()
            return 0
        if args.command == 'autostart':
            autostart.handle(args)
            return 0
        mac = macos.Mac()
        if args.command == 'list':
            display.list_displays(mac, args.all)
        else:
            with runtime.single_instance(args.backup_dir):
                if args.command == 'virtual':
                    virtual.run(mac, args)
                elif args.command == 'backup':
                    print('备份：' + str(backups.write_backup(mac.snapshot(), args.backup_dir)))
                elif args.command == 'restore':
                    saved = backups.validate_backup(json.loads(args.file.read_text()))
                    path = backups.write_backup(mac.snapshot(), args.backup_dir)
                    print(f'恢复前的状态也已备份：{path}', flush=True)
                    mac.restore(saved)
                    print('已恢复并核验原始分辨率、刷新率、镜像与排列。')
                else:
                    if not 5 <= args.seconds <= 120:
                        raise errors.HiDPIError('--seconds 必须在 5–120 之间。')
                    if args.refresh is not None and (not math.isfinite(args.refresh) or not 0 < args.refresh <= 1000):
                        raise errors.HiDPIError('--refresh 必须是 0–1000 范围内的正数。')
                    if not 0 <= args.wait_display <= 120:
                        raise errors.HiDPIError('--wait-display 必须在 0–120 之间。')
                    if args.wait_display and not display.wait_for_display(mac, args):
                        return 0
                    display.enable_hidpi(mac, args)
        return 0
    except (errors.HiDPIError, OSError, ValueError) as exc:
        print(f'错误：{exc}', file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('\n已取消。', file=sys.stderr)
        return 130


if __name__ == '__main__':
    sys.exit(main())
