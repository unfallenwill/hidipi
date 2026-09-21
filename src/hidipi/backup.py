"""Validated, durable display snapshots, independent of system APIs."""
import datetime
import json
import math
import os
import tempfile
import uuid
from . import errors


def validate_backup(data):
    if isinstance(data, dict) and data.get('schema') == 2 and data.get('headless') is True and data.get('displays') == []:
        return data
    if not isinstance(data, dict) or data.get("schema") != 1:
        raise errors.HiDPIError("不支持的备份格式。")
    displays = data.get("displays")
    if not isinstance(displays, list) or not 1 <= len(displays) <= 128:
        raise errors.HiDPIError("备份显示器列表无效。")
    ids, uuids = set(), set()
    try:
        for item in displays:
            if not isinstance(item, dict):
                raise ValueError()
            if type(item["id"]) is not int or not 0 < item["id"] < 2**32:
                raise ValueError()
            if item["id"] in ids or item["uuid"] in uuids:
                raise ValueError()
            uuid.UUID(item["uuid"])
            ids.add(item["id"])
            uuids.add(item["uuid"])
            if len(item["origin"]) != 2 or any(type(n) is not int or abs(n) >= 2**31 for n in item["origin"]):
                raise ValueError()
            if type(item["mirror_of"]) is not int:
                raise ValueError()
            mode = item["mode"]
            for key in ("width", "height", "pixel_width", "pixel_height"):
                if type(mode[key]) is not int or not 0 < mode[key] <= 65536:
                    raise ValueError()
            if type(mode["mode_id"]) is not int:
                raise ValueError()
            if not isinstance(mode["hz"], (int, float)) or not math.isfinite(mode["hz"]) or not 0 <= mode["hz"] <= 1000:
                raise ValueError()
        if any(d["mirror_of"] and (d["mirror_of"] not in ids or d["mirror_of"] == d["id"]) for d in displays):
            raise ValueError()
    except (KeyError, TypeError, ValueError, AttributeError):
        raise errors.HiDPIError("备份数据不完整或数值无效；未修改显示器。") from None
    return data


def write_backup(snapshot, directory):
    validate_backup(snapshot)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    name = datetime.datetime.now().strftime("display-%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8] + '.json'
    path = directory / name
    fd, temporary = tempfile.mkstemp(prefix='.backup-', dir=str(directory))
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(snapshot, out, ensure_ascii=False, indent=2, allow_nan=False)
            out.write('\n')
            out.flush()
            os.fsync(out.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(str(directory), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        # Read back before any change to the display.
        if validate_backup(json.loads(path.read_text())) != snapshot:
            raise errors.HiDPIError("备份回读不一致；取消切换。")
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return path
