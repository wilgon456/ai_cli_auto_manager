"""Release archive membership, integrity, reproducibility and boundary regressions."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('aicm_release', Path(__file__).resolve().parents[1] / 'scripts/build_release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='aicm-release-test-')
        self.addCleanup(self.scratch.cleanup)
        self.work = Path(self.scratch.name)
        self.root = self.work / 'source'
        self.root.mkdir()
        self.content = {'VERSION': b'2.8.3\n', 'LICENSE': b'MIT License\n', 'bin/aicm': b'#!/bin/bash\n', 'README.md': b'documentation\n'}
        for name, data in self.content.items():
            p = self.root / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        self.write_manifest()

    def write_manifest(self, manifest=None):
        if manifest is None:
            manifest = {n: hashlib.sha256(d).hexdigest() for n, d in self.content.items()}
        (self.root / 'MANIFEST.json').write_text(json.dumps(manifest), encoding='utf-8')

    def test_archives_only_include_verified_files_and_manifest(self):
        personal = self.root / 'docs/social/private.txt'
        personal.parent.mkdir(parents=True)
        personal.write_text('must not ship')
        outputs = release.build(self.root, self.work / 'out')
        expected = {'ai_cli_auto_manager-2.8.3/' + n for n in list(self.content) + ['MANIFEST.json']}
        for p in outputs:
            if p.name.endswith('.tar.gz'):
                with tarfile.open(p) as archive:
                    self.assertEqual(set(archive.getnames()), expected)
                    self.assertEqual(archive.getmember('ai_cli_auto_manager-2.8.3/bin/aicm').mode, 0o755)
            elif p.suffix == '.zip':
                with zipfile.ZipFile(p) as archive:
                    self.assertEqual(set(archive.namelist()), expected)
                    self.assertEqual(archive.read('ai_cli_auto_manager-2.8.3/LICENSE'), b'MIT License\n')
        for line in (self.work / 'out/SHA256SUMS').read_text().splitlines():
            digest, name = line.split('  ')
            self.assertEqual(digest, hashlib.sha256((self.work / 'out' / name).read_bytes()).hexdigest())

    def test_build_is_reproducible_in_same_toolchain(self):
        first = {p.name: p.read_bytes() for p in release.build(self.root, self.work / 'one')}
        second = {p.name: p.read_bytes() for p in release.build(self.root, self.work / 'two')}
        self.assertEqual(first, second)

    def test_stale_hash_fails_before_output_created(self):
        (self.root / 'LICENSE').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            release.build(self.root, self.work / 'out')
        self.assertFalse((self.work / 'out').exists())

    def test_unsafe_manifest_paths_rejected(self):
        for name in ['../secret', '/secret', 'a/../secret', 'a\\secret', 'C:secret', 'a//b', 'docs/social/private.txt']:
            with self.subTest(name=name):
                self.write_manifest({name: '0' * 64})
                with self.assertRaises(ValueError):
                    release.build(self.root, self.work / 'out')

    def test_linked_file_rejected(self):
        p = self.root / 'README.md'
        p.unlink()
        outside = self.work / 'outside'
        outside.write_bytes(self.content['README.md'])
        try:
            p.symlink_to(outside)
        except OSError:
            self.skipTest('symlink creation unavailable')
        with self.assertRaisesRegex(ValueError, 'linked release path'):
            release.build(self.root, self.work / 'out')

    def test_unicode_release_paths_roundtrip(self):
        name = 'docs/' + chr(0xC548) + chr(0xB0B4) + '.txt'
        self.content[name] = 'unicode documentation'.encode('utf-8')
        file = self.root / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(self.content[name])
        self.write_manifest()
        for output in release.build(self.root, self.work / 'out'):
            member = 'ai_cli_auto_manager-2.8.3/' + name
            if output.name.endswith('.tar.gz'):
                with tarfile.open(output) as archive:
                    self.assertEqual(archive.extractfile(member).read(), self.content[name])
            elif output.suffix == '.zip':
                with zipfile.ZipFile(output) as archive:
                    self.assertEqual(archive.read(member), self.content[name])

    def test_existing_artifacts_are_preserved(self):
        outputs = release.build(self.root, self.work / 'out')
        expected = {p: p.read_bytes() for p in outputs}
        with self.assertRaisesRegex(ValueError, 'output already exists'):
            release.build(self.root, self.work / 'out')
        self.assertTrue(all(p.read_bytes() == data for p, data in expected.items()))


if __name__ == '__main__':
    unittest.main()
