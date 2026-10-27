#!/usr/bin/env python3
"""Build verified source archives from MANIFEST.json; never includes unlisted files."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import stat
import tarfile
import zipfile


def unique_object(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError('duplicate manifest key: ' + key)
        out[key] = value
    return out


def regular_bytes(root, name):
    rel = PurePosixPath(name)
    if (not name or rel.is_absolute() or rel.as_posix() != name or
            any(part in ('', '.', '..') for part in name.split('/')) or
            '\\' in name or ':' in name or any(ord(ch) < 32 for ch in name)):
        raise ValueError('unsafe release path: ' + name)
    if rel.parts[0] == '.git' or name.startswith('docs/social/'):
        raise ValueError('private or local-only release path: ' + name)
    current = root
    for part in rel.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError('linked release path: ' + name)
    if not stat.S_ISREG(current.stat().st_mode):
        raise ValueError('release entry is not a regular file: ' + name)
    return current.read_bytes()


def verified_files(root):
    root = Path(root).resolve()
    raw = regular_bytes(root, 'MANIFEST.json')
    manifest = json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object)
    if not isinstance(manifest, dict) or not manifest:
        raise ValueError('release manifest must be a nonempty object')
    files = {}
    folded = set()
    for name, expected in sorted(manifest.items()):
        if not isinstance(name, str) or name == 'MANIFEST.json':
            raise ValueError('invalid manifest entry')
        if name.casefold() in folded:
            raise ValueError('case-colliding release path: ' + name)
        folded.add(name.casefold())
        if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
            raise ValueError('invalid checksum: ' + name)
        data = regular_bytes(root, name)
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError('checksum mismatch: ' + name)
        files[name] = data
    if 'VERSION' not in files or 'LICENSE' not in files:
        raise ValueError('VERSION and LICENSE must be in the release manifest')
    version = files['VERSION'].decode('ascii').strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', version):
        raise ValueError('invalid release VERSION')
    files['MANIFEST.json'] = raw
    return version, files


def release_mode(name):
    return 0o755 if name == 'bin/aicm' or name.endswith(('.sh', '.py')) else 0o644


def archive_bytes(prefix, files):
    tar_buffer = io.BytesIO()
    with gzip.GzipFile(filename='', fileobj=tar_buffer, mode='wb', mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode='w', format=tarfile.PAX_FORMAT) as archive:
            for name, data in sorted(files.items()):
                entry = tarfile.TarInfo(prefix + '/' + name)
                entry.size = len(data)
                entry.mode = release_mode(name)
                entry.mtime = entry.uid = entry.gid = 0
                archive.addfile(entry, io.BytesIO(data))
    zip_buffer = io.BytesIO()
    with zipfile.ZipFile(zip_buffer, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(prefix + '/' + name, (1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | release_mode(name)) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data)
    return {prefix + '.tar.gz': tar_buffer.getvalue(), prefix + '.zip': zip_buffer.getvalue()}


def build(root, output_dir):
    version, files = verified_files(root)
    artifacts = archive_bytes('ai_cli_auto_manager-' + version, files)
    sums = ''.join(hashlib.sha256(data).hexdigest() + '  ' + name + '\n'
                   for name, data in sorted(artifacts.items())).encode('ascii')
    artifacts['SHA256SUMS'] = sums
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    # Exclusive creation preserves previous artifacts and refuses symlink destinations.
    if any((output_dir / name).exists() or (output_dir / name).is_symlink() for name in artifacts):
        raise ValueError('output already exists; choose an empty release output directory')
    for name, data in artifacts.items():
        with (output_dir / name).open('xb') as stream:
            stream.write(data)
    return [output_dir / name for name in sorted(artifacts)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    try:
        outputs = build(Path(__file__).resolve().parents[1], args.output_dir)
    except (OSError, UnicodeError, ValueError, tarfile.TarError, zipfile.BadZipFile) as error:
        parser.exit(1, 'release: ' + str(error) + '\n')
    for output in outputs:
        print(output)


if __name__ == '__main__':
    main()
