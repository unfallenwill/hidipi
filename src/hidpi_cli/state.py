"""Stable per-user paths, independent of cwd and installation method."""
import json
import os
from pathlib import Path
import tempfile


def config_dir():
    return Path.home() / '.config' / 'hidpi-cli'


def backup_dir():
    return config_dir() / 'backups'


def load_settings():
    path = config_dir() / 'autostart.json'
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    if not isinstance(data, dict):
        raise ValueError('自启动记录必须是 JSON 对象。')
    return data


def save_settings(data):
    root = config_dir()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix='.autostart-', dir=str(root))
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, root / 'autostart.json')
        directory_fd = os.open(str(root), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def show_paths():
    root = config_dir()
    print(f'配置目录：{root}\n自启动记录：{root / "autostart.json"}\n'
          f'默认备份目录：{backup_dir()}\n日志目录：{root / "logs"}')
