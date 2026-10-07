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
# Fake pgrep and systemctl: the cron daemon "runs" unless $WORK/cron-stopped exists.
for f in pgrep systemctl; do
  printf '#!/usr/bin/env bash\n[[ ! -e "%s/cron-stopped" ]]\n' "$WORK" > "$WORK/fakebin/$f"
  chmod +x "$WORK/fakebin/$f"
done
export PATH="$WORK/fakebin:$PATH" AICM_CRONTAB="$WORK/fakebin/crontab"
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
grep -Eq '^15 6,9,12,15,18,21 \* \* \* /bin/bash \S*\.ai-cli-auto-manager/app/bin/aicm scheduled update --scheduled --targets codex\\?,claude .*# aicm:update$' "$WORK/crontab.txt" && pass "update cron line" || fail "update cron line: $(cat "$WORK/crontab.txt")"
# cron skips missed runs, so the weekly jobs start daily and run once per week (sunday = 7).
grep -q '^5 13 \* \* \* .*/app/bin/aicm scheduled clean --weekly 7 13:05 .*# aicm:clean$' "$WORK/crontab.txt" && pass "clean cron line (daily start, due sunday)" || fail "clean cron line"
grep -q '^40 11 \* \* \* .*/app/bin/aicm scheduled inventory --weekly 3 11:40 .*# aicm:inventory$' "$WORK/crontab.txt" && pass "inventory cron line (daily start, due wednesday)" || fail "inventory cron line"
grep -q "\"path\":\"[^\"]*$WORK/fakebin" "$AICM_HOME/state/schedule.json" && pass "the PATH at install is kept for the jobs" || fail "job path: $(cat "$AICM_HOME/state/schedule.json")"
if command -v node >/dev/null 2>&1; then
  grep -q '"tools":{"node":"/' "$AICM_HOME/state/schedule.json" && pass "where node was found is recorded" || fail "tools: $(cat "$AICM_HOME/state/schedule.json")"
fi
grep -q '# keep me' "$WORK/crontab.txt" && pass "other cron lines kept" || fail "other cron line lost"
SCHED="$AICM_HOME/state/schedule.json"
grep -q '"options":{"updateAt":"06:15","inventoryDay":"3","inventoryAt":"11:40","cleanDay":"7","cleanAt":"13:05","targets":"codex,claude"}' "$SCHED" && pass "schedule.json keeps the install options" || fail "options: $(cat "$SCHED")"

# Installing the same schedule again changes nothing; refresh re-registers stale jobs from the stored options.
cp "$WORK/crontab.txt" "$WORK/crontab.want"
out="$("$AICM" schedule install --update-at 06:15 --inventory-day wed --inventory-at 11:40 --clean-day sun --clean-at 13:05 --targets codex,claude 2>&1)"
cmp -s "$WORK/crontab.want" "$WORK/crontab.txt" && grep -q '^unchanged: ' <<< "$out" && ! grep -q '^registered: ' <<< "$out" && pass "same install again leaves the jobs alone" || fail "reinstall: $out"
sed 's/scheduled update/scheduled update_old_name/' "$WORK/crontab.txt" > "$WORK/crontab.new" && mv "$WORK/crontab.new" "$WORK/crontab.txt"
out="$("$AICM" schedule refresh 2>&1)" || true
cmp -s "$WORK/crontab.want" "$WORK/crontab.txt" && pass "refresh puts a stale job back with the stored options" || fail "refresh: $out / $(cat "$WORK/crontab.txt")"
out="$("$AICM" schedule refresh 2>&1)" || true
grep -q 'already match' <<< "$out" && cmp -s "$WORK/crontab.want" "$WORK/crontab.txt" && pass "refresh with nothing to change changes nothing" || fail "second refresh: $out"
# A schedule.json written by 2.5.1 has no options: refresh reads them back from the crontab lines.
installed_before="$(sed -n 's/.*"installedAt":"\([^"]*\)".*/\1/p' "$SCHED")"
sed 's/,"options":{[^}]*}//' "$SCHED" > "$SCHED.new" && mv "$SCHED.new" "$SCHED"
out="$("$AICM" schedule refresh 2>&1)" || true
cmp -s "$WORK/crontab.want" "$WORK/crontab.txt" && grep -q '"updateAt":"06:15".*"inventoryDay":"3".*"cleanDay":"7".*"targets":"codex,claude"' "$SCHED" && pass "refresh of an older schedule keeps its days and times" || fail "old refresh: $out / $(cat "$SCHED")"
grep -q "\"installedAt\":\"$installed_before\"" "$SCHED" && pass "refresh keeps installedAt" || fail "installedAt changed"

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

# No cron daemon (WSL default): nothing would ever start.
touch "$WORK/cron-stopped"
out="$("$AICM" doctor 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 ]] && grep -q 'cron is not running' <<< "$out" && pass "doctor notices that cron is not running" || fail "cron stopped: $out"
rm -f "$WORK/cron-stopped"
# node found at install but not with the jobs' PATH any more.
if grep -q '"node":"' "$SCHED"; then
  cp -p "$SCHED" "$WORK/schedule.keep"
  sed 's/"path":"[^"]*"/"path":"\/nonexistent-aicm"/' "$WORK/schedule.keep" > "$SCHED"
  out="$("$AICM" doctor 2>&1)" && rc=0 || rc=$?
  [[ "$rc" == 1 ]] && grep -q 'node was found when the schedule was installed but the scheduled jobs no longer find it' <<< "$out" && pass "doctor notices that the jobs no longer find node" || fail "node gone: $out"
  cp -p "$WORK/schedule.keep" "$SCHED"
fi
# What the crontab lines run: the PATH from the install comes first, weekly jobs run once a week.
cp -R "$AICM_HOME/app" "$WORK/fakeapp"
printf '#!/usr/bin/env bash\necho "PATH=$PATH"\n' > "$WORK/fakeapp/bin/update_ai_clis.sh"
printf '#!/usr/bin/env bash\necho "CLEAN RAN $*"\n' > "$WORK/fakeapp/bin/clean_ai_leftovers.sh"
out="$(PATH=/usr/bin:/bin /bin/bash "$WORK/fakeapp/bin/aicm" scheduled update --scheduled 2>&1)" || true
grep -q "^PATH=.*$WORK/fakebin" <<< "$out" && pass "a cron job gets the PATH captured at install" || fail "cron PATH: $out"
weekly() { /bin/bash "$WORK/fakeapp/bin/aicm" scheduled clean --weekly "$1" "$2" --dry-run 2>&1 || true; }
days_ago() { touch -t "$(date -d "-$1 days" +%Y%m%d%H%M 2>/dev/null || date -v-"$1"d +%Y%m%d%H%M)" "$AICM_HOME/state/last-clean.json"; }
today="$(date +%u)"; tomorrow=$((today % 7 + 1))
touch "$AICM_HOME/state/last-clean.json"
grep -q 'already happened' <<< "$(weekly "$today" 00:00)" && pass "weekly job done today is skipped" || fail "weekly skip today"
days_ago 8
grep -q 'CLEAN RAN --dry-run' <<< "$(weekly "$today" 00:00)" && pass "weekly job missed last week runs" || fail "weekly run after 8 days"
days_ago 3
grep -q 'already happened' <<< "$(weekly "$tomorrow" 00:00)" && pass "weekly job done after its due day is skipped" || fail "weekly skip 3 days"
days_ago 7
grep -q 'CLEAN RAN' <<< "$(weekly "$tomorrow" 00:00)" && pass "weekly job whose due day passed without a run runs" || fail "weekly run 7 days"
touch "$AICM_HOME/state/last-clean.json"
rm -rf "$WORK/fakeapp"

# Someone deletes the cleanup job: the next update run must notice.
grep -v '# aicm:clean' "$WORK/crontab.txt" > "$WORK/crontab.new"; mv "$WORK/crontab.new" "$WORK/crontab.txt"
out="$("$AICM" doctor 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 ]] && grep -q "'clean' is missing" <<< "$out" && pass "doctor notices a deleted job" || fail "deleted job: $out"
out="$("$ROOT/bin/update_ai_clis.sh" --targets none 2>&1)" || true
grep -q "notify: .*'clean' is missing" <<< "$out" && pass "update run notifies about the deleted job" || fail "update did not notify: $out"

[[ -x "$AICM_HOME/app/bin/update_ai_clis.sh" && -f "$AICM_HOME/app/SOURCE" ]] && pass "jobs run an installed copy, not the clone" || fail "installed copy"
grep -q "$AICM_HOME/app/bin/aicm scheduled inventory" "$WORK/crontab.txt" && pass "cron points at the installed copy" || fail "cron path"

# The installed copy: never downgraded, swapped only when complete, the old copy kept on any failure.
APP="$AICM_HOME/app"
run_lib() { bash -c '. "$1/lib/aicm-common.sh"; shift; eval "$*"' _ "$@"; }
printf '99.0.0\n' > "$APP/VERSION"
out="$(run_lib "$APP" aicm_update_app_copy 2>&1)"
[[ "$(cat "$APP/VERSION")" == 99.0.0 ]] && grep -q 'not newer' <<< "$out" && pass "an older version in the clone does not downgrade the copy" || fail "downgrade: $out"
printf '0.0.1\n' > "$APP/VERSION"
cp "$WORK/crontab.txt" "$WORK/crontab.before-update"
sed 's/scheduled inventory/scheduled inventory_old_name/' "$WORK/crontab.txt" > "$WORK/crontab.new" && mv "$WORK/crontab.new" "$WORK/crontab.txt"
out="$(run_lib "$APP" aicm_update_app_copy 2>&1)"
[[ "$(cat "$APP/VERSION")" == "$(cat "$ROOT/VERSION")" ]] && grep -q "updated 0.0.1 -> " <<< "$out" && pass "a newer version in the clone refreshes the copy" || fail "upgrade: $out"
grep -q "$APP/bin/aicm scheduled inventory" "$WORK/crontab.txt" && ! grep -q inventory_old_name "$WORK/crontab.txt" && pass "after the copy is refreshed the jobs are re-registered" || fail "re-register after update: $out / $(cat "$WORK/crontab.txt")"
echo old > "$APP/MARKER"
out="$(run_lib "$ROOT" 'cp() { return 1; }; aicm_sync_app_copy "$AICM_ROOT"' 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && -f "$APP/MARKER" && ! -e "$APP.new" ]] && pass "a failed copy keeps the old copy" || fail "failed copy rc=$rc: $out"
out="$(run_lib "$ROOT" 'cp() { local rc=0; command cp "$@" || rc=$?; [[ "${*: -1}" == */lib ]] && rm -f "${*: -1}/aicm-common.sh"; return $rc; }; aicm_sync_app_copy "$AICM_ROOT"' 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && -f "$APP/MARKER" && ! -e "$APP.new" ]] && grep -q incomplete <<< "$out" && pass "an incomplete copy is not swapped in" || fail "incomplete copy rc=$rc: $out"
out="$(run_lib "$ROOT" 'mv() { [[ "$1" == *.new ]] && return 1; command mv "$@"; }; aicm_sync_app_copy "$AICM_ROOT"' 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && -f "$APP/MARKER" && ! -e "$APP.old" && ! -e "$APP.new" ]] && pass "a failed swap puts the old copy back" || fail "failed swap rc=$rc: $out"
mv "$APP" "$APP.old"
out="$(run_lib "$ROOT" 'aicm_sync_app_copy "$AICM_ROOT"' 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && -x "$APP/bin/update_ai_clis.sh" && ! -e "$APP/MARKER" && ! -e "$APP.old" ]] && pass "a copy left half-swapped is completed by the next sync" || fail "recovery rc=$rc: $out"
cp "$WORK/crontab.before-update" "$WORK/crontab.txt"
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
