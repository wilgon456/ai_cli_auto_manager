"""Real filesystem/SQLite regressions in a disposable home; no real CLI is invoked."""
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


class CleanupSafetyTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="aicm-clean-safety-")
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)
        self.home = self.base / "home"
        self.temp = self.base / "tmp"
        self.home.mkdir()
        self.temp.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.temp),
                        CODEX_HOME=str(self.home / ".codex"),
                        AICM_HOME=str(self.home / ".manager"), AICM_NOTIFY="0",
                        AICM_WORKTREES="0", AICM_CLOCK_CHECK="0")

    def clean(self, rule):
        rules = self.base / "rules.conf"
        rules.write_text(rule + "\n", encoding="utf-8")
        return subprocess.run(
            ["/bin/bash", str(ROOT / "bin/clean_ai_leftovers.sh"),
             "--rules-file", str(rules), "--local-rules-file", str(self.base / "none")],
            env=self.env, text=True, capture_output=True, timeout=40)

    def test_parent_symlink_is_refused_under_home_and_temp(self):
        outside = self.base / "outside" / "data"
        outside.mkdir(parents=True)
        note = outside / "note.txt"
        note.write_text("keep this temporary test note", encoding="utf-8")
        old = time.time() - 3 * 86400
        os.utime(note, (old, old))
        for anchor in (self.home, self.temp):
            with self.subTest(anchor=anchor):
                alias = anchor / "alias"
                alias.symlink_to(outside.parent, target_is_directory=True)
                result = self.clean(f"escape | all | age | {alias}/data | * | 1 | | on | test")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("refused", result.stdout)
                self.assertTrue(note.exists())

    def test_missing_rule_folders_under_trusted_roots_are_allowed(self):
        for anchor in (self.home, self.temp):
            with self.subTest(anchor=anchor):
                missing = anchor / "not-created" / "data"
                result = self.clean(f"missing | all | age | {missing} | * | 1 | | on | test")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("refused", result.stdout)

    @unittest.skipUnless(shutil.which("lsof"), "lsof unavailable; cap cleanup keeps files")
    def test_open_sqlite_and_wal_survive_then_idle_database_is_removed(self):
        folder = self.home / "database"
        folder.mkdir()
        database = folder / "logs_1.sqlite"
        connection = sqlite3.connect(database)
        try:
            connection.execute("pragma journal_mode=wal")
            connection.execute("create table sample (data blob)")
            connection.execute("insert into sample values (zeroblob(2097152))")
            connection.commit()
            connection.execute("pragma wal_checkpoint(truncate)")
            connection.execute("update sample set data = zeroblob(2097152)")
            connection.commit()
            connection.execute("begin immediate")
            sidecars = [Path(str(database) + suffix) for suffix in ("-wal", "-shm")]
            self.assertTrue(all(p.exists() for p in sidecars))
            rule = f"database | all | cap | {folder} | logs_*.sqlite | 30 | 1 | on | test"
            result = self.clean(rule)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(database.exists())
            self.assertTrue(all(p.exists() for p in sidecars))
            self.assertEqual(connection.execute("select length(data) from sample").fetchone()[0], 2097152)
            connection.rollback()
        finally:
            connection.close()
        result = self.clean(rule)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(database.exists(), result.stdout)

    def test_unexpected_sqlite_sidecar_keeps_family(self):
        folder = self.home / "database"
        folder.mkdir()
        database = folder / "logs_1.sqlite"
        database.write_bytes(b"x" * 2097152)
        outside = self.base / "outside"
        outside.mkdir()
        note = outside / "note.txt"
        note.write_text("keep")
        sidecar = Path(str(database) + "-wal")
        for shape in ("directory", "link"):
            with self.subTest(shape=shape):
                if shape == "directory":
                    sidecar.mkdir()
                else:
                    sidecar.symlink_to(outside, target_is_directory=True)
                result = self.clean(f"database | all | cap | {folder} | logs_*.sqlite | 30 | 1 | on | test")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(database.exists())
                self.assertEqual(note.read_text(), "keep")
                if shape == "directory":
                    sidecar.rmdir()
                else:
                    sidecar.unlink()

    def test_recursive_rules_keep_protected_units_without_partial_deletion(self):
        for kind in ("keep-latest", "archive"):
            for protected in ("auth.json", "memory/notes.md", "secret.pem"):
                with self.subTest(kind=kind, protected=protected):
                    folder = self.home / "browsers"
                    if kind == "keep-latest":
                        unit = folder / "chromium-1000"
                        for build in (2000, 3000):
                            (folder / f"chromium-{build}").mkdir(parents=True, exist_ok=True)
                        rule = f"tree | all | keep-latest | {folder} | * | | 2 | on | test"
                    else:
                        unit = self.home / ".manager/archive/tree/20200101"
                        rule = f"tree | all | archive | {folder} | *.jsonl | 30 | 60 | off | test"
                    secret = unit / protected
                    secret.parent.mkdir(parents=True, exist_ok=True)
                    secret.write_text("keep")
                    first = unit / "first.bin"
                    first.write_text("keep whole unit")
                    result = self.clean(rule)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertTrue(secret.exists())
                    self.assertTrue(first.exists())
                    shutil.rmtree(unit)

    @unittest.skipUnless(shutil.which("lsof"), "lsof unavailable; recursive cleanup keeps files")
    def test_recursive_cleanup_keeps_open_unit_then_removes_it(self):
        folder = self.home / "browsers"
        unit = folder / "chromium-1000"
        for build in (1000, 2000, 3000):
            (folder / f"chromium-{build}").mkdir(parents=True)
        busy = unit / "busy.bin"
        busy.write_bytes(b"busy")
        first = unit / "first.bin"
        first.write_bytes(b"keep")
        rule = f"tree | all | keep-latest | {folder} | * | | 2 | on | test"
        with busy.open("rb"):
            result = self.clean(rule)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(busy.exists())
            self.assertTrue(first.exists())
        result = self.clean(rule)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(unit.exists(), result.stdout)

    def test_checker_failure_keeps_database(self):
        folder = self.home / "database"
        folder.mkdir()
        database = folder / "logs_1.sqlite"
        database.write_bytes(b"x" * 2097152)
        fake_bin = self.base / "fakebin"
        fake_bin.mkdir()
        checker = fake_bin / "lsof"
        checker.write_text("#!/bin/sh\necho failed >&2\nexit 1\n", encoding="utf-8")
        checker.chmod(0o755)
        self.env["PATH"] = str(fake_bin) + os.pathsep + self.env["PATH"]
        result = self.clean(f"database | all | cap | {folder} | logs_*.sqlite | 30 | 1 | on | test")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(database.exists())


if __name__ == "__main__":
    unittest.main()
