"""Real filesystem/SQLite regressions in a disposable home; no real CLI is invoked."""
import json
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

    def own_home(self):
        """Marks AICM_HOME as the tool's own (an installed user's home). The archive-link tests need
        this: an unmarked home that already holds a linked archive folder is now refused before the
        cleanup starts, which would no longer reach the per-destination link checks under test."""
        manager = self.home / ".manager"
        manager.mkdir(parents=True, exist_ok=True)
        (manager / ".aicm-home").write_text("AI CLI Auto Manager home (logs, state, archive, installed copy)\n")

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

    # --- Date rules (age, age-files) and SQLite families -------------------------------------

    def clean_json(self, rule):
        rules = self.base / "rules.conf"
        rules.write_text(rule + "\n", encoding="utf-8")
        result = subprocess.run(
            ["/bin/bash", str(ROOT / "bin/clean_ai_leftovers.sh"), "--json",
             "--rules-file", str(rules), "--local-rules-file", str(self.base / "none")],
            env=self.env, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)["rules"][0], result

    @staticmethod
    def age(*paths, days=10):
        stamp = time.time() - days * 86400
        for p in paths:
            os.utime(p, (stamp, stamp))

    def family(self, folder, name="state.sqlite", suffixes=("", "-wal", "-shm")):
        folder.mkdir(parents=True, exist_ok=True)
        files = [folder / (name + s) for s in suffixes]
        for f in files:
            f.write_bytes(b"x" * 64)
        return files

    def without_lsof(self):
        """PATH with every tool of the current PATH except lsof (the script finds the rest as usual)."""
        sandbox = self.base / "no-lsof-bin"
        sandbox.mkdir()
        for entry in self.env["PATH"].split(os.pathsep):
            if not entry or not os.path.isdir(entry):
                continue
            for name in os.listdir(entry):
                target = os.path.join(entry, name)
                link = sandbox / name
                if name == "lsof" or link.exists() or link.is_symlink():
                    continue
                if os.path.isfile(target) and os.access(target, os.X_OK):
                    link.symlink_to(target)
        self.env["PATH"] = str(sandbox)
        self.assertIsNone(shutil.which("lsof", path=self.env["PATH"]))

    def test_age_files_keeps_live_database_with_stale_main_and_fresh_wal(self):
        folder = self.home / "cache"
        folder.mkdir()
        database = folder / "state.sqlite"
        plain = folder / "old-entry.bin"
        plain.write_bytes(b"cache")
        connection = sqlite3.connect(database)
        try:
            connection.execute("pragma journal_mode=wal")
            connection.execute("pragma wal_autocheckpoint=0")
            connection.execute("create table t (v text)")
            connection.executemany("insert into t values (?)", [("row%d" % i,) for i in range(200)])
            connection.commit()
            wal = Path(str(database) + "-wal")
            shm = Path(str(database) + "-shm")
            self.assertTrue(wal.exists() and wal.stat().st_size > 0)
            # Committed rows live only in the fresh WAL; the base file is old.
            self.age(database, plain)
            row, result = self.clean_json(f"cache | all | age-files | {folder} | * | 1 | | on | test")
            self.assertTrue(database.exists(), result.stdout + result.stderr)
            self.assertTrue(wal.exists() and shm.exists())
            self.assertGreater(row["inUse"], 0, row)
            self.assertFalse(plain.exists(), "independent cache files are still removed")
            self.assertEqual(connection.execute("select count(*) from t").fetchone()[0], 200)
        finally:
            connection.close()
        reopened = sqlite3.connect(database)
        try:
            self.assertEqual(reopened.execute("select count(*) from t").fetchone()[0], 200)
        finally:
            reopened.close()

    @unittest.skipUnless(shutil.which("lsof"), "lsof unavailable; date rules keep every SQLite family")
    def test_age_files_keeps_open_database_even_when_every_member_is_stale(self):
        folder = self.home / "cache"
        folder.mkdir()
        database = folder / "state.sqlite"
        connection = sqlite3.connect(database)
        try:
            connection.execute("pragma journal_mode=wal")
            connection.execute("create table t (v text)")
            connection.execute("insert into t values ('keep')")
            connection.commit()
            members = [p for p in (database, Path(str(database) + "-wal"), Path(str(database) + "-shm")) if p.exists()]
            self.age(*members)
            row, result = self.clean_json(f"cache | all | age-files | {folder} | * | 1 | | on | test")
            self.assertTrue(all(p.exists() for p in members), result.stdout + result.stderr)
            self.assertGreater(row["inUse"], 0, row)
            self.assertEqual(connection.execute("select v from t").fetchone()[0], "keep")
        finally:
            connection.close()

    @unittest.skipUnless(shutil.which("lsof"), "lsof unavailable; date rules keep every SQLite family")
    def test_stale_closed_family_and_lone_sidecar_are_removed_whole(self):
        for kind in ("age", "age-files"):
            with self.subTest(kind=kind):
                folder = self.home / ("cache-" + kind)
                members = self.family(folder, "state.sqlite", ("", "-wal", "-shm", "-journal"))
                nested = self.family(folder / "unit", "history.db", ("", "-wal"))
                lone = self.family(folder, "orphan.sqlite3", ("-wal",))
                self.age(*members, *nested, *lone, folder / "unit")
                row, result = self.clean_json(f"cache | all | {kind} | {folder} | * | 1 | | on | test")
                for p in members + nested + lone:
                    self.assertFalse(p.exists(), f"{p.name}: " + result.stdout + result.stderr)
                self.assertEqual(row["inUse"], 0, row)

    def test_missing_lsof_keeps_every_family_but_still_removes_plain_files(self):
        folder = self.home / "cache"
        members = self.family(folder)
        lone = self.family(folder, "orphan.db", ("-journal",))
        plain = [folder / "a.bin", folder / "nested" / "b.bin"]
        plain[1].parent.mkdir()
        for p in plain:
            p.write_bytes(b"cache")
        self.age(*members, *lone, *plain)
        self.without_lsof()
        for kind in ("age-files", "age"):
            with self.subTest(kind=kind):
                row, result = self.clean_json(f"cache | all | {kind} | {folder} | * | 1 | | on | test")
                self.assertTrue(all(p.exists() for p in members + lone), result.stdout + result.stderr)
                self.assertGreaterEqual(row["inUse"], len(members) + len(lone), row)
        self.assertFalse(any(p.exists() for p in plain), "plain files go in the batch even without lsof")

    def test_date_rule_family_with_ineligible_or_unexpected_member_is_kept(self):
        outside = self.base / "outside"
        outside.mkdir()
        (outside / "note.txt").write_text("keep")
        cases = {
            "pattern": ("*.sqlite", lambda wal: None),
            "directory": ("*", lambda wal: (wal.unlink(), wal.mkdir(), (wal / "page").write_bytes(b"p"))),
            "link": ("*", lambda wal: (wal.unlink(), wal.symlink_to(outside, target_is_directory=True))),
        }
        for label, (pattern, shape) in cases.items():
            with self.subTest(case=label):
                folder = self.home / ("cache-" + label)
                members = self.family(folder)
                shape(members[1])
                self.age(members[0], members[2])
                row, result = self.clean_json(f"cache | all | age-files | {folder} | {pattern} | 1 | | on | test")
                self.assertTrue(members[0].exists(), result.stdout + result.stderr)
                self.assertTrue(members[1].exists() or members[1].is_symlink())
                self.assertGreater(row["inUse"], 0, row)
        self.assertEqual((outside / "note.txt").read_text(), "keep")

    def test_linked_archive_root_is_not_purged(self):
        self.own_home()
        outside = self.base / "outside-archive"
        note = outside / "tree" / "20200101" / "note.txt"
        note.parent.mkdir(parents=True)
        note.write_text("keep this archive target", encoding="utf-8")
        archive = self.home / ".manager" / "archive"
        archive.parent.mkdir(parents=True, exist_ok=True)
        if archive.exists() or archive.is_symlink():
            if archive.is_symlink() or archive.is_file():
                archive.unlink()
            else:
                shutil.rmtree(archive)
        archive.symlink_to(outside, target_is_directory=True)
        source = self.home / "unused-src"
        source.mkdir()
        result = self.clean(f"tree | all | archive | {source} | *.txt | 1 | 1 | off | test")
        self.assertTrue(note.exists(), result.stdout + result.stderr)
        self.assertEqual(note.read_text(), "keep this archive target")

    def test_linked_archive_destination_is_not_written(self):
        self.own_home()
        source = self.home / "archsrc"
        source.mkdir()
        old = source / "old.txt"
        old.write_text("session", encoding="utf-8")
        age = time.time() - 10 * 86400
        os.utime(old, (age, age))
        dest_outside = self.base / "outside-dest"
        dest_outside.mkdir()
        archive_rule = self.home / ".manager" / "archive" / "tree"
        archive_rule.mkdir(parents=True)
        today = time.strftime("%Y%m%d")
        linked = archive_rule / today
        linked.symlink_to(dest_outside, target_is_directory=True)
        result = self.clean(f"tree | all | archive | {source} | * | 1 | 60 | on | test")
        self.assertTrue(old.exists(), result.stdout + result.stderr)
        self.assertEqual(list(dest_outside.iterdir()), [])

    def test_nested_archive_link_cannot_create_outside_directories(self):
        self.own_home()
        source = self.home / 'archsrc'
        old = source / 'project' / 'subdir' / 'old.txt'
        old.parent.mkdir(parents=True)
        old.write_text('keep the session')
        age = time.time() - 10 * 86400
        os.utime(old, (age, age))
        outside = self.base / 'outside-dest'
        outside.mkdir()
        destination = self.home / '.manager' / 'archive' / 'tree' / time.strftime('%Y%m%d')
        destination.mkdir(parents=True)
        (destination / 'project').symlink_to(outside, target_is_directory=True)
        result = self.clean(f'tree | all | archive | {source} | * | 1 | 60 | on | test')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(old.exists())
        self.assertEqual(list(outside.iterdir()), [], 'even mkdir must not traverse the link')

    @unittest.skipUnless(shutil.which("lsof"), "lsof unavailable; budget rules delete nothing")
    def test_budget_keeps_a_really_open_file_and_live_database(self):
        folder = self.home / "budget-cache"
        folder.mkdir()
        held = folder / "held.bin"
        nxt = folder / "next.bin"
        last = folder / "last.bin"
        for p in (held, nxt, last):
            p.write_bytes(b"x" * 1048576)
        database = folder / "index.sqlite"
        connection = sqlite3.connect(database)
        handle = open(held, "rb")
        try:
            connection.execute("create table t (v text)")
            connection.execute("insert into t values ('kept')")
            connection.commit()
            self.age(held, days=90)
            self.age(nxt, days=80)
            self.age(last, days=70)
            self.age(database, days=120)
            # 3 MiB plus the database; a 1 MiB budget wants two deletions.
            row, result = self.clean_json(f"budget-cache | all | budget | {folder} | * | 30 | 1 | on | test")
            self.assertTrue(held.exists(), "a file another process holds open is kept")
            self.assertFalse(nxt.exists(), result.stdout + result.stderr)
            self.assertFalse(last.exists())
            self.assertTrue(database.exists(), "SQLite files never go by budget")
            self.assertEqual(row["inUse"], 1, row)
            self.assertEqual(row["scanStatus"], "complete", row)
            self.assertEqual(row["remainingBytes"], 1048576 + database.stat().st_size, row)
            self.assertEqual(row["budgetUnmetBytes"], database.stat().st_size, row)
            self.assertEqual(connection.execute("select v from t").fetchone()[0], "kept")
        finally:
            handle.close()
            connection.close()


if __name__ == "__main__":
    unittest.main()
