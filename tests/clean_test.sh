#!/usr/bin/env bash
# Regression test for bin/clean_ai_leftovers.sh. Runs against a throwaway HOME, never the real one.
# shellcheck disable=SC2015 # "check && pass || fail" is intended: pass never fails
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home" TMPDIR="$WORK/tmp" AICM_HOME="$WORK/home/.ai-cli-auto-manager" AICM_OS=linux AICM_NOTIFY=0
unset XDG_CACHE_HOME
mkdir -p "$HOME" "$TMPDIR" "$AICM_HOME" "$WORK/outside"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
expect_exists() { if [[ -e "$1" ]]; then pass "$2"; else fail "$2 ($1 missing)"; fi; }
expect_gone() { if [[ ! -e "$1" ]]; then pass "$2"; else fail "$2 ($1 still there)"; fi; }

stamp_days_ago() {
  local s=$(( $(date +%s) - $1 * 86400 ))
  date -d "@$s" +%Y%m%d%H%M 2>/dev/null || date -r "$s" +%Y%m%d%H%M
}
LINKS=true
link_dir() { # target link; Git Bash without symlink rights cannot make real links, so skip those checks there
  mkdir -p "$(dirname "$2")"
  ln -s "$1" "$2" 2>/dev/null && [[ -L "$2" ]] || { LINKS=false; rm -rf "$2"; }
}
expect_link_target() { if [[ "$LINKS" == true ]]; then expect_exists "$@"; else echo "skip - $2 (no symlink support)"; fi; }
make_file() { # path days_old [bytes]
  mkdir -p "$(dirname "$1")"
  head -c "${3:-16}" /dev/zero > "$1"
  touch -t "$(stamp_days_ago "$2")" "$1"
}

# Codex transcripts: old one goes, new one stays, protected names stay.
make_file "$HOME/.codex/sessions/2026/08/old.jsonl" 40
make_file "$HOME/.codex/sessions/2026/10/new.jsonl" 1
make_file "$HOME/.codex/sessions/MEMORY.md" 90
# A link inside a cleaned folder must never be followed.
make_file "$WORK/outside/precious.txt" 90
link_dir "$WORK/outside" "$HOME/.codex/sessions/linked"
# Claude transcripts: only *.jsonl, memory folder untouched.
make_file "$HOME/.claude/projects/p/old.jsonl" 40
make_file "$HOME/.claude/projects/p/notes.md" 40
make_file "$HOME/.claude/projects/p/memory/fact.md" 400
# Off-by-default rule keeps its files.
make_file "$HOME/.codex/generated_images/pic.png" 90
# cap: oversized trace DB plus its WAL go, small fresh DB stays.
make_file "$HOME/.codex/logs_2.sqlite" 1 2097152
make_file "$HOME/.codex/logs_2.sqlite-wal" 1 10
make_file "$HOME/.codex/logs_9.sqlite" 1 10
# keep-latest: keep the newest two chromium builds, ignore unversioned names.
for b in 1000 1100 1200; do make_file "$HOME/.cache/ms-playwright/chromium-$b/chrome" 1; done
make_file "$HOME/.cache/ms-playwright/ffmpeg/ffmpeg" 1
link_dir "$WORK/outside" "$HOME/.cache/ms-playwright/chromium-1000/linked"

cat > "$AICM_HOME/clean-rules.local.conf" <<'EOF'
codex-trace-db      | all   | cap         | ~/.codex                | logs_*.sqlite | 30 | 1 | on |
playwright-browsers | linux | keep-latest | {cache}/ms-playwright   | *             |    | 2 | on |
escape-home         | all   | age         | ~/../escape             | *             | 1  |   | on |
home-itself         | all   | age         | ~                       | *             | 1  |   | on |
system-dir          | all   | age         | /usr                    | *             | 1  |   | on |
EOF

echo "# dry run"
out="$("$ROOT/bin/clean_ai_leftovers.sh" --dry-run 2>&1)" && rc=0 || rc=$?
echo "$out"
[[ "$rc" == 1 ]] && pass "dry run reports refused rules with exit 1" || fail "dry run exit was $rc"
expect_exists "$HOME/.codex/sessions/2026/08/old.jsonl" "dry run removes nothing"
expect_exists "$HOME/.cache/ms-playwright/chromium-1000" "dry run keeps old builds"
grep -q 'refused' <<< "$out" && pass "outside paths are refused" || fail "refused rows missing"
grep -q 'would remove' <<< "$out" && pass "dry run says would remove" || fail "dry run wording"

echo "# real run"
out="$("$ROOT/bin/clean_ai_leftovers.sh" 2>&1)" && rc=0 || rc=$?
echo "$out"
expect_gone "$HOME/.codex/sessions/2026/08/old.jsonl" "old transcript removed"
expect_gone "$HOME/.codex/sessions/2026/08" "emptied folder pruned"
expect_exists "$HOME/.codex/sessions" "rule root kept"
expect_exists "$HOME/.codex/sessions/2026/10/new.jsonl" "fresh transcript kept"
expect_exists "$HOME/.codex/sessions/MEMORY.md" "protected name kept"
expect_exists "$WORK/outside/precious.txt" "link target outside never touched"
expect_link_target "$HOME/.codex/sessions/linked" "link itself kept by age rule"
expect_gone "$HOME/.claude/projects/p/old.jsonl" "old claude transcript removed"
expect_exists "$HOME/.claude/projects/p/notes.md" "pattern limits to *.jsonl"
expect_exists "$HOME/.claude/projects/p/memory/fact.md" "memory folder kept"
expect_exists "$HOME/.codex/generated_images/pic.png" "off rule keeps files"
expect_gone "$HOME/.codex/logs_2.sqlite" "oversized trace DB removed"
expect_gone "$HOME/.codex/logs_2.sqlite-wal" "trace DB sidecar removed"
expect_exists "$HOME/.codex/logs_9.sqlite" "small fresh DB kept"
expect_gone "$HOME/.cache/ms-playwright/chromium-1000" "oldest build removed"
expect_exists "$HOME/.cache/ms-playwright/chromium-1100" "second newest build kept"
expect_exists "$HOME/.cache/ms-playwright/chromium-1200" "newest build kept"
expect_exists "$HOME/.cache/ms-playwright/ffmpeg" "unversioned folder kept"
expect_exists "$WORK/outside/precious.txt" "link inside removed build not followed"
expect_exists "$AICM_HOME/state/last-clean.json" "state file written"
grep -q '"ok":false' "$AICM_HOME/state/last-clean.json" && pass "state records refused rules" || fail "state ok flag"

echo "# explicit rule runs even when off"
"$ROOT/bin/clean_ai_leftovers.sh" --rules codex-images >/dev/null 2>&1 || true
expect_gone "$HOME/.codex/generated_images/pic.png" "--rules runs an off rule"

echo "# unknown rule id"
if "$ROOT/bin/clean_ai_leftovers.sh" --rules nope >/dev/null 2>&1; then fail "unknown id accepted"; else pass "unknown id rejected"; fi

echo "# bad rule file"
printf 'x | all | weird | ~/.x | * | 1 | | on |\n' > "$WORK/bad.conf"
if "$ROOT/bin/clean_ai_leftovers.sh" --dry-run --local-rules-file "$WORK/bad.conf" >/dev/null 2>&1; then fail "bad kind accepted"; else pass "bad kind rejected"; fi

echo
if ((fails)); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
