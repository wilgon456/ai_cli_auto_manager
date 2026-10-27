#!/usr/bin/env python3
"""Verify the release file manifest without changing the checkout."""

import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def main():
    try:
        manifest = json.loads((ROOT / "MANIFEST.json").read_text(encoding="utf-8"))
        if not isinstance(manifest, dict) or not manifest:
            raise ValueError("expected a nonempty object of filenames and SHA-256 hashes")
    except (OSError, ValueError) as error:
        print(f"manifest: {error}", file=sys.stderr)
        return 1

    problems = []
    for name, expected in manifest.items():
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or "\\" in name or name == "MANIFEST.json":
            problems.append(f"invalid manifest path: {name}")
            continue
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
            problems.append(f"invalid SHA-256: {name}")
            continue
        file = ROOT / path
        try:
            actual = hashlib.sha256(file.read_bytes()).hexdigest()
        except OSError as error:
            problems.append(f"cannot read {name}: {error}")
            continue
        if actual != expected:
            problems.append(f"checksum mismatch: {name}")

    # Check completeness when run from Git: tracked files and new files that are not ignored (so a
    # new test or module cannot be forgotten before its first commit). docs/social is local-only.
    # Extracted release archives still get hash checks.
    if (ROOT / ".git").exists():
        try:
            result = subprocess.run(
                ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT, check=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            listed = set(result.stdout.decode("utf-8").split("\0")) - {"", "MANIFEST.json"}
            listed = {n for n in listed if not n.startswith("docs/social/") and (ROOT / n).is_file()}
            for name in sorted(listed - set(manifest)):
                problems.append(f"release file missing from manifest: {name}")
        except (OSError, subprocess.CalledProcessError, UnicodeError) as error:
            problems.append(f"could not check tracked files: {error}")

    if problems:
        for problem in problems:
            print(f"manifest: {problem}", file=sys.stderr)
        return 1
    print(f"manifest: {len(manifest)} files verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
