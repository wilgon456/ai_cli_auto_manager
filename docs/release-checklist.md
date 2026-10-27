# Release checklist

For maintainers preparing a source release. Nothing here publishes anything by itself; every step
runs in a checkout and in throwaway folders. Do not describe a release as "certified",
"production-ready" or "tested on" a platform unless the exact release commit passed there and the
result is recorded in the release notes.

## 1. Scope and version

- `VERSION` and the top `CHANGELOG.md` section agree. An unreleased section stays marked
  `Unreleased` until the tag is made.
- The changelog describes every behavior change, its side effects (what is deleted, what is
  downloaded again, what needs Node.js) and known limits. Follow-up work is listed as follow-up, not
  as done.
- Default cleanup rules (`rules/clean-rules.conf`) and default schedules changed only on purpose, and
  the change is in the changelog. New destructive kinds (`budget`) and commands (`optimize`) stay
  opt-in.

## 2. Compatibility matrix

Record, for the exact release commit, which of these passed. Configured CI is not a record that a
platform ran; link the CI run.

| Platform | Shell / runtime | Suites |
| --- | --- | --- |
| macOS (Intel or Apple silicon) | `/bin/bash` 3.2, Node.js 22 | all Bash, Python and Node suites, ShellCheck |
| Ubuntu | GNU Bash, Node.js 22 | all Bash, Python and Node suites, `pwsh tests/cache_budget_test.ps1` |
| Windows | Windows PowerShell 5.1 | every `tests/*.ps1`, Node suites |
| Windows | PowerShell 7 | every `tests/*.ps1`, Node suites, PSScriptAnalyzer errors |

Optional but recommended: one disposable machine per OS with real CLIs, running `aicm inventory`,
`aicm update --dry-run`, `aicm clean --dry-run --json` and `aicm optimize` (preview) and recording the
output. Never run these against a maintainer's real profile while testing a release candidate.

For this unreleased line, also repeat the inventory suite concurrently on macOS Bash 3.2 with
captured output and a bounded runner. An intermittent updater spin was observed before the buffered
read change; passing reruns are mitigation evidence, not confirmation of its precise cause. A timed-out
run must be investigated and never counted as passed.

## 3. Isolated smoke checks

Run in a throwaway `HOME`/`USERPROFILE` and `AICM_HOME`, with fake package managers on PATH:

- `aicm clean --dry-run --json` prints one JSON document and writes nothing.
- A local `budget` rule over a fixture cache removes only old, unprotected, non-SQLite files, oldest
  first, and reports `totalBytes`, `budgetBytes`, `remainingBytes`, `budgetUnmetBytes`, `scanStatus`.
- `aicm optimize --json` runs no tool and creates no `AICM_HOME`; `aicm optimize --apply` runs exactly
  `npm cache verify`, `uv cache prune`, `pnpm store prune` against the fakes and releases
  `state/maintenance.lock`.
- `aicm doctor` and `aicm uninstall --purge --dry-run` change nothing.

## 4. Integrity and packaging

```sh
python3 scripts/check_manifest.py          # hashes, plus files missing from the manifest
python3 tests/release_packaging_test.py
python3 scripts/build_release.py --output-dir /path/outside/the/checkout/release-X.Y.Z
cd /path/outside/the/checkout/release-X.Y.Z && shasum -a 256 -c SHA256SUMS   # or sha256sum -c
```

- `MANIFEST.json` lists every release file (sources, rules, tests, docs) with its SHA-256 and nothing
  local: no logs, caches (`__pycache__`), `.git`, credentials or `docs/social/`.
- `build_release.py` packs only manifest files, verifies each hash, refuses links, unsafe or
  case-colliding names and an output folder that already holds artifacts, and writes reproducible
  `.tar.gz` and `.zip` archives plus `SHA256SUMS`. Build into a fresh folder outside the checkout.
- Extract both archives into empty folders and run `python3 scripts/check_manifest.py` inside each
  (it checks hashes without Git).
- The manifest and `SHA256SUMS` are integrity checks, not publisher signatures. Sign tags or
  artifacts separately if you need authenticity.

## 5. Security

- Vulnerabilities are reported as described in [SECURITY.md](../SECURITY.md) (private advisory). Do not
  ship a release with an open deletion-boundary or package-selection report unless the notes say so.
- Review changes to deletion paths (`bin/clean_ai_leftovers.*`, `lib/aicm-common.*`,
  `lib/aicm-file-guard.cs`, `lib/maintenance.js`) and command execution (`lib/optimize.js`,
  updaters) with their refusal tests: linked ancestors, open files, SQLite families, protected names,
  incomplete scans, busy package managers, metacharacters in Windows paths.

## 6. Publish (outside this checklist)

Tagging, uploading archives and announcing are manual maintainer steps. Attach `SHA256SUMS`, state
the platforms that actually passed, and list known limits and follow-up work (for this line: OS DNS
cache flush, macOS QuickLook reset and SQLite `VACUUM` are not included).
