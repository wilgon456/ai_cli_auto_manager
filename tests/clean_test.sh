#!/usr/bin/env bash
# Regression test for bin/clean_ai_leftovers.sh. Runs against a throwaway HOME, never the real one,
# with a fake `codex` command; the real Codex is never called.
# shellcheck disable=SC2015,SC2016 # "check && pass || fail" is intended; fake scripts are written with literal $
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home" TMPDIR="$WORK/tmp" AICM_HOME="$WORK/home/.ai-cli-auto-manager" AICM_OS=linux AICM_NOTIFY=0
# If a real codex were ever reached, it would only see the throwaway home.
export CODEX_HOME="$WORK/home/.codex" USERPROFILE="$WORK/home"
unset XDG_CACHE_HOME
mkdir -p "$HOME" "$TMPDIR" "$AICM_HOME" "$WORK/outside" "$WORK/fakebin"

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
TODAY="$(date +%Y%m%d)"

# Fake codex: records calls; archive moves the rollout to archived_sessions, delete removes it.
# Ids starting with "ffffffff" are unknown to it and fail, like the real CLI.
cat > "$WORK/fakebin/codex" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$WORK/codex-calls.log"
id="\${@: -1}"
[[ "\$id" == ffffffff* || "\$id" == eeeeeeee* ]] && { echo "Error: failed to \$1 session" >&2; exit 1; }
# Deleting session 55555555-... also deletes its sub-agent session eeeeeeee-..., like the real Codex does.
[[ "\$1" == delete && "\$id" == 55555555* && -x "$WORK/dbdel" ]] && "$WORK/dbdel" eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee
case "\$1" in
  archive) f="\$(find "$HOME/.codex/sessions" -name "*\$id*" | head -n 1)"; [[ -n "\$f" ]] || exit 1; mkdir -p "$HOME/.codex/archived_sessions"; mv "\$f" "$HOME/.codex/archived_sessions/" ;;
  delete) rm -f "$HOME"/.codex/archived_sessions/*"\$id"* "$HOME"/.codex/sessions/*/*/*/*"\$id"* ;;
esac
exit 0
EOF
chmod +x "$WORK/fakebin/codex"
export PATH="$WORK/fakebin:$PATH"
U1=11111111-1111-4111-8111-111111111111; U2=22222222-2222-4222-8222-222222222222
U3=33333333-3333-4333-8333-333333333333; U4=44444444-4444-4444-8444-444444444444
UX=ffffffff-ffff-4fff-8fff-ffffffffffff; UO=55555555-5555-4555-8555-555555555555; UY=66666666-6666-4666-8666-666666666666
UE=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee

# age rule: old scratch file goes, new one stays, protected names stay, links are not followed.
make_file "$HOME/.codex/.tmp/2026/08/old.bin" 40
make_file "$HOME/.codex/.tmp/2026/10/new.bin" 1
make_file "$HOME/.codex/.tmp/MEMORY.md" 90
make_file "$WORK/outside/precious.txt" 90
link_dir "$WORK/outside" "$HOME/.codex/.tmp/linked"
# archive rule: Claude transcripts, only *.jsonl, memory folder untouched; Claude's own setting is 20 days.
printf '{\n  "cleanupPeriodDays": 20\n}\n' > "$HOME/.claude-settings.tmp"; mkdir -p "$HOME/.claude"; mv "$HOME/.claude-settings.tmp" "$HOME/.claude/settings.json"
make_file "$HOME/.claude/projects/p/old.jsonl" 15
make_file "$HOME/.claude/projects/p/recent.jsonl" 10
make_file "$HOME/.claude/projects/p/notes.md" 40
make_file "$HOME/.claude/projects/p/memory/fact.md" 400
make_file "$AICM_HOME/archive/claude-transcripts/20200101/p/ancient.jsonl" 2000
make_file "$AICM_HOME/archive/claude-transcripts/$TODAY/p/kept.jsonl" 15
# codex rule: archive after 30 days, delete 60 days after that.
make_file "$HOME/.codex/sessions/2026/08/01/rollout-2026-08-01T10-00-00-$U1.jsonl" 40
make_file "$HOME/.codex/sessions/2026/10/01/rollout-2026-10-01T10-00-00-$U2.jsonl" 2
make_file "$HOME/.codex/archived_sessions/rollout-2026-06-01T10-00-00-$U3.jsonl" 100
make_file "$HOME/.codex/archived_sessions/rollout-2026-08-01T10-00-00-$U4.jsonl" 50
make_file "$HOME/.codex/archived_sessions/rollout-2026-05-01T10-00-00-$UX.jsonl" 120
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

# Codex database with two sessions whose file is already gone (100 and 50 days unused), when a reader exists.
DB_OK=false
db_sql="create table threads (id text, rollout_path text, updated_at integer, archived integer);
insert into threads values ('$U1', '$HOME/.codex/sessions/x-$U1.jsonl', $(( $(date +%s) - 40 * 86400 )), 0);
insert into threads values ('$UO', '$HOME/.codex/sessions/gone-$UO.jsonl', $(( $(date +%s) - 100 * 86400 )), 0);
insert into threads values ('$UY', '$HOME/.codex/sessions/gone-$UY.jsonl', $(( $(date +%s) - 50 * 86400 )), 0);
insert into threads values ('$UE', '$HOME/.codex/sessions/gone-$UE.jsonl', $(( $(date +%s) - 100 * 86400 )), 0);"
DB="$HOME/.codex/state_5.sqlite"
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$DB" "$db_sql" && DB_OK=true
  cat > "$WORK/dbdel" <<EOF
#!/usr/bin/env bash
sqlite3 "$DB" "delete from threads where id = '\$1'"
EOF
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import sqlite3' >/dev/null 2>&1; then
  python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.executescript(sys.argv[2]); c.commit()' "$DB" "$db_sql" && DB_OK=true
  cat > "$WORK/dbdel" <<EOF
#!/usr/bin/env bash
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("delete from threads where id = ?", (sys.argv[2],)); c.commit()' "$DB" "\$1"
EOF
fi
[[ -f "$WORK/dbdel" ]] && chmod +x "$WORK/dbdel"

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
expect_exists "$HOME/.codex/.tmp/2026/08/old.bin" "dry run removes nothing"
expect_exists "$HOME/.claude/projects/p/old.jsonl" "dry run archives nothing"
expect_exists "$HOME/.cache/ms-playwright/chromium-1000" "dry run keeps old builds"
[[ ! -s "$WORK/codex-calls.log" ]] && pass "dry run does not call codex" || fail "dry run called codex"
grep -q 'refused' <<< "$out" && pass "outside paths are refused" || fail "refused rows missing"
grep -q 'would remove' <<< "$out" && grep -q 'would archive' <<< "$out" && pass "dry run wording" || fail "dry run wording"
grep -q 'archive after 12d (the CLI deletes after 20d)' <<< "$out" && pass "archives a week before Claude's own cleanup" || fail "native retention"

echo "# real run"
out="$("$ROOT/bin/clean_ai_leftovers.sh" 2>&1)" && rc=0 || rc=$?
echo "$out"
expect_gone "$HOME/.codex/.tmp/2026/08/old.bin" "old scratch file removed"
expect_gone "$HOME/.codex/.tmp/2026/08" "emptied folder pruned"
expect_exists "$HOME/.codex/.tmp" "rule root kept"
expect_exists "$HOME/.codex/.tmp/2026/10/new.bin" "fresh scratch file kept"
expect_exists "$HOME/.codex/.tmp/MEMORY.md" "protected name kept"
expect_exists "$WORK/outside/precious.txt" "link target outside never touched"
expect_link_target "$HOME/.codex/.tmp/linked" "link itself kept by age rule"

expect_gone "$HOME/.claude/projects/p/old.jsonl" "transcript older than the archive age left the project folder"
expect_exists "$AICM_HOME/archive/claude-transcripts/$TODAY/p/old.jsonl" "... and sits in today's archive with its relative path"
expect_exists "$HOME/.claude/projects/p/recent.jsonl" "recent transcript kept in place"
expect_exists "$HOME/.claude/projects/p/notes.md" "pattern limits to *.jsonl"
expect_exists "$HOME/.claude/projects/p/memory/fact.md" "memory folder kept"
expect_gone "$AICM_HOME/archive/claude-transcripts/20200101" "archive folder past its limit deleted (remnants)"
expect_exists "$AICM_HOME/archive/claude-transcripts/$TODAY/p/kept.jsonl" "today's archive folder kept"

grep -qx "archive $U1" "$WORK/codex-calls.log" && pass "codex session unused 30+ days archived with codex archive" || fail "codex archive: $(cat "$WORK/codex-calls.log")"
expect_exists "$HOME/.codex/archived_sessions/rollout-2026-08-01T10-00-00-$U1.jsonl" "... and Codex moved it to archived_sessions"
! grep -q "$U2" "$WORK/codex-calls.log" && pass "recent codex session untouched" || fail "recent codex session touched"
grep -qx "delete --force $U3" "$WORK/codex-calls.log" && pass "archived session unused 90+ days deleted with codex delete" || fail "codex delete"
! grep -q "$U4" "$WORK/codex-calls.log" && pass "archived session younger than 90 days kept" || fail "young archived session touched"
expect_exists "$HOME/.codex/archived_sessions/rollout-2026-08-01T10-00-00-$U4.jsonl" "... file still there"
if [[ "$DB_OK" == true ]]; then
  grep -qx "delete --force $UO" "$WORK/codex-calls.log" && pass "session whose file is gone and unused 90+ days deleted" || fail "orphan delete"
  ! grep -q "$UY" "$WORK/codex-calls.log" && pass "session whose file is gone but used within 90 days kept" || fail "young orphan touched"
  grep -E '^codex-sessions ' <<< "$out" | grep -qv 'in use or failed' && pass "sub-agent session removed with its parent is not reported as failed" || fail "sub-agent recount: $(grep -E '^codex-sessions ' <<< "$out")"
  expect_gone "$HOME/.codex/archived_sessions/rollout-2026-05-01T10-00-00-$UX.jsonl" "file Codex does not know is removed directly"
else
  echo "skip - Codex database checks (no sqlite3 or python3 here)"
  expect_exists "$HOME/.codex/archived_sessions/rollout-2026-05-01T10-00-00-$UX.jsonl" "without the database, unknown files are kept"
fi

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

echo "# without a codex command nothing of Codex is touched"
make_file "$HOME/.codex/sessions/2026/07/01/rollout-2026-07-01T10-00-00-$U2.jsonl" 60
# Only where no real codex exists: never let a test reach the real Codex.
if PATH="${PATH#"$WORK/fakebin:"}" command -v codex >/dev/null 2>&1; then
  echo "skip - a real codex is installed on this machine"
else
  PATH="${PATH#"$WORK/fakebin:"}" "$ROOT/bin/clean_ai_leftovers.sh" --rules codex-sessions > "$WORK/nocodex.txt" 2>&1 || true
  grep -q 'codex command not found: nothing touched' "$WORK/nocodex.txt" && pass "missing codex command reported" || fail "missing codex"
  expect_exists "$HOME/.codex/sessions/2026/07/01/rollout-2026-07-01T10-00-00-$U2.jsonl" "codex files kept without the codex command"
fi

echo "# explicit rule runs even when off"
"$ROOT/bin/clean_ai_leftovers.sh" --rules codex-images >/dev/null 2>&1 || true
expect_gone "$HOME/.codex/generated_images/pic.png" "--rules runs an off rule"
expect_exists "$AICM_HOME/archive/codex-images/$TODAY/pic.png" "... and archives it"

echo "# unknown rule id"
if "$ROOT/bin/clean_ai_leftovers.sh" --rules nope >/dev/null 2>&1; then fail "unknown id accepted"; else pass "unknown id rejected"; fi

echo "# bad rule file"
printf 'x | all | weird | ~/.x | * | 1 | | on |\n' > "$WORK/bad.conf"
if "$ROOT/bin/clean_ai_leftovers.sh" --dry-run --local-rules-file "$WORK/bad.conf" >/dev/null 2>&1; then fail "bad kind accepted"; else pass "bad kind rejected"; fi
printf 'x | all | archive | ~/.x | * | 30 | | on |\n' > "$WORK/bad2.conf"
if "$ROOT/bin/clean_ai_leftovers.sh" --dry-run --local-rules-file "$WORK/bad2.conf" >/dev/null 2>&1; then fail "archive rule without limit accepted"; else pass "archive rule needs a delete-after limit"; fi

echo
if ((fails)); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
