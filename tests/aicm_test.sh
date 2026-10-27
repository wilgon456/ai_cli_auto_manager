#!/usr/bin/env bash
# Tests for bin/aicm (dispatcher, schedule via a fake crontab, doctor) and the updater dry run.
# Runs against a throwaway HOME and never touches the real crontab.
# shellcheck disable=SC2015 # "check && pass || fail" is intended: pass never fails
# shellcheck disable=SC2016 # code passed to bash -c is single-quoted on purpose
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home" TMPDIR="$WORK/tmp" AICM_HOME="$WORK/home/.ai-cli-auto-manager" AICM_OS=linux AICM_NOTIFY=0
# If a real codex were ever reached, it would only see the throwaway home.
export CODEX_HOME="$WORK/home/.codex" USERPROFILE="$WORK/home"
# The node checks have their own tests (tests/node); keep these runs away from real processes and repos.
export AICM_PROCESSES=0 AICM_WORKTREES=0
export BREW=/usr/bin/false AICM_CODEX_RECYCLE=0 AICM_CODEX_UNQUARANTINE=0
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
grep -q '^7 \* \* \* \* .*scheduled maintenance --dry-run .*# aicm:maintenance$' "$WORK/crontab.txt" && pass "hourly maintenance defaults to dry-run" || fail "maintenance cron line"
# cron skips missed runs, so the weekly jobs start daily and run once per week (sunday = 7).
grep -q '^5 13 \* \* \* .*/app/bin/aicm scheduled clean --weekly 7 13:05 .*# aicm:clean$' "$WORK/crontab.txt" && pass "clean cron line (daily start, due sunday)" || fail "clean cron line"
grep -q '^40 11 \* \* \* .*/app/bin/aicm scheduled inventory --weekly 3 11:40 .*# aicm:inventory$' "$WORK/crontab.txt" && pass "inventory cron line (daily start, due wednesday)" || fail "inventory cron line"
grep -q "\"path\":\"[^\"]*$WORK/fakebin" "$AICM_HOME/state/schedule.json" && pass "the PATH at install is kept for the jobs" || fail "job path: $(cat "$AICM_HOME/state/schedule.json")"
if command -v node >/dev/null 2>&1; then
  grep -q '"tools":{"node":"/' "$AICM_HOME/state/schedule.json" && pass "where node was found is recorded" || fail "tools: $(cat "$AICM_HOME/state/schedule.json")"
fi
grep -q '# keep me' "$WORK/crontab.txt" && pass "other cron lines kept" || fail "other cron line lost"
SCHED="$AICM_HOME/state/schedule.json"
grep -q '"options":{"updateAt":"06:15","inventoryDay":"3","inventoryAt":"11:40","cleanDay":"7","cleanAt":"13:05","targets":"codex,claude","maintenanceMode":"dry-run"}' "$SCHED" && pass "schedule.json keeps the install options" || fail "options: $(cat "$SCHED")"

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

# Category is stored and passed to the job. A bad value changes nothing.
cp "$WORK/crontab.txt" "$WORK/crontab.keep"
cp "$SCHED" "$WORK/sched.keep"
if "$AICM" schedule install --clean-category 'sessions,nope' >/dev/null 2>"$WORK/bad-cat.txt"; then fail "bad clean category accepted"; else pass "bad clean category rejected"; fi
cmp -s "$WORK/crontab.keep" "$WORK/crontab.txt" && cmp -s "$WORK/sched.keep" "$SCHED" && pass "bad clean category changes no schedule" || fail "bad category mutated the schedule"
"$AICM" schedule install --update-at 06:15 --inventory-day wed --inventory-at 11:40 --clean-day sun --clean-at 13:05 --targets codex,claude --clean-category 'sessions, logs' >/dev/null
grep -q '"cleanCategory":"sessions,logs"' "$SCHED" && pass "schedule.json keeps cleanCategory" || fail "cleanCategory missing: $(cat "$SCHED")"
grep -q 'scheduled clean --weekly 7 13:05 --category sessions,logs ' "$WORK/crontab.txt" && pass "cron passes the clean category" || fail "cron category: $(grep aicm:clean "$WORK/crontab.txt")"
grep -q -- '--category' "$AICM_HOME/app/bin/aicm" && pass "installed copy knows --category" || fail "installed copy has no category flag"
cp "$WORK/crontab.txt" "$WORK/crontab.cat"
sed 's/ --category sessions,logs//' "$WORK/crontab.txt" > "$WORK/crontab.new" && mv "$WORK/crontab.new" "$WORK/crontab.txt"
out="$("$AICM" schedule refresh 2>&1)" || true
grep -q 'scheduled clean --weekly 7 13:05 --category sessions,logs ' "$WORK/crontab.txt" && grep -q '"cleanCategory":"sessions,logs"' "$SCHED" && pass "refresh keeps the clean category" || fail "category refresh: $out / $(grep aicm:clean "$WORK/crontab.txt")"
# Back to the category-free schedule the rest of this file expects.
"$AICM" schedule install --update-at 06:15 --inventory-day wed --inventory-at 11:40 --clean-day sun --clean-at 13:05 --targets codex,claude >/dev/null
! grep -q -- '--category' "$WORK/crontab.txt" && ! grep -q cleanCategory "$SCHED" && pass "a schedule without a category stays compatible" || fail "empty category leaked: $(grep aicm:clean "$WORK/crontab.txt") $(cat "$SCHED")"

"$AICM" schedule install >/dev/null
[[ "$(grep -c '# aicm:' "$WORK/crontab.txt")" == 4 ]] && pass "reinstall does not duplicate" || fail "duplicate cron lines"

# Previews and invalid clean input do not create the home marker.
MARK="$WORK/markhome"
AICM_HOME="$MARK" "$AICM" clean --dry-run >/dev/null 2>&1 || true
[[ ! -e "$MARK/.aicm-home" ]] && pass "dry-run does not mark the home" || fail "dry-run created a marker"
rm -rf "$MARK"
if AICM_HOME="$MARK" "$AICM" clean --category nope >/dev/null 2>&1; then fail "bad category accepted by aicm"; fi
[[ ! -e "$MARK/.aicm-home" && ! -d "$MARK" ]] && pass "invalid clean input does not create a home" || fail "invalid clean created $(ls -A "$MARK" 2>&1)"
rm -rf "$MARK"
AICM_HOME="$MARK" "$AICM" clean --explain --category temp >/dev/null 2>&1 || true
[[ ! -e "$MARK/.aicm-home" && ! -d "$MARK/logs" && ! -d "$MARK/state" ]] && pass "explain does not mark or write state" || fail "explain wrote $(ls -A "$MARK" 2>&1)"
rm -rf "$MARK"
json_out="$(AICM_HOME="$MARK" "$AICM" clean --json --dry-run --category temp 2>"$WORK/json-preview.err")" || true
[[ "$json_out" == '{'* && "$json_out" != *'cleanup started'* ]] && pass "json preview stdout is only JSON" || fail "json preview stdout: $json_out"
[[ ! -e "$MARK/.aicm-home" && ! -d "$MARK/state" && ! -d "$MARK/logs" ]] && pass "json preview writes nothing" || fail "json preview wrote $(ls -A "$MARK" 2>&1)"
grep -q 'cleanup started' "$WORK/json-preview.err" && pass "json preview logs go to stderr" || fail "json preview stderr: $(cat "$WORK/json-preview.err")"

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
printf '{"finishedAt":"%s","ok":true}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AICM_HOME/state/last-maintenance.json"
out="$("$AICM" doctor 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && pass "doctor healthy after runs" || fail "doctor after runs: $out"
grep -q "^info: installed copy $AICM_HOME/app version $(cat "$ROOT/VERSION"); source $ROOT (version $(cat "$ROOT/VERSION"))" <<< "$out" && pass "doctor shows the installed copy, its source and versions" || fail "doctor info: $out"

# Healthy fake schedules and recent runs, but an update policy the updater would refuse: not healthy.
dsnap() { (cd "$AICM_HOME" && find . -print | LC_ALL=C sort && find . -type f ! -name '*.log' -exec cksum {} + | LC_ALL=C sort); }
for bad in '{"schemaVersion":1,"tools":{"codex":{"exclude":"yes"}}}' \
           '{"schemaVersion":1,"tools":{"gpt":{"exclude":true},"codex":{"exclude":false}}}' \
           '{"schemaVersion":1,"tools":{"nope":{"pin":"1.0.0"}}}' 'not json'; do
  printf '%s\n' "$bad" > "$AICM_HOME/update-policy.json"
  before="$(dsnap)"
  out="$("$AICM" doctor 2>&1)" && rc=0 || rc=$?
  [[ "$rc" == 1 ]] && grep -q '^problem: update policy: .*refuses to run until it is fixed' <<< "$out" && ! grep -q '^healthy' <<< "$out" && pass "doctor fails on an invalid policy: $bad" || fail "doctor with policy $bad rc=$rc: $out"
  [[ "$(dsnap)" == "$before" ]] && pass "doctor changes nothing (policy $bad)" || fail "doctor wrote into the home"
done
printf '{"schemaVersion":1,"tools":{"codex":{"exclude":true}}}\n' > "$AICM_HOME/update-policy.json"
out="$("$AICM" doctor 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -q '^info: update policy ' <<< "$out" && pass "a valid policy keeps the doctor healthy" || fail "valid policy rc=$rc: $out"
# The same policy without Node.js: the updater would refuse, so the doctor does too.
NONODE="$WORK/nonode-bin"; mkdir -p "$NONODE"
IFS=: read -r -a _path_dirs <<< "$PATH"
for d in "${_path_dirs[@]}"; do
  for f in "$d"/*; do
    n="${f##*/}"
    [[ -f "$f" && -x "$f" && "$n" != node && ! -e "$NONODE/$n" ]] && ln -s "$f" "$NONODE/$n"
  done
done
if PATH="$NONODE" command -v node >/dev/null 2>&1; then
  echo "skip - node is still reachable without its folder"
else
  out="$(PATH="$NONODE" "$AICM" doctor 2>&1)" && rc=0 || rc=$?
  [[ "$rc" == 1 ]] && grep -q 'Node.js is required to read it' <<< "$out" && grep -q '^info: Node.js not found' <<< "$out" && pass "doctor fails when the policy needs a missing Node.js" || fail "doctor without node rc=$rc: $out"
fi
rm -f "$AICM_HOME/update-policy.json"

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
printf '#!/usr/bin/env bash\necho "9.9.9 (Claude Code)"\n' > "$WORK/fakebin/claude"; chmod +x "$WORK/fakebin/claude"
out="$("$ROOT/bin/update_ai_clis.sh" --dry-run --targets claude 2>&1)" || true
grep -q "path: $WORK/fakebin/claude" <<< "$out" && pass "update uses the CLI first on the job PATH, not /usr/local or Homebrew" || fail "update PATH order: $out"
rm -f "$WORK/fakebin/claude"
NLOG="$AICM_HOME/logs/notifications.log"
grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} AI CLI Auto Manager - .*'clean' is missing" "$NLOG" && pass "notifications are kept in notifications.log" || fail "notification log: $(cat "$NLOG" 2>&1)"
out="$("$AICM" doctor 2>&1)" || true
grep -q "recent notifications" <<< "$out" && grep -q "'clean' is missing" <<< "$out" && pass "doctor shows the recent notifications" || fail "doctor notifications: $out"
cp "$NLOG" "$WORK/nlog.keep"
for i in $(seq 1 650); do echo "old $i"; done > "$NLOG"
bash -c '. "$1/lib/aicm-common.sh"; aicm_notify T "new one"' _ "$ROOT" >/dev/null
[[ "$(wc -l < "$NLOG" | tr -d ' ')" == 500 ]] && tail -n 1 "$NLOG" | grep -q 'T - new one' && pass "notifications.log keeps the last 500 lines" || fail "log trim: $(wc -l < "$NLOG")"
cp "$WORK/nlog.keep" "$NLOG"

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
# The old copy is recognized by the content of a file every copy has: any file a copy never has
# (app/MARKER, app/bin/MARKER) now makes the sync refuse to touch the copy at all (tested below), so
# it would no longer exercise the rollback paths.
echo 'old copy marker' > "$APP/LICENSE"
out="$(run_lib "$ROOT" 'cp() { return 1; }; aicm_sync_app_copy "$AICM_ROOT"' 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && "$(cat "$APP/LICENSE")" == 'old copy marker' && ! -e "$APP.new" ]] && pass "a failed copy keeps the old copy" || fail "failed copy rc=$rc: $out"
out="$(run_lib "$ROOT" 'cp() { local rc=0; command cp "$@" || rc=$?; [[ "${*: -1}" == */lib ]] && rm -f "${*: -1}/aicm-common.sh"; return $rc; }; aicm_sync_app_copy "$AICM_ROOT"' 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && "$(cat "$APP/LICENSE")" == 'old copy marker' && ! -e "$APP.new" ]] && grep -q incomplete <<< "$out" && pass "an incomplete copy is not swapped in" || fail "incomplete copy rc=$rc: $out"
out="$(run_lib "$ROOT" 'mv() { [[ "$1" == *.new ]] && return 1; command mv "$@"; }; aicm_sync_app_copy "$AICM_ROOT"' 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && "$(cat "$APP/LICENSE")" == 'old copy marker' && ! -e "$APP.old" && ! -e "$APP.new" ]] && pass "a failed swap puts the old copy back" || fail "failed swap rc=$rc: $out"
mv "$APP" "$APP.old"
out="$(run_lib "$ROOT" 'aicm_sync_app_copy "$AICM_ROOT"' 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && -x "$APP/bin/update_ai_clis.sh" && "$(cat "$APP/LICENSE")" != 'old copy marker' && ! -e "$APP.old" ]] && pass "a copy left half-swapped is completed by the next sync" || fail "recovery rc=$rc: $out"
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
[[ -f "$AICM_HOME/.aicm-home" ]] && pass "the home folder is marked as ours" || fail "no .aicm-home marker"
mkdir -p "$AICM_HOME/hooks" && echo 'echo hi' > "$AICM_HOME/hooks/post-update.sh" && echo '# mine' > "$AICM_HOME/ai-clis.local.conf"
"$AICM" uninstall --purge >/dev/null
[[ -f "$AICM_HOME/hooks/post-update.sh" && -f "$AICM_HOME/ai-clis.local.conf" && -f "$AICM_HOME/.aicm-home" && ! -e "$AICM_HOME/state" && ! -e "$AICM_HOME/logs" ]] && pass "uninstall --purge keeps hooks and local rules" || fail "purge with user files: $(ls -A "$AICM_HOME" 2>&1)"
rm -rf "$AICM_HOME/hooks" "$AICM_HOME/ai-clis.local.conf"
"$AICM" uninstall --purge >/dev/null
[[ ! -d "$AICM_HOME" ]] && pass "uninstall --purge removes everything" || fail "purge"
# AICM_HOME pointed at a folder that is not ours: refused, nothing deleted.
mkdir -p "$WORK/dotconfig/state" "$WORK/dotconfig/app" && echo keep > "$WORK/dotconfig/state/other-app.json" && echo keep > "$WORK/dotconfig/app/x"
if AICM_HOME="$WORK/dotconfig" "$AICM" uninstall --purge >/dev/null 2>&1; then fail "purge of an unmarked folder accepted"
elif [[ -f "$WORK/dotconfig/state/other-app.json" && -f "$WORK/dotconfig/app/x" ]]; then pass "uninstall --purge refuses a folder without the marker"
else fail "unmarked folder was changed"; fi
mkdir -p "$AICM_HOME"
grep -q '== disk use by cleanup rule ==' "$WORK/status.txt" && grep -q 'codex-sessions' "$WORK/status.txt" && pass "status shows rules" || fail "status output"

# --- Ownership of AICM_HOME ------------------------------------------------------------------
# Every path and checksum below a folder, to prove a command changed nothing at all.
snap() { (cd "$1" && find . -print | LC_ALL=C sort && find . -type f -exec cksum {} + | LC_ALL=C sort) 2>/dev/null; }

# An existing project folder used as AICM_HOME: help, bad flags and previews never bless it, and
# nothing that would write into it or remove from it runs.
PROJ="$WORK/project"
mkdir -p "$PROJ/src" "$PROJ/app" "$PROJ/logs" "$PROJ/state" "$PROJ/archive/notes"
echo 'int main(void) { return 0; }' > "$PROJ/src/main.c"
echo mine > "$PROJ/app/personal.txt"; echo mine > "$PROJ/app/SOURCE"; echo 1.0 > "$PROJ/app/VERSION"
echo mine > "$PROJ/logs/build.log"; echo '{}' > "$PROJ/state/last-update.json"; echo mine > "$PROJ/archive/notes/a.txt"
echo '# my inventory' > "$PROJ/inventory.md"
before="$(snap "$PROJ")"; cp "$WORK/crontab.txt" "$WORK/crontab.proj"
for args in "help" "update --help" "inventory --help" "clean --help" "update --bogus" "inventory --bogus" \
  "clean --bogus" "schedule install --clean-at 99:99" "uninstall --bogus" "update --dry-run --targets none" \
  "clean --dry-run" "clean --explain" "clean --json --dry-run" "uninstall --purge --dry-run" "uninstall --dry-run" \
  "schedule install" "update --targets none" "clean" "uninstall --purge" "doctor" "status" "version"; do
  # shellcheck disable=SC2086 # word splitting of the argument list is intended
  AICM_HOME="$PROJ" "$AICM" $args >/dev/null 2>&1 || true
done
[[ ! -e "$PROJ/.aicm-home" ]] && pass "help, bad flags, previews and refused runs never mark an existing project" || fail "a command marked the project: $(ls -A "$PROJ")"
[[ "$(snap "$PROJ")" == "$before" ]] && pass "an existing project used as AICM_HOME is left byte for byte" || fail "project changed: $(diff <(echo "$before") <(snap "$PROJ"))"
cmp -s "$WORK/crontab.proj" "$WORK/crontab.txt" && pass "a refused install or uninstall leaves the crontab alone" || fail "crontab changed for a foreign home"
out="$(AICM_HOME="$PROJ" "$AICM" schedule install 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 ]] && grep -q 'refusing to use AICM_HOME' <<< "$out" && grep -q 'personal.txt\|src' <<< "$out" && pass "schedule install names why it refuses a foreign folder" || fail "foreign install rc=$rc: $out"
out="$(AICM_HOME="$PROJ" "$AICM" uninstall --purge 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 && -f "$PROJ/app/personal.txt" && -f "$PROJ/logs/build.log" && -f "$PROJ/archive/notes/a.txt" ]] && pass "purge of a foreign folder is refused before anything changes" || fail "foreign purge rc=$rc: $out"

# The default folder name alone is not ownership, and neither is a marker the tool did not write.
DEF="$WORK/other/.ai-cli-auto-manager"
mkdir -p "$DEF/logs" && echo mine > "$DEF/notes.txt" && echo mine > "$DEF/logs/update-20240101-000000.log"
before="$(snap "$DEF")"
AICM_HOME="$DEF" "$AICM" uninstall --purge >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" == 1 && "$(snap "$DEF")" == "$before" ]] && pass "an unmarked default-named folder with foreign files is not purged" || fail "default name purge rc=$rc"
printf 'something else\n' > "$DEF/.aicm-home"; before="$(snap "$DEF")"
AICM_HOME="$DEF" "$AICM" uninstall --purge >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" == 1 && "$(snap "$DEF")" == "$before" ]] && pass "a marker with foreign content is not ownership" || fail "arbitrary marker purge rc=$rc"
rm -f "$DEF/.aicm-home"

# The installed copy is never replaced or removed while it holds a file a copy never has.
OWN="$WORK/owned"
AICM_HOME="$OWN" run_lib "$ROOT" 'aicm_sync_app_copy "$AICM_ROOT"' >/dev/null 2>&1
[[ -f "$OWN/.aicm-home" && -f "$OWN/app/SOURCE" ]] && pass "a new home is claimed and gets a copy" || fail "new home: $(ls -A "$OWN" 2>&1)"
for victim in app app.old app.new; do
  mkdir -p "$OWN/$victim"; echo 'my notes' > "$OWN/$victim/personal.txt"
  out="$(AICM_HOME="$OWN" run_lib "$ROOT" 'aicm_sync_app_copy "$AICM_ROOT"' 2>&1)" && rc=0 || rc=$?
  [[ "$rc" != 0 && "$(cat "$OWN/$victim/personal.txt")" == 'my notes' ]] && grep -q "refusing to replace or remove $OWN/$victim" <<< "$out" && pass "sync never erases $victim/personal.txt" || fail "sync with $victim/personal.txt rc=$rc: $out"
  rm -f "$OWN/$victim/personal.txt"; [[ "$victim" == app ]] || rm -rf "${OWN:?}/$victim"
done
for nested in bin lib; do
  echo 'my notes' > "$OWN/app/$nested/personal-note.txt"
  out="$(AICM_HOME="$OWN" run_lib "$ROOT" 'aicm_sync_app_copy "$AICM_ROOT"' 2>&1)" && rc=0 || rc=$?
  [[ "$rc" != 0 && -f "$OWN/app/$nested/personal-note.txt" ]] && grep -q "app/$nested/personal-note.txt is not part of the installed copy" <<< "$out" && pass "sync never erases app/$nested/personal-note.txt" || fail "nested $nested rc=$rc: $out"
  rm -f "$OWN/app/$nested/personal-note.txt"
done
PROFILE="$WORK/profile"; mkdir -p "$PROFILE"; printf 'AI CLI Auto Manager home (logs, state, archive, installed copy)\n' > "$PROFILE/.aicm-home"
out="$(HOME="$PROFILE" AICM_HOME="$PROFILE" run_lib "$ROOT" 'aicm_sync_app_copy "$AICM_ROOT"' 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && ! -e "$PROFILE/app" ]] && grep -q 'home folder' <<< "$out" && pass "a marker never makes the home folder itself an install target" || fail "profile root rc=$rc: $out"
DATED="$WORK/dated"; mkdir -p "$DATED/archive/demo/20261027"; echo keep > "$DATED/archive/demo/20261027/personal.txt"
out="$(AICM_HOME="$DATED" run_lib "$ROOT" 'aicm_sync_app_copy "$AICM_ROOT"' 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && ! -e "$DATED/.aicm-home" && ! -e "$DATED/app" ]] && pass "a dated archive folder alone is not evidence of ownership" || fail "dated archive adopted rc=$rc: $out"
echo mine > "$OWN/app/personal.txt"
out="$(AICM_HOME="$OWN" "$AICM" uninstall 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 && -f "$OWN/app/personal.txt" && -f "$OWN/app/SOURCE" ]] && grep -q 'nothing was changed' <<< "$out" && pass "uninstall refuses to remove a copy holding personal files, despite the marker" || fail "uninstall marked app rc=$rc: $out"
rm -f "$OWN/app/personal.txt"

# Nothing is uninstalled while an update (or cleanup, archive, restore) holds its lock.
sleep 60 & busy_pid=$!
mkdir -p "$TMPDIR/ai-cli-auto-manager-update-$(id -u).lockdir" && echo "$busy_pid" > "$TMPDIR/ai-cli-auto-manager-update-$(id -u).lockdir/pid"
out="$(AICM_HOME="$OWN" "$AICM" uninstall --purge 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 && -f "$OWN/app/SOURCE" ]] && grep -q 'an update run is in progress' <<< "$out" && pass "uninstall refuses while an update run holds its lock" || fail "busy uninstall rc=$rc: $out"
kill "$busy_pid" 2>/dev/null || true; wait "$busy_pid" 2>/dev/null || true
rm -rf "$TMPDIR/ai-cli-auto-manager-update-$(id -u).lockdir"

# Purge removes only what the tool wrote; --dry-run changes nothing and writes no marker, log or state.
mkdir -p "$OWN/logs" "$OWN/state/archive-index" "$OWN/state/history" "$OWN/archive/codex-images/20200101/sub" "$OWN/archive/codex-images/mine" "$OWN/hooks"
echo x > "$OWN/logs/update-20240101-000000.log"; echo x > "$OWN/logs/notifications.log"; echo mine > "$OWN/logs/personal.txt"
echo '{}' > "$OWN/state/last-update.json"; echo '{}' > "$OWN/state/schedule.json"; echo mine > "$OWN/state/personal.md"
echo '{}' > "$OWN/state/history/h1.json"; echo mine > "$OWN/state/history/notes.md"
# An archived file the index records (removed) next to one in the same dated folder it does not (kept).
echo x > "$OWN/archive/codex-images/20200101/sub/img.png"; echo mine > "$OWN/archive/codex-images/20200101/personal.txt"
printf '{"id":"m1","original":"%s","stored":"codex-images/20200101/sub/img.png","rule":"codex-images","archivedAt":"2020-01-01T00:00:00Z","size":2,"status":"archived"}\n' "$HOME/img.png" > "$OWN/state/archive-index/m1.json"
echo mine > "$OWN/archive/codex-images/mine/keep.txt"; echo mine > "$OWN/archive/readme.txt"
printf '# AI CLI inventory - test\n' > "$OWN/inventory.md"; echo 'echo hi' > "$OWN/hooks/post-update.sh"
before="$(snap "$OWN")"; cp "$WORK/crontab.txt" "$WORK/crontab.own"
out="$(AICM_HOME="$OWN" "$AICM" uninstall --purge --dry-run 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && "$(snap "$OWN")" == "$before" ]] && cmp -s "$WORK/crontab.own" "$WORK/crontab.txt" && pass "uninstall --purge --dry-run changes nothing" || fail "purge dry run rc=$rc: $out"
grep -q "would remove installed copy: $OWN/app" <<< "$out" && grep -q "would remove $OWN/logs/update-20240101-000000.log" <<< "$out" && grep -q 'logs/personal.txt' <<< "$out" && grep -q 'would remove 1 archived files listed in the archive index' <<< "$out" && grep -q 'archive/codex-images/20200101/personal.txt (not in the archive index)' <<< "$out" && pass "purge dry run lists what goes and what stays" || fail "purge dry run text: $out"
NEWH="$WORK/never-created"
AICM_HOME="$NEWH" "$AICM" uninstall --purge --dry-run >/dev/null 2>&1 || true
[[ ! -e "$NEWH" ]] && pass "purge dry run of a missing home creates nothing" || fail "dry run created $(ls -A "$NEWH")"
out="$(AICM_HOME="$OWN" "$AICM" uninstall --purge 2>&1)" && rc=0 || rc=$?
kept_ok=true
for f in logs/personal.txt state/personal.md state/history/notes.md archive/codex-images/mine/keep.txt archive/readme.txt archive/codex-images/20200101/personal.txt hooks/post-update.sh .aicm-home; do
  [[ -f "$OWN/$f" ]] || { kept_ok=false; echo "missing $f"; }
done
gone_ok=true
for f in app logs/update-20240101-000000.log logs/notifications.log state/last-update.json state/schedule.json state/archive-index state/history/h1.json archive/codex-images/20200101/sub inventory.md; do
  [[ ! -e "$OWN/$f" ]] || { gone_ok=false; echo "left $f"; }
done
[[ "$rc" == 0 && "$kept_ok" == true ]] && pass "purge keeps personal logs, state and archive files" || fail "purge lost personal files rc=$rc: $out"
[[ "$gone_ok" == true ]] && pass "purge removes what the tool wrote" || fail "purge left tool files: $out"

# Linked reserved entries are never followed or removed; the selected home itself may be a link.
OUT="$WORK/outside-logs"; mkdir -p "$OUT" && echo keep > "$OUT/update-20240101-000000.log"
rm -rf "${OWN:?}/logs" && ln -s "$OUT" "$OWN/logs"
AICM_HOME="$OWN" "$AICM" uninstall --purge >/dev/null 2>&1 || true
[[ -L "$OWN/logs" && -f "$OUT/update-20240101-000000.log" ]] && pass "purge keeps a linked logs folder and its target" || fail "linked logs were followed"
LINKED="$WORK/linked-home"; mkdir -p "$WORK/linked-target"; ln -s "$WORK/linked-target" "$LINKED"
AICM_HOME="$LINKED" run_lib "$ROOT" 'aicm_sync_app_copy "$AICM_ROOT"' >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" == 0 && -f "$WORK/linked-target/app/SOURCE" ]] && pass "an AICM_HOME chosen as a link still works" || fail "linked home rc=$rc"

# An unmarked folder of an older version (only what the tool writes) is migrated; a stray file is not.
LEG="$WORK/legacy/.ai-cli-auto-manager"
mkdir -p "$LEG/logs" "$LEG/state" "$LEG/hooks"
cp -R "$OWN/../linked-target/app" "$LEG/app"
echo x > "$LEG/logs/update-20240101-000000.log"; echo '{}' > "$LEG/state/last-update.json"; echo 'echo hi' > "$LEG/hooks/post-update.sh"
out="$(AICM_HOME="$LEG" run_lib "$ROOT" 'aicm_claim_home' 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && -f "$LEG/.aicm-home" ]] && grep -q 'marked it' <<< "$out" && pass "an unmarked older install is recognized by its structure and marked" || fail "legacy migration rc=$rc: $out"
rm -f "$LEG/.aicm-home"; echo mine > "$LEG/state/notes.md"
out="$(AICM_HOME="$LEG" run_lib "$ROOT" 'aicm_claim_home' 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 && ! -e "$LEG/.aicm-home" ]] && grep -q 'state/notes.md' <<< "$out" && pass "an older install with a foreign state file is not adopted" || fail "legacy with stray file rc=$rc: $out"

echo "# optimize: preview by default, allowlisted commands only on --apply (fake npm/uv/pnpm)"
OPT="$HOME/opt"; OPTBIN="$OPT/bin dir"
mkdir -p "$OPTBIN"
for t in npm uv pnpm; do
  printf '#!/bin/sh\nexec node "%s" %s "$@"\n' "$ROOT/tests/fixtures/optimize-fake.js" "$t" > "$OPTBIN/$t"
  chmod +x "$OPTBIN/$t"
done
printf '[{"pid":1,"ppid":0,"name":"init","cmd":"/sbin/init"}]\n' > "$OPT/procs.json"
opt() { AICM_HOME="$OPT/home" FAKE_OPTIMIZE_CALLS="$OPT/calls.jsonl" AICM_PROCESS_LIST="$OPT/procs.json" PATH="$OPTBIN:$PATH" "$AICM" optimize "$@"; }
"$AICM" help | grep -q 'aicm optimize' && pass "help lists optimize" || fail "help without optimize"
out="$(opt --json)" && rc=0 || rc=$?
[[ "$rc" == 0 && ! -e "$OPT/calls.jsonl" && ! -e "$OPT/home" ]] && grep -q '"mode":"preview"' <<< "$out" && pass "optimize previews by default: no tool runs, no AICM_HOME" || fail "optimize preview rc=$rc: $out"
out="$(opt --dry-run --tasks uv-prune)" && rc=0 || rc=$?
[[ "$rc" == 0 && ! -e "$OPT/calls.jsonl" ]] && grep -q 'uv cache prune' <<< "$out" && pass "optimize --dry-run names the command without running it" || fail "optimize dry-run: $out"
for bad in "--tasks bogus --apply" "--apply --dry-run" "--tasks" "--apply --tasks npm-verify,"; do
  # shellcheck disable=SC2086 # split on purpose
  opt $bad >/dev/null 2>&1 && rc=0 || rc=$?
  [[ "$rc" == 2 && ! -e "$OPT/calls.jsonl" && ! -e "$OPT/home" ]] && pass "optimize $bad is refused with no side effects" || fail "optimize $bad: rc=$rc"
done
out="$(opt --apply --json 2>/dev/null)" && rc=0 || rc=$?
seen="$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);console.log(l.map(c=>[c.name,...c.args].join(" ")).join(";"))' "$OPT/calls.jsonl" 2>/dev/null || true)"
[[ "$rc" == 0 && "$seen" == "npm cache verify;uv cache prune;pnpm store prune" && -f "$OPT/home/.aicm-home" && ! -e "$OPT/home/state/maintenance.lock" ]] &&
  pass "optimize --apply claims the home, runs the three allowlisted commands and releases the lock" || fail "optimize apply rc=$rc seen=$seen: $out"
rm -f "$OPT/calls.jsonl"
mkdir -p "$TMPDIR/ai-cli-auto-manager-update-$(id -u).lockdir"; printf '%s\n' "$$" > "$TMPDIR/ai-cli-auto-manager-update-$(id -u).lockdir/pid"
out="$(opt --apply --json 2>/dev/null)" && rc=0 || rc=$?
rm -rf "$TMPDIR/ai-cli-auto-manager-update-$(id -u).lockdir"
[[ "$rc" == 1 && ! -e "$OPT/calls.jsonl" ]] && grep -q '"status":"refused"' <<< "$out" && grep -q 'update run is in progress' <<< "$out" && pass "optimize --apply refuses while an update runs" || fail "optimize during update rc=$rc: $out"
mkdir -p "$OPT/foreign"; echo mine > "$OPT/foreign/notes.txt"
out="$(AICM_HOME="$OPT/foreign" FAKE_OPTIMIZE_CALLS="$OPT/calls.jsonl" AICM_PROCESS_LIST="$OPT/procs.json" PATH="$OPTBIN:$PATH" "$AICM" optimize --apply --json 2>/dev/null)" && rc=0 || rc=$?
[[ "$rc" == 1 && ! -e "$OPT/calls.jsonl" && ! -e "$OPT/foreign/.aicm-home" && ! -e "$OPT/foreign/state" ]] && grep -q '"status":"refused"' <<< "$out" && pass "optimize --apply refuses a foreign AICM_HOME untouched" || fail "optimize foreign home rc=$rc: $out"

# Hourly apply is explicit and survives refresh; opting out does not reappear on refresh.
"$AICM" schedule install --no-update --no-inventory --no-clean --maintenance-apply >/dev/null
"$AICM" schedule refresh >/dev/null
grep -q 'scheduled maintenance --apply ' "$WORK/crontab.txt" && [[ "$(grep -c '# aicm:' "$WORK/crontab.txt")" == 1 ]] && pass "hourly apply survives refresh" || fail "hourly apply refresh"
"$AICM" schedule install --no-maintenance >/dev/null
"$AICM" schedule refresh >/dev/null
! grep -q '# aicm:maintenance' "$WORK/crontab.txt" && pass "maintenance opt-out survives refresh" || fail "maintenance opt-out"
"$AICM" schedule remove >/dev/null
# A mocked launchctl writes plists under the throwaway HOME, never the real launchd service.
cat > "$WORK/fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == list ]]; then
  for f in "$HOME/Library/LaunchAgents/"*.plist; do [[ ! -f "$f" ]] || basename "$f" .plist; done
fi
exit 0
SH
chmod +x "$WORK/fakebin/launchctl"
AICM_OS=mac "$AICM" schedule install --no-update --no-inventory --no-clean >/dev/null
plist="$HOME/Library/LaunchAgents/io.github.wilgon456.ai-cli-auto-manager.maintenance.plist"
[[ "$(grep -c '<key>Hour</key>' "$plist")" == 24 ]] && grep -q '<string>--dry-run</string>' "$plist" && pass "macOS hourly plist defaults to dry-run" || fail "maintenance plist"
AICM_OS=mac "$AICM" schedule refresh >/dev/null
grep -q '<string>--dry-run</string>' "$plist" && pass "macOS refresh keeps maintenance mode" || fail "macOS maintenance refresh"
AICM_OS=mac "$AICM" schedule remove >/dev/null
[[ ! -e "$plist" ]] && pass "macOS removes its maintenance plist" || fail "macOS maintenance removal"

echo
if ((fails)); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
