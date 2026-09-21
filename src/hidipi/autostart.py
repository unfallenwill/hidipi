"""Per-user LaunchAgent installation. No root, shell, or uv at login."""
import json
import argparse
import math
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

from . import backup as backups, errors, macos, modes as display_modes, runtime, state

# Keep the installed service identity so hidipi can manage existing agents.
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
        raise errors.HiDPIError(f'launchctl {args[0]} 超时，请运行 autostart status 检查状态。') from None
    if checked and result.returncode:
        raise errors.HiDPIError(f'launchctl {args[0]} 失败：{result.stderr.strip() or result.stdout.strip()}')
    return result


def add_parser(sub):
    parser = sub.add_parser('autostart', help='安装、查看或移除登录自启动')
    commands = parser.add_subparsers(dest='autostart_command', required=True)
    install = commands.add_parser('install', help='安装并立即在后台开启 HiDPI')
    install.add_argument('--size', type=display_modes.size_value, help='默认保持当前界面逻辑尺寸')
    install.add_argument('--display', type=int, help='多屏时指定显示器 ID；安装后保存其 UUID')
    install.add_argument('--refresh', type=float, help='要求指定刷新率')
    install.add_argument('--dry-run', action='store_true', help='只读预检并输出 plist，不安装')
    install.add_argument('--virtual', action='store_true', help='登录后创建虚拟 HiDPI 屏幕，不需要 HDMI 或实体屏幕')
    commands.add_parser('status', help='查看配置、launchd 状态和最近日志')
    commands.add_parser('uninstall', help='停止服务、取消自启动，并恢复安装前备份')


def make_plist(python, workdir, backup_dir, identity, mode, backup):
    refresh_args = ['--refresh', str(mode['hz'])] if mode['hz'] else []
    return dict(Label=LABEL, ProgramArguments=[str(python), '-u', '-m', 'hidipi',
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
    data['ProgramArguments'] = [str(python), '-u', '-m', 'hidipi',
        '--backup-dir', str(backup_dir), 'virtual', '--size', f'{mode["width"]}x{mode["height"]}',
        '--refresh', str(mode['hz']), '--keep']
    data['EnvironmentVariables']['HIDPI_MODE'] = 'virtual'
    return data


def install(args):
    with runtime.autostart_lock():
        _install(args)


def write_agent(path, data):
    """Publish a complete plist without replacing an existing installation."""
    payload = plistlib.dumps(data)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.hidipi-agent-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(payload)
            out.flush()
            os.fsync(out.fileno())
        os.link(temporary, path)
    finally:
        os.unlink(temporary)


def start_agent(path, settings):
    # Once launchctl is invoked, failure/timeout does not prove the child never
    # started. Keep both the plist and recovery record so uninstall can stop it.
    try:
        launchctl('enable', service())
        launchctl('bootstrap', f'gui/{os.getuid()}', str(path))
    except (errors.HiDPIError, OSError) as error:
        raise errors.HiDPIError(f'提交启动未确认完成：{error}。配置和备份已保留；'
                               '请运行 autostart status，或 autostart uninstall 后重试。') from error
    state.save_settings(dict(settings, phase='submitted'))


def _install(args):
    path = agent_path()
    if path.exists():
        raise errors.HiDPIError(f'已存在自启动配置：{path}。修改配置请先 autostart uninstall。')
    if state.load_settings().get('phase') == 'restore_pending':
        raise errors.HiDPIError('上次卸载尚未完成恢复，请先重试 autostart uninstall。')
    mac = macos.Mac()
    workdir = state.config_dir()
    backup_dir = args.backup_dir.resolve()
    # Keep the venv path (do not resolve its symlink to the system interpreter).
    python = Path(sys.executable).absolute()
    with runtime.single_instance(backup_dir):
        virtual_mode = getattr(args, 'virtual', False)
        if virtual_mode:
            from . import virtual
            if args.display is not None:
                raise errors.HiDPIError('--virtual 不能与 --display 一起使用。')
            size = args.size or (1920, 1080)
            refresh = args.refresh if args.refresh is not None else 60
            virtual.validate_options(argparse.Namespace(size=size, refresh=refresh, seconds=20))
            macos.ObjC().cls('CGVirtualDisplay')
            original = virtual.capture_original(mac)
            target = {'uuid': None}
            wanted = dict(width=size[0], height=size[1], pixel_width=size[0]*2,
                          pixel_height=size[1]*2, hz=refresh)
            build = lambda backup: make_virtual_plist(python, workdir, backup_dir, wanted, backup)
        else:
            original = mac.snapshot()
            candidates = [d for d in original['displays'] if args.display is None or d['id'] == args.display]
            if len(candidates) != 1:
                raise errors.HiDPIError('请通过 --display 指定一台已连接的显示器。')
            target = candidates[0]
            if target['in_mirror_set'] or not target['mode']:
                raise errors.HiDPIError('目标显示器正在镜像或模式未就绪，无法安装自启动。')
            if args.refresh is not None and (not math.isfinite(args.refresh) or not 0 < args.refresh <= 1000):
                raise errors.HiDPIError('刷新率必须是 0–1000 范围内的正数。')
            size = args.size or (target['mode']['width'], target['mode']['height'])
            with mac.modes(target['id']) as modes:
                wanted = display_modes.choose_mode([mac.info(m) for m in modes], size, target['mode'], args.refresh)
            build = lambda backup: make_plist(python, workdir, backup_dir, target['uuid'], wanted, backup)
        print('登录后将启用：' + display_modes.describe(wanted), flush=True)
        if args.dry_run:
            data = build(backup_dir / 'INSTALL_BACKUP_CREATED_ON_INSTALL.json')
            print(plistlib.dumps(data).decode())
            return
        backup = backups.write_backup(original, backup_dir)
        print(f'安装前备份：{backup}', flush=True)
        data = build(backup)
        (workdir / 'logs').mkdir(parents=True, exist_ok=True, mode=0o700)
        settings = dict(schema=1, enabled=True, phase='start_pending', display_uuid=target['uuid'],
                        size=list(size), refresh=wanted['hz'], python=str(python),
                        backup_dir=str(backup_dir), install_backup=str(backup),
                        mode='virtual' if virtual_mode else 'physical')
        state.save_settings(settings)
        write_agent(path, data)
    # The lifecycle lock stays held; only release the display lock for the child.
    start_agent(path, settings)
    print(f'已安装并提交启动：{path}\n运行 hidipi autostart status 查看实际运行情况。', flush=True)


def read_agent(path):
    data = plistlib.loads(path.read_bytes())
    if data.get('Label') != LABEL:
        raise errors.HiDPIError('配置文件的 Label 不匹配；拒绝操作其他服务。')
    return data


def status():
    path = agent_path()
    print(f'自启动配置：{path}' if path.exists() else '未安装自启动配置。')
    try:
        record = state.load_settings()
        if record.get('phase'):
            print('最近操作阶段：' + record['phase'])
        if record.get('phase') == 'restore_pending':
            print('恢复未完成，请重试 autostart uninstall；备份：' + record['install_backup'])
    except (OSError, ValueError, KeyError) as error:
        print(f'无法读取自启动记录：{error}', file=sys.stderr)
    result = launchctl('print', service(), checked=False)
    if result.returncode == 113:
        print('服务未加载。')
    elif result.returncode:
        raise errors.HiDPIError('无法查询 launchd：' + result.stderr.strip())
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
    with runtime.autostart_lock():
        _uninstall(args)


def recovery_record(path):
    """Prefer the installed plist; resume from the journal after its removal."""
    if path.exists():
        data = read_agent(path)
        environment = data.get('EnvironmentVariables', {})
        backup = environment.get('HIDPI_INSTALL_BACKUP')
        if not isinstance(backup, str) or not backup:
            raise errors.HiDPIError('启动项缺少安装前备份路径；保留配置供检查。')
        # Reconstruct essential fields even if the optional settings JSON broke.
        try:
            record = state.load_settings()
        except (OSError, ValueError):
            record = {}
        return dict(record, schema=1, enabled=True, phase='stop_pending',
                    install_backup=backup,
                    mode=environment.get('HIDPI_MODE', 'physical'))
    record = state.load_settings()
    if record.get('phase') == 'restore_pending':
        if not isinstance(record.get('install_backup'), str) or not record['install_backup']:
            raise errors.HiDPIError('待恢复记录缺少备份路径。')
        return record
    return None


def stop_agent():
    result = launchctl('print', service(), checked=False)
    if result.returncode == 0:
        # On failure retain the plist and journal. A retry queries launchd again,
        # including when bootout actually completed but its caller timed out.
        launchctl('bootout', service())
    elif result.returncode != 113:
        raise errors.HiDPIError('无法确定服务状态：' + result.stderr.strip())


def restore_installation(record, directory):
    backup = Path(record['install_backup'])
    try:
        saved = backups.validate_backup(json.loads(backup.read_text()))
    except (errors.HiDPIError, OSError, ValueError) as error:
        raise errors.HiDPIError(f'自启动已卸载，但无法恢复安装前设置：备份 {backup} '
                               f'不可用（{error}）。修复备份后可重试 autostart uninstall，'
                               '或使用其他有效备份手动 restore。') from error
    mac = macos.Mac()
    if record['mode'] == 'virtual':
        from . import virtual
        current = virtual.capture_original(mac)
    else:
        current = mac.snapshot()
    current_backup = backups.write_backup(current, directory)
    print(f'恢复前状态备份：{current_backup}', flush=True)
    if record['mode'] == 'virtual':
        virtual.restore_connected(mac, saved)
    else:
        mac.restore(saved)


def _uninstall(args):
    path = agent_path()
    record = recovery_record(path)
    if record is None:
        print('未安装自启动，无需移除。')
        return
    # Journal before external mutations. Preserve it until restoration succeeds.
    state.save_settings(record)
    stop_agent()
    record = dict(record, enabled=False, phase='restore_pending')
    state.save_settings(record)
    path.unlink(missing_ok=True)
    print('已移除登录自启动；正在等待后台进程退出。', flush=True)
    try:
        with runtime.single_instance(args.backup_dir, timeout=22):
            restore_installation(record, args.backup_dir)
    except (errors.HiDPIError, OSError, ValueError) as error:
        raise errors.HiDPIError(f'{error}\n恢复记录已保留，可重试 autostart uninstall。'
                               f'备份：{record["install_backup"]}') from error
    state.save_settings(dict(record, phase='uninstalled'))
    print(f'已恢复并核验安装前设置。所有备份保留，包括：{record["install_backup"]}')



def handle(args):
    if sys.platform != 'darwin':
        raise errors.HiDPIError('登录自启动仅支持 macOS。')
    if args.autostart_command == 'install':
        install(args)
    elif args.autostart_command == 'status':
        status()
    else:
        uninstall(args)
