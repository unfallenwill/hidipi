"""Per-user LaunchAgent installation. No root, shell, or uv at login."""
import json
import argparse
import math
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

from . import cli, state

LABEL = 'local.hidpi-cli.agent'


def agent_path():
    return Path.home() / 'Library' / 'LaunchAgents' / f'{LABEL}.plist'


def service():
    return f'gui/{os.getuid()}/{LABEL}'


def launchctl(*args, checked=True):
    try:
        result = subprocess.run(['/bin/launchctl', *args], text=True,
                                capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        raise cli.HiDPIError(f'launchctl {args[0]} 超时，请运行 autostart status 检查状态。') from None
    if checked and result.returncode:
        raise cli.HiDPIError(f'launchctl {args[0]} 失败：{result.stderr.strip() or result.stdout.strip()}')
    return result


def add_parser(sub):
    parser = sub.add_parser('autostart', help='安装、查看或移除登录自启动')
    commands = parser.add_subparsers(dest='autostart_command', required=True)
    install = commands.add_parser('install', help='安装并立即在后台开启 HiDPI')
    install.add_argument('--size', type=cli.size_value, help='默认保持当前界面逻辑尺寸')
    install.add_argument('--display', type=int, help='多屏时指定显示器 ID；安装后保存其 UUID')
    install.add_argument('--refresh', type=float, help='要求指定刷新率')
    install.add_argument('--dry-run', action='store_true', help='只读预检并输出 plist，不安装')
    install.add_argument('--virtual', action='store_true', help='登录后创建虚拟 HiDPI 屏幕，不需要 HDMI 或实体屏幕')
    commands.add_parser('status', help='查看配置、launchd 状态和最近日志')
    commands.add_parser('uninstall', help='停止服务、取消自启动，并恢复安装前备份')


def make_plist(python, workdir, backup_dir, identity, mode, backup):
    refresh_args = ['--refresh', str(mode['hz'])] if mode['hz'] else []
    return dict(Label=LABEL, ProgramArguments=[str(python), '-u', '-m', 'hidpi_cli',
        '--backup-dir', str(backup_dir), 'enable', '--display-uuid', identity,
        '--size', f'{mode["width"]}x{mode["height"]}', *refresh_args,
        '--wait-display', '60', '--keep'], WorkingDirectory=str(workdir),
        RunAtLoad=True, KeepAlive=False, LimitLoadToSessionType='Aqua',
        ExitTimeOut=20, ProcessType='Interactive',
        StandardOutPath=str(workdir / 'logs' / 'autostart.log'),
        StandardErrorPath=str(workdir / 'logs' / 'autostart-error.log'),
        EnvironmentVariables={'HIDPI_INSTALL_BACKUP': str(backup)})


def make_virtual_plist(python, workdir, backup_dir, mode, backup):
    data = make_plist(python, workdir, backup_dir, None, mode, backup)
    data['ProgramArguments'] = [str(python), '-u', '-m', 'hidpi_cli',
        '--backup-dir', str(backup_dir), 'virtual', '--size', f'{mode["width"]}x{mode["height"]}',
        '--refresh', str(mode['hz']), '--keep']
    data['EnvironmentVariables']['HIDPI_MODE'] = 'virtual'
    return data


def install(args):
    path = agent_path()
    if path.exists():
        raise cli.HiDPIError(f'已存在自启动配置：{path}。修改配置请先 autostart uninstall。')
    mac = cli.Mac()
    workdir = state.config_dir()
    backup_dir = args.backup_dir.resolve()
    # Keep the venv path (do not resolve its symlink to the system interpreter).
    python = Path(sys.executable).absolute()
    with cli.single_instance(backup_dir):
        virtual_mode = getattr(args, 'virtual', False)
        if virtual_mode:
            from . import virtual
            if args.display is not None:
                raise cli.HiDPIError('--virtual 不能与 --display 一起使用。')
            size = args.size or (1920, 1080)
            refresh = args.refresh if args.refresh is not None else 60
            virtual.validate_options(argparse.Namespace(size=size, refresh=refresh, seconds=20))
            virtual.ObjC().cls('CGVirtualDisplay')
            original = virtual.capture_original(mac)
            target = {'uuid': None}
            wanted = dict(width=size[0], height=size[1], pixel_width=size[0]*2,
                          pixel_height=size[1]*2, hz=refresh)
            build = lambda backup: make_virtual_plist(python, workdir, backup_dir, wanted, backup)
        else:
            original = mac.snapshot()
            candidates = [d for d in original['displays'] if args.display is None or d['id'] == args.display]
            if len(candidates) != 1:
                raise cli.HiDPIError('请通过 --display 指定一台已连接的显示器。')
            target = candidates[0]
            if target['in_mirror_set'] or not target['mode']:
                raise cli.HiDPIError('目标显示器正在镜像或模式未就绪，无法安装自启动。')
            if args.refresh is not None and (not math.isfinite(args.refresh) or not 0 < args.refresh <= 1000):
                raise cli.HiDPIError('刷新率必须是 0–1000 范围内的正数。')
            size = args.size or (target['mode']['width'], target['mode']['height'])
            with mac.modes(target['id']) as modes:
                wanted = cli.choose_mode([mac.info(m) for m in modes], size, target['mode'], args.refresh)
            build = lambda backup: make_plist(python, workdir, backup_dir, target['uuid'], wanted, backup)
        print('登录后将启用：' + cli.describe(wanted), flush=True)
        if args.dry_run:
            data = build(backup_dir / 'INSTALL_BACKUP_CREATED_ON_INSTALL.json')
            print(plistlib.dumps(data).decode())
            return
        backup = cli.write_backup(original, backup_dir)
        print(f'安装前备份：{backup}', flush=True)
        data = build(backup)
        (workdir / 'logs').mkdir(parents=True, exist_ok=True, mode=0o700)
        settings = dict(schema=1, enabled=True, display_uuid=target['uuid'],
                        size=list(size), refresh=wanted['hz'], python=str(python),
                        backup_dir=str(backup_dir), install_backup=str(backup),
                        mode='virtual' if virtual_mode else 'physical')
        state.save_settings(settings)
        path.parent.mkdir(parents=True, exist_ok=True)
        # Refuse replacement, including a concurrently created file.
        with path.open('xb') as out:
            os.chmod(path, 0o600)
            out.write(plistlib.dumps(data))
            out.flush()
            os.fsync(out.fileno())
    # Release the display lock before launchd starts the child process.
    try:
        launchctl('enable', service())
        launchctl('bootstrap', f'gui/{os.getuid()}', str(path))
    except Exception:
        path.unlink(missing_ok=True)
        settings['enabled'] = False
        state.save_settings(settings)
        raise
    print(f'已安装并提交启动：{path}\n运行 hidpi autostart status 查看实际运行情况。', flush=True)


def read_agent(path):
    data = plistlib.loads(path.read_bytes())
    if data.get('Label') != LABEL:
        raise cli.HiDPIError('配置文件的 Label 不匹配；拒绝操作其他服务。')
    return data


def status():
    path = agent_path()
    print(f'自启动配置：{path}' if path.exists() else '未安装自启动配置。')
    result = launchctl('print', service(), checked=False)
    if result.returncode == 113:
        print('服务未加载。')
    elif result.returncode:
        raise cli.HiDPIError('无法查询 launchd：' + result.stderr.strip())
    else:
        for line in result.stdout.splitlines():
            if any(key in line for key in ('state =', 'pid =', 'last exit code =')):
                print(line.strip())
    if path.exists():
        data = read_agent(path)
        print('安装前备份：' + data['EnvironmentVariables']['HIDPI_INSTALL_BACKUP'])
        for key in ('StandardOutPath', 'StandardErrorPath'):
            log = Path(data[key])
            print(f'日志：{log}')
            if log.exists():
                # Bound memory use even after many logins.
                with log.open('rb') as stream:
                    stream.seek(max(0, log.stat().st_size - 4096))
                    lines = stream.read().decode(errors='replace').splitlines()
                for line in lines[-10:]:
                    print('  ' + line)


def uninstall(args):
    path = agent_path()
    if not path.exists():
        print('未安装自启动，无需移除。')
        return
    data = read_agent(path)
    backup = Path(data['EnvironmentVariables']['HIDPI_INSTALL_BACKUP'])
    # Recovery failure must not prevent stopping/removing the service.
    recovery_error = None
    try:
        saved = cli.validate_backup(json.loads(backup.read_text()))
    except (cli.HiDPIError, OSError, ValueError) as error:
        recovery_error = error
    result = launchctl('print', service(), checked=False)
    if result.returncode == 0:
        launchctl('bootout', service())
    elif result.returncode != 113:
        raise cli.HiDPIError('无法确定服务状态：' + result.stderr.strip())
    path.unlink()
    settings_path = state.config_dir() / 'autostart.json'
    if settings_path.exists():
        settings = json.loads(settings_path.read_text())
        settings['enabled'] = False
        state.save_settings(settings)
    print('已移除登录自启动；正在等待后台进程退出。', flush=True)
    # bootout can return before the process finishes its SIGTERM cleanup.
    deadline = time.monotonic() + 22
    while True:
        lock = cli.single_instance(args.backup_dir)
        try:
            lock.__enter__()
            break
        except cli.HiDPIError:
            if time.monotonic() >= deadline:
                raise cli.HiDPIError(f'服务停止超时。备份保留在 {backup}；请稍后手动 restore。')
            time.sleep(0.2)
    try:
        if recovery_error is not None:
            raise cli.HiDPIError(f'自启动已卸载，但无法恢复安装前设置：备份 {backup} '
                                 f'不可用（{recovery_error}）。请使用其他有效备份手动 restore。')
        mac = cli.Mac()
        virtual_mode = data['EnvironmentVariables'].get('HIDPI_MODE') == 'virtual'
        if virtual_mode:
            from . import virtual
            current = virtual.capture_original(mac)
        else:
            current = mac.snapshot()
        current_backup = cli.write_backup(current, args.backup_dir)
        print(f'恢复前状态备份：{current_backup}', flush=True)
        if virtual_mode:
            virtual.restore_connected(mac, saved)
        else:
            mac.restore(saved)
    finally:
        lock.__exit__(None, None, None)
    print(f'已恢复并核验安装前设置。所有备份保留，包括：{backup}')


def wait_for_display(mac, args):
    deadline = time.monotonic() + args.wait_display
    last_error = '显示器尚未就绪'
    with cli.stop_signals() as stopping:
        while not stopping['stop']:
            try:
                saved = mac.snapshot()
                matches = [d for d in saved['displays'] if
                    (not args.display_uuid or d['uuid'].lower() == args.display_uuid.lower()) and
                    (args.display is None or d['id'] == args.display)]
                if len(matches) == 1 and matches[0]['mode']:
                    d = matches[0]
                    with mac.modes(d['id']) as modes:
                        cli.choose_mode([mac.info(m) for m in modes], args.size or
                            (d['mode']['width'], d['mode']['height']), d['mode'], args.refresh)
                    return True
            except cli.HiDPIError as error:
                last_error = str(error)
            if time.monotonic() >= deadline:
                raise cli.HiDPIError(f'等待显示器超时：{last_error}')
            mac.pump(0.5)
    return False


def handle(args):
    if sys.platform != 'darwin':
        raise cli.HiDPIError('登录自启动仅支持 macOS。')
    if args.autostart_command == 'install':
        install(args)
    elif args.autostart_command == 'status':
        status()
    else:
        uninstall(args)
