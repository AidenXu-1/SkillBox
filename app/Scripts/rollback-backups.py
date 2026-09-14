#!/usr/bin/env python3
"""Register app rollback sets; keep one per app and expire them after 7 days.

Only explicitly registered directories below this project's scratch/ are eligible.
Default cleanup is a preview; --apply permanently removes matching backup payloads.
"""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import pathlib
import plistlib
import stat
import shutil
import uuid
from contextlib import contextmanager

LIFETIME = dt.timedelta(days=7)
MARKER = ".skillbox-rollback.json"


def utc(value=None):
    if value is None:
        return dt.datetime.now(dt.timezone.utc)
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("备份时间必须包含时区")
    return parsed.astimezone(dt.timezone.utc)


def write_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


class Backups:
    def __init__(self, workspace):
        self.scratch = (pathlib.Path(workspace).resolve() / "scratch")
        self.home = self.scratch / "rollback-backups"
        self.home.mkdir(parents=True, exist_ok=True)
        self.registry = self.home / "registry.json"

    @contextmanager
    def locked(self):
        with (self.home / "registry.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def entries(self):
        return json.loads(self.registry.read_text()) if self.registry.exists() else []

    def checked_path(self, path):
        path = pathlib.Path(path).absolute()
        if path.is_symlink() or path.resolve() != path or self.scratch not in path.parents:
            raise ValueError("备份路径必须位于本项目 scratch 内，且不能是文件连接")
        if path == self.home or path in self.home.parents:
            raise ValueError("不能把备份登记表或其上层目录登记为备份")
        return path

    def digest(self, path):
        digest = hashlib.sha256()
        for item in sorted(path.rglob("*")):
            if item == path / MARKER:
                continue
            relative = str(item.relative_to(path)).encode()
            digest.update(len(relative).to_bytes(8, "big") + relative)
            if item.is_symlink():
                # Hash the link itself, never read its target. rmtree likewise
                # unlinks nested links without traversing them.
                digest.update(b"L" + os.readlink(item).encode())
            elif item.is_file():
                digest.update(b"F")
                with item.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
            else:
                digest.update(b"D")
        return digest.hexdigest()

    def integrity_digest(self, path):
        # Keep the original byte digest readable. The version prefix makes older
        # cleaners fail closed instead of silently ignoring the metadata contract.
        metadata = hashlib.sha256()
        for item in [path] + [p for p in sorted(path.rglob("*")) if p != path / MARKER]:
            info = item.lstat()
            if stat.S_ISLNK(info.st_mode):
                kind = b"L"
            elif stat.S_ISREG(info.st_mode):
                kind = b"F"
            elif stat.S_ISDIR(info.st_mode):
                kind = b"D"
            else:
                raise ValueError("备份包含不支持的文件类型，已保留")
            relative = ("" if item == path else str(item.relative_to(path))).encode()
            metadata.update(len(relative).to_bytes(8, "big") + relative + kind)
            metadata.update(stat.S_IMODE(info.st_mode).to_bytes(4, "big"))
        return "v2:" + self.digest(path) + ":" + metadata.hexdigest()

    def removal_inventory(self, path):
        items = []
        for item in [path] + sorted(path.rglob("*")):
            info = item.lstat()
            record = {"path": "" if item == path else str(item.relative_to(path)),
                      "mode": stat.S_IMODE(info.st_mode)}
            if stat.S_ISLNK(info.st_mode):
                record.update(kind="L", content=os.readlink(item))
            elif stat.S_ISREG(info.st_mode):
                digest = hashlib.sha256()
                with item.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(chunk)
                record.update(kind="F", content=digest.hexdigest())
            elif stat.S_ISDIR(info.st_mode):
                record["kind"] = "D"
            else:
                raise ValueError("备份包含不支持的文件类型，已保留")
            items.append(record)
        return items

    def checked_inventory(self, entry):
        inventory = entry.get("removalInventory")
        if not isinstance(inventory, list) or not inventory:
            raise ValueError("备份清理清单缺失，已停止清理")
        expected = {}
        for item in inventory:
            name = item.get("path")
            if (not isinstance(name, str) or name in expected or
                (name and (name.startswith("/") or any(p in ("", ".", "..") for p in name.split("/")))) or
                item.get("kind") not in ("D", "F", "L") or
                not isinstance(item.get("mode"), int) or not 0 <= item["mode"] <= 0o7777 or
                (item["kind"] != "D" and not isinstance(item.get("content"), str))):
                raise ValueError("备份清理清单异常，已停止清理")
            expected[name] = item
        if expected.get("", {}).get("kind") != "D" or expected.get(MARKER, {}).get("kind") != "F":
            raise ValueError("备份清理清单缺少根目录或登记标记，已停止清理")
        for name in expected:
            if name and expected.get(name.rpartition("/")[0], {}).get("kind") != "D":
                raise ValueError("备份清理清单目录结构异常，已停止清理")
        return expected

    def verify_remaining(self, path, entry, require_complete=False):
        expected = self.checked_inventory(entry)
        actual = {item["path"]: item for item in self.removal_inventory(path)}
        if (any(expected.get(name) != item for name, item in actual.items()) or
            (require_complete and actual != expected) or
            (MARKER not in actual and any(name for name in actual))):
            raise ValueError("备份剩余内容、权限或登记标记已变化，已保留：" + str(path))

    def remove_registered(self, path, entry):
        # The saved inventory permits already removed entries, never unknown or
        # changed survivors. Empty-directory removal refuses newly added files.
        self.verify_remaining(path, entry)
        expected = self.checked_inventory(entry)
        names = sorted((name for name in expected if name and name != MARKER),
                       key=lambda name: (-len(name.split("/")), name))
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        parent_fd = os.open(path.parent, flags)
        try:
            root_fd = os.open(path.name, flags, dir_fd=parent_fd)
            try:
                root_identity = os.fstat(root_fd)
                for name in names + [MARKER]:
                    directory_fd = os.dup(root_fd)
                    try:
                        components = name.split("/")
                        missing_parent = False
                        for component in components[:-1]:
                            try:
                                child_fd = os.open(component, flags, dir_fd=directory_fd)
                            except FileNotFoundError:
                                missing_parent = True
                                break
                            os.close(directory_fd)
                            directory_fd = child_fd
                        if missing_parent:
                            continue
                        try:
                            if expected[name]["kind"] == "D":
                                os.rmdir(components[-1], dir_fd=directory_fd)
                            else:
                                os.unlink(components[-1], dir_fd=directory_fd)
                        except FileNotFoundError:
                            pass
                    finally:
                        os.close(directory_fd)
                current_root = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
                if (current_root.st_dev, current_root.st_ino) != (root_identity.st_dev, root_identity.st_ino):
                    raise ValueError("备份目录位置已变化，已停止清理")
                os.rmdir(path.name, dir_fd=parent_fd)
            finally:
                os.close(root_fd)
        finally:
            os.close(parent_fd)

    def check_legacy_app(self, path):
        # Legacy registrations did not record permissions. They can only establish
        # a new baseline after their bytes and known App launch requirements pass;
        # this does not reconstruct historical modes for arbitrary backup files.
        for app in path.iterdir():
            if app.name != "SkillBox.previous" and not app.name.endswith(".app"):
                continue
            if not app.is_dir() or app.is_symlink():
                raise ValueError("旧应用备份结构异常，已保留")
            with (app / "Contents/Info.plist").open("rb") as stream:
                executable = plistlib.load(stream).get("CFBundleExecutable")
            if not isinstance(executable, str) or not executable or executable in (".", "..") or "/" in executable:
                raise ValueError("旧应用备份缺少有效的启动程序，已保留")
            program = app / "Contents/MacOS" / executable
            info = program.lstat()
            if not stat.S_ISREG(info.st_mode) or not os.access(program, os.X_OK):
                raise ValueError("旧应用备份的启动权限异常，已保留")

    def register(self, path, group="SkillBox", created_at=None):
        path = self.checked_path(path)
        if not path.is_dir():
            raise ValueError("找不到要登记的备份目录")
        with self.locked():
            entries = self.entries()
            existing = next((e for e in entries if e["path"] == str(path) and not e.get("removedAt")), None)
            if existing:
                return existing  # Re-registering must never restart the expiry clock.
            if any(path in pathlib.Path(e["path"]).parents or pathlib.Path(e["path"]) in path.parents
                   for e in entries if not e.get("removedAt")):
                raise ValueError("备份目录不可相互包含")
            created = utc(created_at)
            if created > utc():
                raise ValueError("备份创建时间不能在未来")
            entry = {"id": str(uuid.uuid4()), "group": group, "path": str(path),
                     "createdAt": created.isoformat(), "expiresAt": (created + LIFETIME).isoformat(),
                     "digest": self.integrity_digest(path)}
            write_json(path / MARKER, {"id": entry["id"], "group": group})
            entries.append(entry)
            write_json(self.registry, entries)
            return entry

    def clean(self, apply=False, now=None):
        now = now or utc()
        with self.locked():
            entries = self.entries()
            live = [e for e in entries if not e.get("removedAt")]
            if len({e["id"] for e in live}) != len(live):
                raise ValueError("备份登记身份重复，已停止清理")
            dates = {e["id"]: (utc(e["createdAt"]), utc(e["expiresAt"])) for e in live}
            for entry in live:
                if entry.get("removalStartedAt"):
                    utc(entry["removalStartedAt"])
                    if not entry["digest"].startswith(("v2:", "v3:")):
                        raise ValueError("备份清理状态缺少完整性登记，已停止清理")
                    if entry["digest"].startswith("v3:"):
                        self.checked_inventory(entry)
                elif entry["digest"].startswith("v3:"):
                    raise ValueError("备份清理状态异常，已停止清理")

            def checked_entry_path(entry):
                path = self.checked_path(entry["path"])
                if any(other is not entry and (path == pathlib.Path(other["path"])
                       or path in pathlib.Path(other["path"]).parents
                       or pathlib.Path(other["path"]) in path.parents) for other in live):
                    raise ValueError("备份目录不可相互包含或重复")
                return path

            # A saved intent is the only evidence that a missing set may have been
            # removed by this cleaner. Reconcile it before choosing replacements.
            recovered = []
            for entry in live:
                if entry.get("removalStartedAt") and not checked_entry_path(entry).exists():
                    entry["removedAt"] = entry["removalStartedAt"]
                    recovered.append(entry)
            if recovered and apply:
                write_json(self.registry, entries)
            live = [e for e in live if not e.get("removedAt")]
            live.sort(key=lambda e: (dates[e["id"]][0], e["id"]), reverse=True)
            latest = {}
            planned = []
            for entry in live:
                superseded = entry["group"] in latest
                latest.setdefault(entry["group"], entry)
                if not superseded and now < dates[entry["id"]][1] and not entry.get("removalStartedAt"):
                    continue
                planned.append((entry, superseded))

            def verified_path(entry, require_present=False):
                path = checked_entry_path(entry)
                upgraded = entry["digest"]
                if path.exists():
                    if entry["digest"].startswith("v3:"):
                        self.verify_remaining(path, entry, require_complete=require_present)
                        return path, upgraded
                    marker_path = path / MARKER
                    if marker_path.is_symlink() or not marker_path.is_file():
                        raise ValueError("备份登记标记异常，已保留")
                    marker = json.loads(marker_path.read_text())
                    if marker != {"id": entry["id"], "group": entry["group"]}:
                        raise ValueError("备份登记标记已变化，未自动删除：" + str(path))
                    actual = self.integrity_digest(path)
                    if entry["digest"].startswith("v2:"):
                        matches = actual == entry["digest"]
                    else:
                        matches = actual.split(":")[1] == entry["digest"]
                        if matches:
                            self.check_legacy_app(path)
                            upgraded = actual
                    if not matches:
                        raise ValueError("备份内容或权限已变化，未自动删除：" + str(path))
                elif require_present:
                    raise ValueError("最新备份已缺失，已保留上一份备份")
                return path, upgraded

            checked = {}
            for entry, superseded in planned:
                if superseded:
                    replacement = latest[entry["group"]]
                    if replacement["id"] not in checked:
                        checked[replacement["id"]] = verified_path(replacement, require_present=True)
            for entry, _ in planned:
                if entry["id"] not in checked:
                    checked[entry["id"]] = verified_path(entry)

            result = []
            if apply and planned:
                for entry in live:
                    if entry["id"] in checked:
                        entry["digest"] = checked[entry["id"]][1]
                for entry, _ in planned:
                    if checked[entry["id"]][0].exists():
                        entry.setdefault("removalStartedAt", now.isoformat())
                        if not entry["digest"].startswith("v3:"):
                            entry["removalInventory"] = self.removal_inventory(checked[entry["id"]][0])
                            entry["digest"] = "v3:" + entry["digest"][3:]
                    else:
                        entry["removedAt"] = now.isoformat()
                # Persist the whole verified plan before touching any payload.
                write_json(self.registry, entries)
            # Older sets go first. Their replacement survives any interrupted
            # earlier deletion, even when every set in the group has expired.
            for entry, superseded in reversed(planned):
                path = checked[entry["id"]][0]
                if apply and path.exists():
                    self.remove_registered(path, entry)
                if apply:
                    entry["removedAt"] = now.isoformat()
                    write_json(self.registry, entries)
                result.append({"path": str(path), "reason": "superseded" if superseded else "7 days old", "removed": apply})
            return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", default=str(pathlib.Path(__file__).resolve().parents[2]))
    sub = parser.add_subparsers(dest="command", required=True)
    register = sub.add_parser("register")
    register.add_argument("--path", required=True)
    register.add_argument("--group", default="SkillBox")
    register.add_argument("--created-at")
    create = sub.add_parser("create")
    create.add_argument("--app", required=True)
    create.add_argument("--data", required=True)
    create.add_argument("--group", default="SkillBox")
    clean = sub.add_parser("clean")
    clean.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    backups = Backups(args.workspace)
    if args.command == "register":
        result = backups.register(args.path, args.group, args.created_at)
    elif args.command == "create":
        path = backups.home / (utc().strftime("%Y%m%d-%H%M%S-") + str(uuid.uuid4()))
        path.mkdir()
        try:
            shutil.copytree(args.app, path / "SkillBox.previous", symlinks=True)
            shutil.copytree(args.data, path / "UserData", symlinks=True)
            result = backups.register(path, args.group)
        except BaseException as error:
            try:
                shutil.rmtree(path)
            except OSError as cleanup_error:
                raise RuntimeError("备份创建失败，未完成资料仍保留在：" + str(path)
                                   + "；请先检查后处理。原错误：" + str(error)) from cleanup_error
            raise
        # The installed app checks this explicit registry on launch or on request.
        # Persist discovery before cleanup: a changed old set must not hide the
        # newly registered backup from native checks. On failure, retain both sets.
        write_json(pathlib.Path(args.data) / "rollback-maintenance.json",
                   {"workspace": str(pathlib.Path(args.workspace).resolve())})
        # New backup and its native discovery entry are saved before removing old sets.
        result = {"registered": result, "cleaned": backups.clean(apply=True)}
    else:
        result = backups.clean(args.apply)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
