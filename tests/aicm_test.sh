#!/usr/bin/env bash
# Tests for bin/aicm (dispatcher, schedule via a fake crontab, doctor) and the updater dry run.
# Runs against a throwaway HOME and never touches the real crontab.
# shellcheck disable=SC2015 # "check && pass || fail" is intended: pass never fails
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home" TMPDIR="$WORK/tmp" AICM_HOME="$WORK/home/.ai-cli-auto-manager" AICM_OS=linux AICM_NOTIFY=0
# If a real codex were ever reached, it would only see the throwaway home.
export CODEX_HOME="$WORK/home/.codex" USERPROFILE="$WORK/home"
# The node checks have their own tests (tests/node); keep these runs away from real processes and repos.
export AICM_PROCESSES=0 AICM_WORKTREES=0
mkdir -p "$HOME" "$TMPDIR" "$WORK/fakebin"

# Fake crontab that keeps its table in a file.
cat > "$WORK/fakebin/crontab" <<EOF
#!/usr/bin/env bash
table="$WORK/crontab.txt"
if [[ "\${1:-}" == -l ]]; then [[ -f "\$table" ]] && cat "\$table" || exit 1; exit 0; fi
if [[ "\${1:-}" == - ]]; then content="\$(cat)"; printf '%s\n' "\$content" > "\$table"; exit 0; fi
if [[ "\${1:-}" == -r ]]; then rm -f "\$table"; exit 0; fi
exit 2
EOF
chmod +x "$WORK/fakebin/crontab"
export PATH="$WORK/fakebin:$PATH"
printf '17 3 * * * /usr/bin/true # keep me\n' > "$WORK/crontab.txt"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
AICM="$ROOT/bin/aicm"

"$AICM" version | grep -q "AI CLI Auto Manager $(cat "$ROOT/VERSION")" && pass "version" || fail "version"
"$AICM" help | grep -q 'aicm schedule' && pass "help" || fail "help"
if "$AICM" bogus >/dev/null 2>&1; then fail "unknown command accepted"; else pass "unknown command rejected"; fi

out="$("$AICM" doctor 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 ]] && grep -q 'no schedule installed' <<< "$out" && pass "doctor flags missing schedule" || fail "doctor without schedule: $out"

for bad in 25:99 24:00 7:60 5 ab:cd; do
  if "$AICM" schedule install --clean-at "$bad" >/dev/null 2>&1; then fail "time $bad accepted"; fi
done
! grep -q '# aicm:' "$WORK/crontab.txt" && pass "invalid times rejected before anything is registered" || fail "invalid time registered jobs"

"$AICM" schedule install --update-at 06:15 --inventory-day wed --inventory-at 11:40 --clean-day sun --clean-at 13:05 --targets codex,claude >/dev/null
grep -Eq '^15 6,9,12,15,18,21 \* \* \* /bin/bash \S*\.ai-cli-auto-manager/app/bin/update_ai_clis.sh --scheduled --targets codex\\?,claude .*# aicm:update$' "$WORK/crontab.txt" && pass "update cron line" || fail "update cron line: $(cat "$WORK/crontab.txt")"
grep -q '^5 13 \* \* 0 .*clean_ai_leftovers.sh .*# aicm:clean$' "$WORK/crontab.txt" && pass "clean cron line (sunday = 0)" || fail "clean cron line"
grep -q '^40 11 \* \* 3 .*inventory_ai_clis.sh .*# aicm:inventory$' "$WORK/crontab.txt" && pass "inventory cron line (wednesday = 3)" || fail "inventory cron line"
grep -q '# keep me' "$WORK/crontab.txt" && pass "other cron lines kept" || fail "other cron line lost"

"$AICM" schedule install >/dev/null
[[ "$(grep -c '# aicm:' "$WORK/crontab.txt")" == 3 ]] && pass "reinstall does not duplicate" || fail "duplicate cron lines"

out="$("$AICM" doctor 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 ]] && grep -q 'no update run' <<< "$out" && pass "doctor flags missing update run" || fail "doctor before runs: $out"

"$AICM" clean >/dev/null 2>&1 || true
[[ -f "$AICM_HOME/state/last-clean.json" ]] && pass "clean writes state" || fail "clean state"

out="$("$AICM" update --dry-run --targets none 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && pass "update dry run exits 0" || fail "update dry run rc=$rc: $out"
[[ ! -f "$AICM_HOME/state/last-update.json" ]] && pass "dry run writes no update state" || fail "dry run wrote state"
[[ -f "$AICM_HOME/logs/latest.log" ]] && pass "update log in new home" || fail "update log location"

printf '{"finishedAt":"%s","version":"x","ok":true,"failures":"","logFile":""}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AICM_HOME/state/last-update.json"
out="$("$AICM" doctor 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 ]] && grep -q 'no inventory run' <<< "$out" && pass "doctor flags missing inventory run" || fail "doctor without inventory: $out"
printf '{"finishedAt":"%s","version":"x","ok":true,"clis":[]}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AICM_HOME/state/inventory.json"
out="$("$AICM" doctor 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && pass "doctor healthy after runs" || fail "doctor after runs: $out"

# Someone deletes the cleanup job: the next update run must notice.
grep -v '# aicm:clean' "$WORK/crontab.txt" > "$WORK/crontab.new"; mv "$WORK/crontab.new" "$WORK/crontab.txt"
out="$("$AICM" doctor 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 ]] && grep -q "'clean' is missing" <<< "$out" && pass "doctor notices a deleted job" || fail "deleted job: $out"
out="$("$ROOT/bin/update_ai_clis.sh" --targets none 2>&1)" || true
grep -q "notify: .*'clean' is missing" <<< "$out" && pass "update run notifies about the deleted job" || fail "update did not notify: $out"

[[ -x "$AICM_HOME/app/bin/update_ai_clis.sh" && -f "$AICM_HOME/app/SOURCE" ]] && pass "jobs run an installed copy, not the clone" || fail "installed copy"
grep -q "$AICM_HOME/app/bin/inventory_ai_clis.sh" "$WORK/crontab.txt" && pass "cron points at the installed copy" || fail "cron path"
# A registered job that has not completed for too long is caught by the others.
touch -t "$(date -d '-20 days' +%Y%m%d%H%M 2>/dev/null || date -v-20d +%Y%m%d%H%M)" "$AICM_HOME/state/schedule.json"
rm -f "$AICM_HOME/state/inventory.json"
# (the cleanup script, because the updater puts system folders first on PATH and would find a real crontab)
out="$("$ROOT/bin/clean_ai_leftovers.sh" --dry-run --rules codex-tmp 2>&1)" || true
grep -q "'inventory' has not completed for over 9 days" <<< "$out" && pass "a job that stopped completing is reported by another job" || fail "stale job: $out"
"$AICM" schedule remove >/dev/null
! grep -q '# aicm:' "$WORK/crontab.txt" && grep -q '# keep me' "$WORK/crontab.txt" && pass "schedule remove" || fail "schedule remove"

if command -v node >/dev/null 2>&1; then
  mkdir -p "$WORK/norepos"
  "$AICM" worktrees --root "$WORK/norepos" 2>&1 | grep -q '0 repositories' && pass "aicm worktrees runs the node module" || fail "aicm worktrees"
  "$AICM" config 2>&1 | grep -q 'MCP servers per CLI' && pass "aicm config runs the node module" || fail "aicm config"
fi
"$AICM" status > "$WORK/status.txt" 2>&1 || true
"$AICM" schedule install >/dev/null
"$AICM" uninstall >/dev/null
! grep -q '# aicm:' "$WORK/crontab.txt" && [[ ! -d "$AICM_HOME/app" && -d "$AICM_HOME/state" ]] && pass "uninstall removes jobs and the copy, keeps state" || fail "uninstall"
"$AICM" uninstall --purge >/dev/null
[[ ! -d "$AICM_HOME" ]] && pass "uninstall --purge removes everything" || fail "purge"
mkdir -p "$AICM_HOME"
grep -q '== disk use by cleanup rule ==' "$WORK/status.txt" && grep -q 'codex-sessions' "$WORK/status.txt" && pass "status shows rules" || fail "status output"

echo
if ((fails)); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
