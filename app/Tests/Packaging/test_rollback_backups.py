import datetime as dt
import importlib.util
import pathlib
import os
import plistlib
import json
import shutil
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "Scripts/rollback-backups.py"
spec = importlib.util.spec_from_file_location("backups", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.backups = module.Backups(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def payload(self, name):
        path = self.root / "scratch" / name
        path.mkdir()
        (path / "old-app").write_text("old version")
        return path

    def test_only_one_set_is_kept(self):
        old, new = self.payload("old"), self.payload("new")
        now = module.utc()
        self.backups.register(old, created_at=(now - dt.timedelta(days=1)).isoformat())
        self.backups.register(new)
        self.assertEqual(len(self.backups.clean()), 1)
        self.assertTrue(old.exists())
        self.backups.clean(apply=True)
        self.assertFalse(old.exists())
        self.assertTrue(new.exists())

    def test_seven_days_and_no_clock_reset_on_registration(self):
        path = self.payload("old")
        created = module.utc() - dt.timedelta(days=6)
        first = self.backups.register(path, created_at=created.isoformat())
        self.assertEqual(first, self.backups.register(path))
        self.assertEqual(self.backups.clean(apply=True, now=created + module.LIFETIME - dt.timedelta(seconds=1)), [])
        self.backups.clean(apply=True, now=created + module.LIFETIME)
        self.assertFalse(path.exists())

    def test_changed_backup_is_preserved(self):
        path = self.payload("changed")
        self.backups.register(path, created_at=(module.utc() - dt.timedelta(days=8)).isoformat())
        (path / "new-user-file").write_text("keep this")
        with self.assertRaises(ValueError):
            self.backups.clean(apply=True)
        self.assertTrue(path.exists())

    def test_unregistered_and_outside_paths_are_protected(self):
        original = self.root / "original"
        original.mkdir()
        with self.assertRaises(ValueError):
            self.backups.register(original)
        unknown = self.payload("not-registered")
        self.backups.clean(apply=True, now=module.utc() + dt.timedelta(days=99))
        self.assertTrue(unknown.exists())

    def test_symlink_cannot_escape_to_original(self):
        original = self.root / "original"
        original.mkdir()
        link = self.root / "scratch" / "linked-backup"
        link.symlink_to(original)
        with self.assertRaises(ValueError):
            self.backups.register(link)
        self.assertTrue(original.exists())

    def test_nested_link_is_removed_without_touching_original(self):
        original = self.root / "original"
        original.mkdir()
        (original / "keep").write_text("current content")
        backup = self.payload("old-with-link")
        (backup / "link").symlink_to(original)
        self.backups.register(backup, created_at=(module.utc() - dt.timedelta(days=8)).isoformat())
        self.backups.clean(apply=True)
        self.assertEqual((original / "keep").read_text(), "current content")

    def test_bad_latest_never_removes_complete_previous(self):
        for damage in ("changed", "missing", "marker"):
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as temporary:
                backups = module.Backups(pathlib.Path(temporary).resolve())
                old, new = backups.scratch / "old", backups.scratch / "new"
                for path in (old, new):
                    path.mkdir()
                    (path / "old-app").write_text("old version")
                backups.register(old, created_at=(module.utc() - dt.timedelta(days=1)).isoformat())
                backups.register(new)
                if damage == "missing":
                    shutil.rmtree(new)
                elif damage == "marker":
                    (new / module.MARKER).unlink()
                else:
                    (new / "old-app").write_text("corrupt")
                for apply in (False, True):
                    with self.assertRaises((ValueError, OSError)):
                        backups.clean(apply=apply)
                    self.assertTrue(old.exists())

    def test_existing_mixed_timezone_registry_keeps_actual_latest(self):
        old, new = self.payload("old"), self.payload("new")
        now = module.utc()
        self.backups.register(old, created_at=(now - dt.timedelta(hours=2)).isoformat())
        self.backups.register(new, created_at=(now - dt.timedelta(hours=1)).isoformat())
        entries = self.backups.entries()
        entries[0]["createdAt"] = (now - dt.timedelta(hours=2)).astimezone(dt.timezone(dt.timedelta(hours=8))).isoformat()
        module.write_json(self.backups.registry, entries)
        self.assertEqual(self.backups.clean()[0]["path"], str(old))
        self.backups.clean(apply=True)
        self.assertFalse(old.exists())
        self.assertTrue(new.exists())

    def test_changed_executable_permissions_preserve_complete_previous(self):
        old, new = self.payload("old"), self.payload("new")
        (new / "old-app").chmod(0o755)
        self.backups.register(old, created_at=(module.utc() - dt.timedelta(days=1)).isoformat())
        self.backups.register(new)
        (new / "old-app").chmod(0o644)
        with self.assertRaises(ValueError):
            self.backups.clean(apply=True)
        self.assertTrue(old.exists())
        self.assertTrue(new.exists())

    def test_special_file_cannot_replace_a_registered_empty_directory(self):
        old, new = self.payload("old"), self.payload("new")
        (new / "empty").mkdir()
        self.backups.register(old, created_at=(module.utc() - dt.timedelta(days=1)).isoformat())
        self.backups.register(new)
        (new / "empty").rmdir()
        os.mkfifo(new / "empty")
        with self.assertRaises(ValueError):
            self.backups.clean(apply=True)
        self.assertTrue(old.exists())

    def test_plan_write_failure_removes_nothing(self):
        old, new = self.payload("old"), self.payload("new")
        for days, path in ((9, old), (8, new)):
            self.backups.register(path, created_at=(module.utc() - dt.timedelta(days=days)).isoformat())
        with patch.object(module, "write_json", side_effect=OSError("cannot save plan")):
            with self.assertRaises(OSError):
                self.backups.clean(apply=True)
        self.assertTrue(old.exists())
        self.assertTrue(new.exists())

    def test_post_removal_registry_failure_resumes_without_missing_replacement_deadlock(self):
        old, new = self.payload("old"), self.payload("new")
        for days, path in ((9, old), (8, new)):
            self.backups.register(path, created_at=(module.utc() - dt.timedelta(days=days)).isoformat())
        real_write = module.write_json
        def fail_completion(path, entries):
            if path == self.backups.registry and any(e.get("removedAt") for e in entries):
                raise OSError("cannot save completion")
            real_write(path, entries)
        with patch.object(module, "write_json", side_effect=fail_completion):
            with self.assertRaises(OSError):
                self.backups.clean(apply=True)
        self.backups.clean(apply=True)
        self.assertFalse(old.exists())
        self.assertFalse(new.exists())
        self.assertTrue(all(e.get("removedAt") for e in self.backups.entries()))
        self.assertEqual(self.backups.clean(apply=True), [])

    def test_pending_backup_is_still_checked_for_payload_marker_permissions_and_links(self):
        for damage in ("payload", "marker", "permissions", "link"):
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as temporary:
                backups = module.Backups(pathlib.Path(temporary).resolve())
                old, new = backups.scratch / "old", backups.scratch / "new"
                for path in (old, new):
                    path.mkdir()
                    (path / "content").write_text("complete backup")
                backups.register(old, created_at=(module.utc() - dt.timedelta(days=1)).isoformat())
                backups.register(new)
                with patch.object(module.Backups, "remove_registered", side_effect=OSError("interrupted before removal")):
                    with self.assertRaises(OSError):
                        backups.clean(apply=True)
                self.assertTrue(backups.entries()[0].get("removalStartedAt"))
                if damage == "payload":
                    (old / "content").write_text("user changed backup")
                elif damage == "marker":
                    (old / module.MARKER).unlink()
                elif damage == "permissions":
                    (old / "content").chmod(0o600)
                else:
                    moved = backups.scratch / "moved"
                    old.rename(moved)
                    old.symlink_to(moved)
                with self.assertRaises((ValueError, OSError)):
                    backups.clean(apply=True)
                self.assertTrue(old.exists())
                self.assertTrue(new.exists())
                self.assertFalse(any(e.get("removedAt") for e in backups.entries()))

    def test_pending_old_still_needs_its_complete_replacement(self):
        old, new = self.payload("old"), self.payload("new")
        self.backups.register(old, created_at=(module.utc() - dt.timedelta(days=1)).isoformat())
        self.backups.register(new)
        with patch.object(module.Backups, "remove_registered", side_effect=OSError("interrupted before removal")):
            with self.assertRaises(OSError):
                self.backups.clean(apply=True)
        shutil.rmtree(new)
        with self.assertRaises(ValueError):
            self.backups.clean(apply=True)
        self.assertTrue(old.exists())

    def test_missing_pending_latest_can_finish_its_saved_removal(self):
        backup = self.payload("expired")
        self.backups.register(backup, created_at=(module.utc() - dt.timedelta(days=8)).isoformat())
        real_remove = self.backups.remove_registered
        def remove_then_interrupt(path, entry):
            real_remove(path, entry)
            raise OSError("process interrupted after deletion")
        with patch.object(self.backups, "remove_registered", side_effect=remove_then_interrupt):
            with self.assertRaises(OSError):
                self.backups.clean(apply=True)
        self.assertFalse(backup.exists())
        self.assertIsNone(self.backups.entries()[0].get("removedAt"))
        self.assertEqual(self.backups.clean(apply=True), [])
        self.assertTrue(self.backups.entries()[0].get("removedAt"))

    def test_legacy_registration_keeps_dates_and_establishes_versioned_metadata(self):
        old, new = self.payload("old"), self.payload("new")
        self.backups.register(old, created_at=(module.utc() - dt.timedelta(days=1)).isoformat())
        self.backups.register(new)
        entries = self.backups.entries()
        for entry in entries:
            entry["digest"] = self.backups.digest(pathlib.Path(entry["path"]))
        before_dates = [(e["createdAt"], e["expiresAt"]) for e in entries]
        module.write_json(self.backups.registry, entries)
        self.backups.clean(apply=True)
        after = self.backups.entries()
        self.assertEqual([(e["createdAt"], e["expiresAt"]) for e in after], before_dates)
        self.assertTrue(after[0]["digest"].startswith("v3:"))
        self.assertTrue(after[1]["digest"].startswith("v2:"))
        self.assertNotEqual(after[1]["digest"], self.backups.digest(new))
        self.assertTrue(new.exists())

    def test_legacy_app_without_execute_permissions_is_not_blessed_as_a_replacement(self):
        old, new = self.payload("old"), self.payload("new")
        app = new / "SkillBox.previous" / "Contents"
        (app / "MacOS").mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "SkillBox"}))
        executable = app / "MacOS" / "SkillBox"
        executable.write_text("executable bytes")
        executable.chmod(0o755)
        self.backups.register(old, created_at=(module.utc() - dt.timedelta(days=1)).isoformat())
        self.backups.register(new)
        entries = self.backups.entries()
        entries[1]["digest"] = self.backups.digest(new)
        module.write_json(self.backups.registry, entries)
        for mode in (0o644, 0o655):
            with self.subTest(mode=oct(mode)):
                executable.chmod(mode)
                self.assertFalse(os.access(executable, os.X_OK))
                with self.assertRaises(ValueError):
                    self.backups.clean(apply=True)
                self.assertTrue(old.exists())
                self.assertFalse(self.backups.entries()[1]["digest"].startswith("v2:"))

    def test_no_payload_scan_when_nothing_is_due(self):
        backup = self.payload("latest")
        self.backups.register(backup)
        with patch.object(self.backups, "digest", side_effect=AssertionError("unexpected payload scan")):
            self.assertEqual(self.backups.clean(apply=True), [])

    @unittest.skipUnless(hasattr(os, "chflags"), "requires macOS file locks")
    def test_partial_removal_resumes_after_unlock_and_restart(self):
        backup = self.payload("partial")
        locked = backup / "zz-locked"
        locked.write_text("remaining backup")
        os.chflags(locked, stat.UF_IMMUTABLE)
        try:
            self.backups.register(backup, created_at=(module.utc() - dt.timedelta(days=8)).isoformat())
            with self.assertRaises(OSError):
                self.backups.clean(apply=True)
        finally:
            os.chflags(locked, 0)
        self.assertTrue(locked.exists())
        module.Backups(self.root).clean(apply=True)
        self.assertFalse(backup.exists())
        self.assertEqual(module.Backups(self.root).clean(apply=True), [])

    def test_partial_inventory_rejects_changed_survivors_and_new_entries(self):
        for damage in ("content", "permission", "type", "link", "added", "root"):
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as temporary:
                backups = module.Backups(pathlib.Path(temporary).resolve())
                backup = backups.scratch / "partial"
                backup.mkdir()
                first, survivor = backup / "first", backup / "survivor"
                first.write_text("old content")
                survivor.write_text("remaining content")
                survivor.chmod(0o644)
                backups.register(backup, created_at=(module.utc() - dt.timedelta(days=8)).isoformat())
                with patch.object(backups, "remove_registered", side_effect=OSError("interrupted")):
                    with self.assertRaises(OSError):
                        backups.clean(apply=True)
                first.unlink()  # A process stopped after deleting one registered item.
                if damage == "content": survivor.write_text("changed")
                elif damage == "permission": survivor.chmod(0o600)
                elif damage == "type":
                    survivor.unlink()
                    survivor.mkdir()
                elif damage == "link":
                    survivor.unlink()
                    survivor.symlink_to(backups.registry)
                elif damage == "added": (backup / "unregistered").write_text("keep me")
                else: backup.chmod(0o700)
                with self.assertRaises(ValueError):
                    module.Backups(backups.scratch.parent).clean(apply=True)
                self.assertTrue(backup.exists())
                self.assertTrue(os.path.lexists(survivor))
                self.assertIsNone(backups.entries()[0].get("removedAt"))

    def test_legacy_pending_partial_state_without_inventory_is_preserved(self):
        backup = self.payload("legacy-partial")
        entry = self.backups.register(backup, created_at=(module.utc() - dt.timedelta(days=8)).isoformat())
        entry["removalStartedAt"] = module.utc().isoformat()
        module.write_json(self.backups.registry, [entry])
        (backup / "old-app").unlink()
        with self.assertRaises(ValueError):
            self.backups.clean(apply=True)
        self.assertTrue(backup.exists())

    def test_intact_v2_pending_upgrades_without_extending_deadline(self):
        backup = self.payload("legacy-pending")
        entry = self.backups.register(backup, created_at=(module.utc() - dt.timedelta(days=8)).isoformat())
        expiry = entry["expiresAt"]
        entry["removalStartedAt"] = module.utc().isoformat()
        module.write_json(self.backups.registry, [entry])
        self.backups.clean(apply=True)
        self.assertFalse(backup.exists())
        after = self.backups.entries()[0]
        self.assertEqual(after["expiresAt"], expiry)
        self.assertTrue(after["removedAt"])

    def test_v3_pending_without_inventory_fails_closed(self):
        backup = self.payload("invalid-plan")
        entry = self.backups.register(backup, created_at=(module.utc() - dt.timedelta(days=8)).isoformat())
        entry["removalStartedAt"] = module.utc().isoformat()
        entry["digest"] = "v3:" + entry["digest"][3:]
        module.write_json(self.backups.registry, [entry])
        with self.assertRaises(ValueError):
            self.backups.clean(apply=True)
        self.assertTrue(backup.exists())

    @unittest.skipUnless(hasattr(os, "chflags"), "requires macOS file locks")
    def test_create_failure_reports_undeletable_partial_path(self):
        args, data = self.create_arguments()
        app = self.root / "App"
        locked = app / "executable"
        os.chflags(locked, stat.UF_IMMUTABLE)
        shutil.rmtree(data)
        try:
            with patch.object(sys, "argv", args), self.assertRaises(RuntimeError) as caught:
                module.main()
            leftovers = [p for p in self.backups.home.iterdir() if p.is_dir()]
            self.assertEqual(len(leftovers), 1)
            self.assertIn(str(leftovers[0]), str(caught.exception))
            self.assertEqual(self.backups.entries(), [])
        finally:
            os.chflags(locked, 0)
            for item in self.backups.home.rglob("*"):
                os.chflags(item, 0)

    def test_replaced_parent_link_cannot_redirect_stepwise_deletion(self):
        backup = self.payload("parent-link")
        folder = backup / "folder"
        folder.mkdir()
        (folder / "file").write_text("backup bytes")
        outside = self.root / "outside"
        outside.mkdir()
        protected = outside / "file"
        protected.write_text("user original")
        self.backups.register(backup, created_at=(module.utc() - dt.timedelta(days=8)).isoformat())
        real_open = os.open
        redirected = False
        def replace_parent(path, flags, *args, **kwargs):
            nonlocal redirected
            if path == "folder" and kwargs.get("dir_fd") is not None and not redirected:
                redirected = True
                folder.rename(backup / "moved-folder")
                folder.symlink_to(outside)
            return real_open(path, flags, *args, **kwargs)
        with patch.object(module.os, "open", side_effect=replace_parent), self.assertRaises(OSError):
            self.backups.clean(apply=True)
        self.assertTrue(redirected)
        self.assertEqual(protected.read_text(), "user original")
        self.assertTrue(backup.exists())

    def create_arguments(self):
        app, data = self.root / "App", self.root / "Data"
        app.mkdir()
        data.mkdir()
        (app / "executable").write_text("current app")
        (data / "records.json").write_text("user records")
        return [str(SCRIPT), "--workspace", str(self.root), "create", "--app", str(app), "--data", str(data)], data

    def test_create_cleanup_failure_still_installs_native_registration(self):
        old = self.payload("old")
        self.backups.register(old, created_at=(module.utc() - dt.timedelta(days=1)).isoformat())
        (old / "old-app").write_text("externally changed")
        args, data = self.create_arguments()
        with patch.object(sys, "argv", args), self.assertRaises(ValueError):
            module.main()
        config = json.loads((data / "rollback-maintenance.json").read_text())
        self.assertEqual(config["workspace"], str(self.root))
        live = [e for e in self.backups.entries() if not e.get("removedAt")]
        self.assertEqual(len(live), 2)
        self.assertTrue(all(pathlib.Path(e["path"]).exists() for e in live))

    def test_create_config_write_failure_preserves_both_registered_backups(self):
        old = self.payload("old")
        self.backups.register(old, created_at=(module.utc() - dt.timedelta(days=1)).isoformat())
        args, data = self.create_arguments()
        write_json = module.write_json
        def fail_config(path, value):
            if path == data / "rollback-maintenance.json":
                raise OSError("simulated configuration write failure")
            write_json(path, value)
        with patch.object(sys, "argv", args), patch.object(module, "write_json", side_effect=fail_config), self.assertRaises(OSError):
            module.main()
        live = [e for e in self.backups.entries() if not e.get("removedAt")]
        self.assertEqual(len(live), 2)
        self.assertTrue(all(pathlib.Path(e["path"]).exists() for e in live))
        self.assertTrue(old.exists())

    def test_create_registry_write_failure_keeps_previous_and_removes_partial_set(self):
        old = self.payload("old")
        self.backups.register(old)
        before = self.backups.registry.read_bytes()
        args, data = self.create_arguments()
        write_json = module.write_json
        def fail_registry(path, value):
            if path == self.backups.registry:
                raise OSError("simulated registry write failure")
            write_json(path, value)
        with patch.object(sys, "argv", args), patch.object(module, "write_json", side_effect=fail_registry), self.assertRaises(OSError):
            module.main()
        self.assertEqual(self.backups.registry.read_bytes(), before)
        self.assertTrue(old.exists())
        self.assertFalse((data / "rollback-maintenance.json").exists())
        self.assertEqual([p for p in self.backups.home.iterdir() if p.is_dir()], [])


if __name__ == "__main__":
    unittest.main()
