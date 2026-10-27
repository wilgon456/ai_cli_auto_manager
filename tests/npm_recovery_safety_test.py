"""Exercise npm recovery with disposable launchers and the fake npm registry."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class NpmRecoverySafetyTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="aicm-recovery-safety-")
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)
        self.home = self.base / "home"
        self.prefix = self.base / "npm"
        self.npm_root = self.prefix / "lib/node_modules"
        self.manager = self.home / ".manager"
        for folder in (self.home, self.base / "tmp", self.prefix / "bin",
                       self.npm_root, self.manager / "state", self.base / "bin"):
            folder.mkdir(parents=True, exist_ok=True)
        # An existing install's home (marked): the tests write state/ before a run, and an unmarked
        # folder holding state/ without an installed copy is no longer adopted (no proof it is ours).
        (self.manager / ".aicm-home").write_text("AI CLI Auto Manager home (logs, state, archive, installed copy)\n")
        npm = self.base / "bin/npm"
        npm.write_text(f'#!/bin/sh\nexec node "{ROOT / "tests/fixtures/npm-fake.js"}" "$@"\n')
        npm.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.base / "tmp"),
                        CODEX_HOME=str(self.home / ".codex"), AICM_HOME=str(self.manager),
                        AICM_NOTIFY="0", AICM_WORKTREES="0", AICM_PROCESSES="0",
                        AICM_VERIFY_SIGNATURES="0", AICM_CODEX_UNQUARANTINE="0",
                        AICM_CODEX_RECYCLE="0", AICM_OS="linux", NPM=str(npm), BREW="/usr/bin/false",
                        LOCK_DIR=str(self.base / "update.lock"), FAKE_NPM_DIR=str(self.base),
                        FAKE_NPM_PREFIX=str(self.prefix), FAKE_NPM_ROOT=str(self.npm_root),
                        PATH=str(self.base / "bin") + os.pathsep + str(self.prefix / "bin")
                        + os.pathsep + os.environ["PATH"])

    def prepare(self, package, command, body):
        parent, name = package.rsplit("/", 1)
        backup = self.npm_root / parent / ("." + name + "-XyZw9876")
        backup.mkdir(parents=True)
        (backup / "package.json").write_text(json.dumps({"name": package, "version": "0.1.0"}))
        (self.manager / "state/update-npm.tsv").write_text(package + "\t0.1.0\n")
        (self.base / "registry.json").write_text(json.dumps({package: {
            "latest": "0.2.0", "versions": {"0.1.0": {"daysAgo": 30}, "0.2.0": {"daysAgo": 10}}
        }}))
        launcher = self.prefix / "bin" / command
        launcher.write_text("#!/bin/sh\n" + body + "\n")
        launcher.chmod(0o755)
        return backup

    def update(self, target):
        return subprocess.run(["/bin/bash", str(ROOT / "bin/update_ai_clis.sh"),
                               "--targets", target], env=self.env, capture_output=True,
                              text=True, timeout=45)

    def test_legacy_amp_shim_restores_its_package(self):
        package_file = self.npm_root / "@sourcegraph/amp/package.json"
        body = "node -p " + shlex.quote('"amp " + require(process.argv[1]).version') + " " + shlex.quote(str(package_file))
        self.prepare("@sourcegraph/amp", "amp", body)
        result = self.update("amp")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("restored: @sourcegraph/amp", result.stdout)
        calls = (self.base / "npm-calls.log").read_text()
        self.assertIn("install -g @sourcegraph/amp@0.1.0", calls)
        self.assertNotIn("@ampcode/cli@", calls)

    def test_standalone_launcher_in_shared_prefix_is_not_npm_recovery(self):
        backup = self.prepare("@openai/codex", "codex", "echo codex-cli 0.1.0")
        result = self.update("codex")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("unused npm copy @openai/codex is not restored", result.stdout)
        self.assertTrue(backup.exists())
        calls = self.base / "npm-calls.log"
        if calls.exists():
            self.assertNotIn("install -g @openai/codex@", calls.read_text())


if __name__ == "__main__":
    unittest.main()
