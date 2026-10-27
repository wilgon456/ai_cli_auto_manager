#!/usr/bin/env bash
# Focused update-verification tests. Disposable HOME and fake CLIs only.
# shellcheck disable=SC2015
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home" TMPDIR="$WORK/tmp" AICM_HOME="$WORK/home/.ai-cli-auto-manager"
export AICM_OS=linux AICM_NOTIFY=0 AICM_PROCESSES=0 AICM_WORKTREES=0
export CODEX_HOME="$WORK/home/.codex" USERPROFILE="$WORK/home"
export LOCK_DIR="$WORK/update.lockdir"
export AICM_CODEX_RECYCLE=0 AICM_CODEX_UNQUARANTINE=0
unset AICM_MIN_RELEASE_AGE_DAYS AICM_VERIFY_SIGNATURES AICM_ALLOW || true
PREFIX="$WORK/npmprefix"
export FAKE_NPM_DIR="$WORK" FAKE_NPM_PREFIX="$PREFIX" FAKE_NPM_ROOT="$PREFIX/lib/node_modules"
mkdir -p "$HOME" "$TMPDIR" "$AICM_HOME/hooks" "$WORK/bin" "$WORK/node_modules/.bin" "$WORK/ctrl" "$PREFIX/bin" "$FAKE_NPM_ROOT"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

cat > "$WORK/fake-npm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/npm.log"
if [[ "\${FAKE_NPM_OFFLINE:-}" == 1 && "\${1:-}" == ping ]]; then exit 1; fi
case "\${1:-}" in
  prefix) echo "$PREFIX" ;;
  root) echo "$FAKE_NPM_ROOT" ;;
  ping) exit 0 ;;
  view)
    if [[ "\$*" == *"--json"* ]]; then
      printf '%s\n' '{"name":"@fake/fresh","dist-tags":{"latest":"1.2.3"},"versions":["1.2.3"],"time":{"created":"2020-01-01T00:00:00.000Z","modified":"2020-01-02T00:00:00.000Z","1.2.3":"2020-01-02T00:00:00.000Z"}}'
    elif [[ "\$*" == *deprecated* ]]; then
      exit 0
    else
      echo 1.2.3
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
cat > "$WORK/fake-brew" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$WORK/fake-npm" "$WORK/fake-brew"
cat > "$WORK/bin/node" <<'EOF'
#!/bin/sh
if [ "${2:-}" = "candidates" ]; then echo 1.2.3; exit 0; fi
exit 0
EOF
chmod +x "$WORK/bin/node"
export NPM="$WORK/fake-npm" BREW="$WORK/fake-brew" PATH="$WORK/bin:$WORK/node_modules/.bin:$PREFIX/bin:/usr/bin:/bin"

cat > "$WORK/bin/cli" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
ctrl="${AICM_VERIFY_CTRL:?}/$name"
line="$(cat "$ctrl" 2>/dev/null || echo 'ok 1.0.0')"
action="${line%% *}"
rest="${line#* }"
[[ "$rest" == "$line" ]] && rest=""
if [[ "${1:-}" == "--version" ]]; then
  case "$action" in
    fail) printf '%s\n' "${rest:-bad}"; exit 3 ;;
    empty) exit 0 ;;
    hang) sleep 60 ;;
    *) printf '%s\n' "$name ${rest:-1.0.0}"; exit 0 ;;
  esac
fi
if [[ "${1:-}" == upgrade ]]; then
  printf '%s\n' "$name" >> "${AICM_VERIFY_CTRL}/upgrades.log"
  if [[ -f "$ctrl.next" ]]; then mv -f "$ctrl.next" "$ctrl"; fi
  now="$(cat "$ctrl" 2>/dev/null || true)"
  if [[ "${now%% *}" == delete ]]; then rm -f "$0" "$(command -v -- "$name" 2>/dev/null || true)"; fi
  if [[ "${now%% *}" == failstep ]]; then exit 1; fi
  exit 0
fi
exit 0
EOF
chmod +x "$WORK/bin/cli"
cp "$WORK/bin/cli" "$WORK/node_modules/.bin/goodcli"
printf 'ok 9.9.9\n' > "$WORK/ctrl/goodcli"
# The hidden copy must not be the one --version reports.
export AICM_VERIFY_CTRL="$WORK/ctrl"

new_cli() { # name
  cp "$WORK/bin/cli" "$WORK/bin/$1"
  chmod +x "$WORK/bin/$1"
  printf 'ok 1.0.0\n' > "$WORK/ctrl/$1"
}

set_next() { printf '%s\n' "$2" > "$WORK/ctrl/$1.next"; }

cat > "$WORK/catalog.conf" <<'EOF'
# id | command | name | npm | brew | winget | self_update | note
goodcli | goodcli | Good | | | | upgrade |
othercli | othercli | Other | | | | upgrade |
gonecli | gonecli | Gone | | | | upgrade |
deskapp | - | Desk | | | Vendor.Desk | |
pendcli | pendcli | Pend | @fake/pend | | | |
solocli | solocli | Solo | | | | upgrade |
EOF
cp "$WORK/catalog.conf" "$AICM_HOME/ai-clis.local.conf"
UPD=("$ROOT/bin/update_ai_clis.sh" --targets)

row() { # id dotted.field
  python3 - "$AICM_HOME/state/last-update.json" "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
rows = doc.get("results")
if not isinstance(rows, list):
    sys.exit("results is not a list")
want, field = sys.argv[2], sys.argv[3]
for row in rows:
    if row.get("id") != want:
        continue
    cur = row
    for part in field.split("."):
        cur = cur[part]
    if cur is None:
        print("")
    elif isinstance(cur, bool):
        print("true" if cur else "false")
    else:
        print(cur)
    break
else:
    sys.exit("missing " + want)
PY
}
ids() {
  python3 -c 'import json,sys; print(",".join(r["id"] for r in json.load(open(sys.argv[1]))["results"]))' "$AICM_HOME/state/last-update.json"
}
okflag() {
  python3 -c 'import json,sys; print("true" if json.load(open(sys.argv[1]))["ok"] else "false")' "$AICM_HOME/state/last-update.json"
}

new_cli goodcli
new_cli othercli
printf 'ok 9.9.9\n' > "$WORK/ctrl/goodcli"
# Reset the selected copy's control file after the hidden copy shared the name... new_cli wrote ok 1.0.0.
printf 'ok 1.0.0\n' > "$WORK/ctrl/goodcli"
printf '#!/bin/sh\necho ran >> "%s/hook.log"\n' "$WORK" > "$AICM_HOME/hooks/post-update.sh"
chmod +x "$AICM_HOME/hooks/post-update.sh"

echo "# healthy unchanged, selected path, selected targets only"
out="$("${UPD[@]}" goodcli 2>&1)" && rc=0 || rc=$?
echo "$out" | sed -n '1,40p'
[[ "$rc" == 0 ]] && pass "unchanged run exits 0" || fail "unchanged rc=$rc"
[[ "$(row goodcli status)" == unchanged ]] && pass "same healthy version is unchanged" || fail "status $(row goodcli status)"
[[ "$(row goodcli before.version)" == "goodcli 1.0.0" && "$(row goodcli after.version)" == "goodcli 1.0.0" ]] && pass "before and after versions recorded" || fail "versions"
[[ "$(row goodcli after.path)" == "$WORK/bin/goodcli" ]] && pass "path is the PATH-selected executable" || fail "path $(row goodcli after.path)"
[[ "$(ids)" == goodcli ]] && pass "results list only the selected target" || fail "ids $(ids)"
[[ ! -f "$WORK/hook.log" ]] && grep -q 'post-update hook skipped: no CLI version changed' <<< "$out" && pass "hook skipped when the healthy version is unchanged" || fail "hook unchanged"
! grep -q latest "$WORK/npm.log" && pass "verification does not ask for latest" || fail "npm log $(cat "$WORK/npm.log")"

echo "# healthy version changed"
set_next goodcli "ok 2.0.0"
out="$("${UPD[@]}" goodcli 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && "$(row goodcli status)" == updated && "$(row goodcli after.version)" == "goodcli 2.0.0" ]] && pass "different healthy version is updated" || fail "updated rc=$rc $(row goodcli status) $(row goodcli after.version)"
[[ "$(grep -c ran "$WORK/hook.log")" == 1 ]] && pass "hook runs when the healthy version changes" || fail "hook count"

echo "# updater succeeds but the CLI disappears"
rm -f "$WORK/node_modules/.bin/goodcli"
printf 'ok 2.0.0\n' > "$WORK/ctrl/goodcli"
set_next goodcli delete
out="$("${UPD[@]}" goodcli 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && "$(okflag)" == false && "$(row goodcli status)" == verifyFailed ]] && pass "missing CLI fails the run and state.ok" || fail "missing rc=$rc ok=$(okflag) $(row goodcli status) $(row goodcli reason)"
[[ -z "$(row goodcli after.path)" && "$(row goodcli before.exitCode)" == 0 ]] && pass "after path is empty and before exit was recorded" || fail "missing fields"
out="$("${UPD[@]}" goodcli --scheduled 2>&1)" || true
! grep -q 'already updated today' <<< "$out" && pass "verify failure does not count as the daily success" || fail "scheduled skipped: $out"
cp "$WORK/bin/cli" "$WORK/bin/goodcli"; chmod +x "$WORK/bin/goodcli"

echo "# updater succeeds but --version fails, is empty, or times out"
printf 'ok 1.0.0\n' > "$WORK/ctrl/goodcli"
set_next goodcli fail
out="$("${UPD[@]}" goodcli 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && "$(row goodcli status)" == verifyFailed && "$(row goodcli after.exitCode)" == 3 ]] && pass "nonzero --version fails the run" || fail "nonzero rc=$rc $(row goodcli status) $(row goodcli after.exitCode)"
printf 'ok 1.0.0\n' > "$WORK/ctrl/goodcli"
set_next goodcli empty
out="$("${UPD[@]}" goodcli 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && "$(row goodcli reason)" == "empty version" && "$(row goodcli after.exitCode)" == 0 ]] && pass "empty version fails the run" || fail "empty rc=$rc $(row goodcli reason)"
printf 'ok 1.0.0\n' > "$WORK/ctrl/goodcli"
set_next goodcli hang
out="$(VERSION_TIMEOUT_SECONDS=1 "${UPD[@]}" goodcli 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && "$(row goodcli reason)" == "version timed out" && "$(row goodcli after.exitCode)" == 124 ]] && pass "timed out --version fails the run" || fail "timeout rc=$rc $(row goodcli reason) $(row goodcli after.exitCode)"

echo "# a broken probe before the update is not kept when the update repairs it"
printf 'fail old\n' > "$WORK/ctrl/goodcli"
set_next goodcli "ok 4.0.0"
: > "$WORK/hook.log"
out="$("${UPD[@]}" goodcli 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && "$(okflag)" == true && "$(row goodcli status)" == updated ]] && pass "repaired CLI is a success" || fail "repair rc=$rc ok=$(okflag) $(row goodcli status)"
[[ "$(grep -c ran "$WORK/hook.log")" == 1 ]] && pass "hook runs when a healthy version appears" || fail "repair hook"

echo "# error text changes do not run the hook"
printf 'fail old\n' > "$WORK/ctrl/goodcli"
set_next goodcli "fail new"
: > "$WORK/hook.log"
out="$("${UPD[@]}" goodcli 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && "$(grep -c ran "$WORK/hook.log")" == 0 ]] && grep -q 'post-update hook skipped' <<< "$out" && pass "broken output change does not run the hook" || fail "broken hook rc=$rc"

echo "# missing, empty, nonzero, and timeout probes do not create the hook file"
rm -f "$WORK/hook.log"
for mode in delete empty fail hang; do
  cp "$WORK/bin/cli" "$WORK/bin/goodcli"
  chmod +x "$WORK/bin/goodcli"
  printf 'ok 1.0.0\n' > "$WORK/ctrl/goodcli"
  set_next goodcli "$mode"
  if [[ "$mode" == hang ]]; then
    VERSION_TIMEOUT_SECONDS=1 "${UPD[@]}" goodcli >/dev/null 2>&1 || true
  else
    "${UPD[@]}" goodcli >/dev/null 2>&1 || true
  fi
  [[ ! -f "$WORK/hook.log" ]] && pass "hook file absent after $mode" || fail "hook file created after $mode"
  rm -f "$WORK/hook.log"
done
cp "$WORK/bin/cli" "$WORK/bin/goodcli"
chmod +x "$WORK/bin/goodcli"

echo "# missing and commandless targets"
out="$("${UPD[@]}" gonecli,deskapp 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && "$(row gonecli status)" == skipped && "$(row deskapp status)" == unsupported && "$(row deskapp reason)" == "unsupported verification" ]] && pass "missing is skipped and a commandless entry is unsupported" || fail "skip rc=$rc gone=$(row gonecli status) desk=$(row deskapp status) $(row deskapp reason)"

echo "# known per-target update failure"
printf 'ok 4.0.0\n' > "$WORK/ctrl/goodcli"
set_next goodcli "failstep 4.0.0"
out="$("${UPD[@]}" goodcli 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && "$(row goodcli status)" == updateFailed && "$(row goodcli after.version)" == "goodcli 4.0.0" ]] && pass "failed updater is updateFailed while the version is still healthy" || fail "updateFailed rc=$rc $(row goodcli status) $(row goodcli reason)"

echo "# npm pending maps only to the package that was skipped"
mkdir -p "$FAKE_NPM_ROOT/@fake/pend"
printf '{\n  "name": "@fake/pend",\n  "version": "1.0.0"\n}\n' > "$FAKE_NPM_ROOT/@fake/pend/package.json"
cp "$WORK/bin/cli" "$FAKE_NPM_ROOT/@fake/pend/cli.sh"
chmod +x "$FAKE_NPM_ROOT/@fake/pend/cli.sh"
ln -sfn "$FAKE_NPM_ROOT/@fake/pend/cli.sh" "$PREFIX/bin/pendcli"
new_cli solocli
printf 'ok 1.0.0\n' > "$WORK/ctrl/pendcli"
printf 'ok 1.0.0\n' > "$WORK/ctrl/solocli"
out="$(FAKE_NPM_OFFLINE=1 "${UPD[@]}" pendcli,solocli 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && "$(row pendcli status)" == deferred && "$(row pendcli reason)" == pending ]] && pass "offline npm update is deferred with reason pending" || fail "pending rc=$rc $(row pendcli status) $(row pendcli reason) $out"
[[ "$(row solocli status)" == unchanged && -z "$(row solocli reason)" ]] && pass "a CLI that was not held is not given a fabricated pending result" || fail "solo $(row solocli status) $(row solocli reason)"
python3 -c 'import json,sys; raise SystemExit(0 if json.load(open(sys.argv[1]))["pending"] else 1)' "$AICM_HOME/state/last-update.json" && pass "run stays pending" || fail "pending flag"

echo "# npm install exits 0 but the new command is still absent"
printf 'freshcli | freshcli | Fresh | @fake/fresh | | | |\n' >> "$AICM_HOME/ai-clis.local.conf"
rm -f "$WORK/bin/freshcli" "$WORK/ctrl/upgrades.log" "$WORK/npm.log"
out="$(AICM_MIN_RELEASE_AGE_DAYS=0 AICM_VERIFY_SIGNATURES=0 "${UPD[@]}" freshcli --install-missing 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 && "$(okflag)" == false && "$(row freshcli status)" == verifyFailed && "$(row freshcli reason)" == "command missing after update" ]] && pass "successful install with no command is verifyFailed" || fail "fresh rc=$rc ok=$(okflag) $(row freshcli status) $(row freshcli reason)"
[[ ! -e "$WORK/ctrl/upgrades.log" ]] && grep -q 'install -g' "$WORK/npm.log" && pass "fake npm install ran and no self-update ran" || fail "fresh actions npm=$(cat "$WORK/npm.log" 2>/dev/null)"

if [[ "$fails" == 0 ]]; then echo "ALL PASSED"; exit 0; fi
echo "$fails FAILED"
exit 1
