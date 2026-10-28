#!/usr/bin/env bash
# Focused update-policy tests: disposable HOME, fake npm, fake CLIs. No real installs or schedules.
# shellcheck disable=SC2015 # "check && pass || fail" is intended: pass never fails
# shellcheck disable=SC2030,SC2031 # the loader tests intentionally change AICM_HOME/PATH inside $(...)
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REAL_NODE="$(command -v node)"
REAL_NODE_DIR="$(dirname "$REAL_NODE")"
export HOME="$WORK/home" TMPDIR="$WORK/tmp" AICM_HOME="$WORK/home/.ai-cli-auto-manager"
export AICM_OS=linux AICM_NOTIFY=0 AICM_PROCESSES=0 AICM_WORKTREES=0 AICM_VERIFY_SIGNATURES=0
export CODEX_HOME="$WORK/home/.codex" USERPROFILE="$WORK/home"
export AICM_CODEX_RECYCLE=0 AICM_CODEX_UNQUARANTINE=0
unset AICM_MIN_RELEASE_AGE_DAYS LOG_DIR LOCK_DIR || true

FAKE_NPM_DIR="$WORK"
export FAKE_NPM_DIR
export FAKE_NPM_PREFIX="$WORK/npmprefix"
export FAKE_NPM_ROOT="$WORK/npmprefix/lib/node_modules"
export REAL_NODE
PREFIX="$FAKE_NPM_PREFIX"
NPM_ROOT="$FAKE_NPM_ROOT"
mkdir -p "$HOME" "$TMPDIR" "$AICM_HOME/hooks" "$WORK/bin" "$WORK/ctrl" "$WORK/versions" "$PREFIX/bin" "$NPM_ROOT"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

cat > "$WORK/fake-npm.js" <<'JS'
'use strict';
const fs = require('fs');
const path = require('path');
const dir = process.env.FAKE_NPM_DIR;
const root = process.env.FAKE_NPM_ROOT;
const prefix = process.env.FAKE_NPM_PREFIX;
const args = process.argv.slice(2);
try { fs.appendFileSync(path.join(dir, 'npm.log'), args.join(' ') + '\n'); } catch {}
const regPath = path.join(dir, 'registry.json');
const reg = fs.existsSync(regPath) ? JSON.parse(fs.readFileSync(regPath, 'utf8')) : {};
function iso(days) { return new Date(Date.now() - days * 86400000).toISOString(); }
function splitSpec(spec) {
  const at = spec.lastIndexOf('@');
  return at > 0 ? [spec.slice(0, at), spec.slice(at + 1)] : [spec, ''];
}
const cmd = args[0];
if (cmd === 'prefix') { console.log(prefix); process.exit(0); }
if (cmd === 'root') { console.log(root); process.exit(0); }
if (cmd === 'ping') { process.exit(0); }
if (cmd === 'list') {
  const pkg = args[args.length - 1];
  const pj = path.join(root, pkg, 'package.json');
  if (!fs.existsSync(pj)) { process.exit(1); }
  if (args.includes('--json')) {
    const version = JSON.parse(fs.readFileSync(pj, 'utf8')).version;
    console.log(JSON.stringify({ dependencies: { [pkg]: { version } } }));
  }
  process.exit(0);
}
if (cmd === 'view') {
  const rest = args.slice(1);
  const spec = rest[0] || '';
  const [pkg, ver] = splitSpec(spec);
  const data = reg[pkg];
  if (!data) { process.exit(1); }
  const field = rest.find((a) => a === 'deprecated' || a === 'version') || '';
  const json = rest.includes('--json');
  if (field === 'deprecated') {
    if (ver && data.versions[ver] && data.versions[ver].deprecated) console.log(data.versions[ver].deprecated);
    process.exit(0);
  }
  if (field === 'version' && !json) { console.log(data.latest); process.exit(0); }
  if (json) {
    if (ver) {
      if (!data.versions[ver]) { process.exit(1); }
      console.log(JSON.stringify({ name: pkg, version: ver, scripts: {}, dist: {} }));
      process.exit(0);
    }
    const time = { created: iso(400), modified: iso(0) };
    for (const [v, info] of Object.entries(data.versions)) time[v] = iso(info.daysAgo);
    console.log(JSON.stringify({ name: pkg, 'dist-tags': { latest: data.latest }, versions: Object.keys(data.versions), time }));
    process.exit(0);
  }
  console.log(data.latest);
  process.exit(0);
}
if (cmd === 'install') {
  const gi = args.indexOf('-g');
  const spec = args[gi + 1] || '';
  const [pkg, ver] = splitSpec(spec);
  const data = reg[pkg];
  if (!data || !data.versions[ver]) { process.exit(1); }
  const pkgdir = path.join(root, pkg);
  fs.mkdirSync(pkgdir, { recursive: true });
  fs.writeFileSync(path.join(pkgdir, 'package.json'), JSON.stringify({ name: pkg, version: ver }, null, 2));
  if (data.command) fs.writeFileSync(path.join(dir, 'versions', data.command), ver + '\n');
  process.exit(0);
}
process.exit(0);
JS
cat > "$WORK/fake-npm" <<'EOF'
#!/bin/bash
exec "$REAL_NODE" "$FAKE_NPM_DIR/fake-npm.js" "$@"
EOF
cat > "$WORK/fake-brew" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$WORK/fake-npm" "$WORK/fake-brew"

cat > "$WORK/bin/standalone-cli" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
ctrl="$FAKE_NPM_DIR/ctrl/$name"
if [[ "${1:-}" == "--version" ]]; then
  line="$(cat "$ctrl" 2>/dev/null || echo 'ok 1.0.0')"
  if [[ "$line" == fail* ]]; then printf '%s\n' "${line#fail }"; exit 3; fi
  printf '%s\n' "${line#ok }"
  exit 0
fi
if [[ "${1:-}" == upgrade ]]; then
  printf '%s\n' "$name" >> "$FAKE_NPM_DIR/upgrade.log"
  [[ -f "$ctrl.next" ]] && mv -f "$ctrl.next" "$ctrl"
  exit 0
fi
exit 0
EOF
cat > "$WORK/bin/npm-cli" <<'EOF'
#!/usr/bin/env bash
name="$(basename "$0")"
if [[ "${1:-}" == "--version" ]]; then cat "$FAKE_NPM_DIR/versions/$name"; exit 0; fi
exit 0
EOF
chmod +x "$WORK/bin/standalone-cli" "$WORK/bin/npm-cli"

export NPM="$WORK/fake-npm" BREW="$WORK/fake-brew"
export PATH="$WORK/bin:$PREFIX/bin:$REAL_NODE_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
export LOCK_DIR="$WORK/update.lock"

cat > "$WORK/catalog.conf" <<'EOF'
pincli | pincli | Pin CLI | @fake/pin | | | |
solocli | solocli | Solo CLI | | | | upgrade |
schedcli | schedcli | Sched CLI | | | | upgrade |
excli | excli | Excluded CLI | | | | upgrade |
reccli | reccli | Recovery CLI | @fake/rec | | | |
EOF
cp "$WORK/catalog.conf" "$AICM_HOME/ai-clis.local.conf"
# The home is an existing install's (marked). Fixtures write state/ before runs, and an unmarked folder
# holding state/ without an installed copy is no longer adopted (no proof it is ours).
mark_home() { printf 'AI CLI Auto Manager home (logs, state, archive, installed copy)\n' > "$AICM_HOME/.aicm-home"; }
mark_home

new_cli() { # name
  cp "$WORK/bin/standalone-cli" "$WORK/bin/$1"
  chmod +x "$WORK/bin/$1"
  printf 'ok 1.0.0\n' > "$WORK/ctrl/$1"
}
new_npm_cli() { # command package
  # Like npm: the package script lives in node_modules and prefix/bin is a symlink into it, so the
  # ownership detector sees real npm ownership rather than a same-prefix standalone copy.
  mkdir -p "$NPM_ROOT/$2"
  cp "$WORK/bin/npm-cli" "$NPM_ROOT/$2/cli"
  chmod +x "$NPM_ROOT/$2/cli"
  ln -sfn "$NPM_ROOT/$2/cli" "$PREFIX/bin/$1"
  cat > "$WORK/registry.json" <<EOF
{"$2":{"latest":"2.0.0","command":"$1","versions":{"1.0.0":{"daysAgo":30},"1.2.3":{"daysAgo":30},"2.0.0":{"daysAgo":1}}}}
EOF
  set_installed "$2" "$1" "1.0.0"
}
set_installed() { # package command version
  mkdir -p "$NPM_ROOT/$1"
  printf '{\n  "name": "%s",\n  "version": "%s"\n}\n' "$1" "$3" > "$NPM_ROOT/$1/package.json"
  printf '%s\n' "$3" > "$WORK/versions/$2"
}
write_policy() { printf '%s\n' "$1" > "$AICM_HOME/update-policy.json"; }
rm_policy() { rm -f "$AICM_HOME/update-policy.json"; }
run_update() { "$ROOT/bin/update_ai_clis.sh" "$@"; }

# A PATH with the usual system tools but no `node` at all. The fake npm still starts Node through
# REAL_NODE, which is how a policy-free standalone run must behave.
NO_NODE_PATH=""
make_no_node_path() {
  local d f n
  NO_NODE_DIR="$WORK/no-node"
  mkdir -p "$NO_NODE_DIR"
  for d in /usr/bin /bin; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
      [[ -x "$f" ]] || continue
      n="$(basename "$f")"
      [[ "$n" == node ]] && continue
      [[ -e "$NO_NODE_DIR/$n" ]] && continue
      ln -s "$f" "$NO_NODE_DIR/$n"
    done
  done
  NO_NODE_PATH="$WORK/bin:$PREFIX/bin:$NO_NODE_DIR"
}
make_no_node_path

fresh_home() {
  rm -rf "$AICM_HOME"
  mkdir -p "$AICM_HOME/hooks"
  cp "$WORK/catalog.conf" "$AICM_HOME/ai-clis.local.conf"
  mark_home
  rm -f "$AICM_HOME/update-policy.json"
  : > "$WORK/npm.log"
  : > "$WORK/upgrade.log"
  rm -rf "$WORK/update.lock"
}
row() {
  python3 - "$AICM_HOME/state/last-update.json" "$1" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
want, field = sys.argv[2], sys.argv[3]
for row in doc.get("results") or []:
    if row.get("id") != want:
        continue
    cur = row
    for part in field.split("."):
        cur = cur[part]
    print("" if cur is None else cur)
    break
else:
    sys.exit("missing " + want)
PY
}
okflag() { python3 -c 'import json,sys; print("true" if json.load(open(sys.argv[1]))["ok"] else "false")' "$AICM_HOME/state/last-update.json"; }
fingerprint() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("policyFingerprint",""))' "$AICM_HOME/state/last-update.json"; }
today() { date +%Y-%m-%d; }

new_cli schedcli
new_cli solocli
new_cli excli
new_cli reccli

echo "# exclude wins over an explicit target and install-missing; the excluded probe is never run"
fresh_home
new_cli excli
printf 'fail 9.9.9\n' > "$WORK/ctrl/excli"
write_policy '{"schemaVersion":1,"tools":{"excli":{"exclude":true}}}'
out="$(run_update --targets excli --install-missing 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && "$(okflag)" == true ]] && pass "excluded run exits 0" || fail "excluded rc=$rc"
[[ "$(row excli status)" == skipped && "$(row excli reason)" == "update policy excludes this CLI" ]] && pass "excluded row is skipped with the policy reason" || fail "excluded row: $(row excli status) / $(row excli reason)"
[[ "$(row excli before.version)" == "" && "$(row excli after.version)" == "" ]] && pass "excluded CLI is not probed" || fail "excluded probe: $(row excli before.version)"
! grep -q excli "$WORK/upgrade.log" && pass "excluded self-update was not invoked" || fail "excluded update ran"
grep -q 'npm leftover cleanup skipped while update policy is configured' <<< "$out" && pass "npm leftovers are left alone while policy rules exist" || fail "leftover cleanup did not back off"

echo "# interrupted npm recovery honors exclusion and preserves state"
fresh_home
# No standalone launcher: the npm package is the only owner.
rm -f "$WORK/bin/reccli"
mkdir -p "$NPM_ROOT/@fake/.rec-AbCd1234"
printf '{"name":"@fake/rec","version":"1.0.0"}\n' > "$NPM_ROOT/@fake/.rec-AbCd1234/package.json"
rm -rf "$NPM_ROOT/@fake/rec"
mkdir -p "$AICM_HOME/state"
printf '@fake/rec\t1.0.0\n' > "$AICM_HOME/state/update-npm.tsv"
write_policy '{"schemaVersion":1,"tools":{"reccli":{"exclude":true}}}'
out="$(run_update --targets reccli 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && pass "excluded recovery run exits 0" || fail "recovery rc=$rc $out"
grep -q 'not restored because update policy excludes reccli' <<< "$out" && pass "recovery reports the exclusion" || fail "recovery message: $out"
! grep -q 'install -g @fake/rec' "$WORK/npm.log" && pass "excluded recovery never invokes npm install" || fail "recovery installed excluded package"
[[ -d "$NPM_ROOT/@fake/.rec-AbCd1234" ]] && pass "excluded backup is preserved" || fail "excluded backup removed"
grep -q '@fake/rec' "$AICM_HOME/state/update-npm.tsv" && pass "known npm state is kept for a later policy removal" || fail "known state lost"

echo "# exact pin installs the pinned version, never latest"
fresh_home
new_npm_cli pincli @fake/pin
write_policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"1.2.3","minReleaseAgeDays":7}}}'
out="$(run_update --targets pincli 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && "$(row pincli status)" == updated ]] && pass "pinned update exits 0 and is updated" || fail "pin rc=$rc status=$(row pincli status) $out"
[[ "$(row pincli after.version)" == "1.2.3" ]] && pass "pinned version is installed" || fail "after $(row pincli after.version)"
grep -q '^install -g @fake/pin@1.2.3' "$WORK/npm.log" && pass "install used the exact pin" || fail "install: $(cat "$WORK/npm.log")"
! grep -Eq '@fake/pin@(2\.0\.0|latest)' "$WORK/npm.log" && pass "pin did not fall back to latest" || fail "latest was used"

echo "# a running npm CLI also defers an exact pinned update"
fresh_home
new_npm_cli pincli @fake/pin
write_policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"1.2.3","minReleaseAgeDays":7}}}'
printf '#!/usr/bin/env perl\nsleep 120;\n' > "$NPM_ROOT/@fake/pin/serve.pl"
chmod +x "$NPM_ROOT/@fake/pin/serve.pl"
ln -sfn "$NPM_ROOT/@fake/pin/serve.pl" "$PREFIX/bin/pinserve"
pinserve & srv=$!
out="$(run_update --targets pincli 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && "$(row pincli status)" == deferred && "$(row pincli reason)" == "is running"* ]] && pass "running pinned CLI is deferred" || fail "running pin rc=$rc $(row pincli status) $(row pincli reason) $out"
! grep -q 'install -g @fake/pin' "$WORK/npm.log" && pass "the pinned update does not overwrite a running CLI" || fail "running pin installed"
kill "$srv" 2>/dev/null || true; wait "$srv" 2>/dev/null || true
rm -f "$PREFIX/bin/pinserve" "$NPM_ROOT/@fake/pin/serve.pl"

echo "# pin holds: too young, missing, deprecated, downgrade"
fresh_home
new_npm_cli pincli @fake/pin
write_policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"2.0.0","minReleaseAgeDays":7}}}'
out="$(run_update --targets pincli 2>&1)" && rc=0 || rc=$?
[[ "$(row pincli status)" == skipped && "$(row pincli reason)" == *"younger than 7 days"* ]] && pass "too-young pin is skipped" || fail "young: $(row pincli status) $(row pincli reason)"
! grep -q 'install -g @fake/pin@2.0.0' "$WORK/npm.log" && pass "too-young pin is not installed" || fail "too-young installed"

fresh_home
new_npm_cli pincli @fake/pin
write_policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"9.9.9"}}}'
out="$(run_update --targets pincli 2>&1)" && rc=0 || rc=$?
[[ "$(row pincli status)" == skipped && "$(row pincli reason)" == *"not published"* ]] && pass "unpublished pin is skipped" || fail "missing: $(row pincli status) $(row pincli reason)"
! grep -q 'install -g @fake/pin' "$WORK/npm.log" && pass "unpublished pin has no fallback install" || fail "missing pin installed"

fresh_home
new_npm_cli pincli @fake/pin
python3 - "$WORK/registry.json" <<'PY'
import json, sys
f = sys.argv[1]; doc = json.load(open(f)); doc['@fake/pin']['versions']['1.2.3']['deprecated'] = 'use 2.0.0'
json.dump(doc, open(f, 'w'))
PY
write_policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"1.2.3"}}}'
out="$(run_update --targets pincli 2>&1)" && rc=0 || rc=$?
[[ "$(row pincli status)" == skipped && "$(row pincli reason)" == *"deprecated"* ]] && pass "deprecated pin is skipped" || fail "deprecated: $(row pincli status) $(row pincli reason)"
! grep -q 'install -g @fake/pin' "$WORK/npm.log" && pass "deprecated pin is not installed" || fail "deprecated pin installed"

fresh_home
new_npm_cli pincli @fake/pin
set_installed @fake/pin pincli 2.0.0
write_policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"1.2.3"}}}'
out="$(run_update --targets pincli 2>&1)" && rc=0 || rc=$?
[[ "$(row pincli status)" == skipped && "$(row pincli reason)" == *"no automatic downgrade"* ]] && pass "downgrade is held" || fail "downgrade: $(row pincli status) $(row pincli reason)"
! grep -q 'install -g @fake/pin@1.2.3' "$WORK/npm.log" && pass "no downgrade install" || fail "downgrade attempted"

echo "# per-tool age overrides the global baseline, including zero"
fresh_home
new_npm_cli pincli @fake/pin
write_policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"2.0.0","minReleaseAgeDays":0}}}'
out="$(AICM_MIN_RELEASE_AGE_DAYS=30 run_update --targets pincli 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -qx 'install -g @fake/pin@2.0.0' "$WORK/npm.log" && pass "explicit age 0 overrides the global baseline" || fail "age override: $out"

fresh_home
new_npm_cli pincli @fake/pin
write_policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"1.2.3","minReleaseAgeDays":60}}}'
out="$(AICM_MIN_RELEASE_AGE_DAYS=3 run_update --targets pincli 2>&1)" && rc=0 || rc=$?
[[ "$(row pincli status)" == skipped && "$(row pincli reason)" == *"younger than 60 days"* ]] && pass "per-tool age overrides the global age" || fail "per-tool age: $(row pincli status) $(row pincli reason)"
! grep -q 'install -g @fake/pin' "$WORK/npm.log" && pass "too-young per-tool pin is not installed" || fail "per-tool pin installed"

echo "# pins and positive ages hold on non-npm routes without invoking anything"
fresh_home
new_cli solocli
write_policy '{"schemaVersion":1,"tools":{"solocli":{"pin":"1.2.3"}}}'
out="$(run_update --targets solocli 2>&1)" && rc=0 || rc=$?
[[ "$(row solocli status)" == skipped && "$(row solocli reason)" == *"requires the npm install route"* ]] && pass "pin on a self-update route is held" || fail "solocli pin rc=$rc: $(row solocli status) $(row solocli reason) $out"
! grep -q solocli "$WORK/upgrade.log" && pass "held self-update was not invoked" || fail "held self-update ran"

fresh_home
new_cli solocli
write_policy '{"schemaVersion":1,"tools":{"solocli":{"minReleaseAgeDays":7}}}'
out="$(run_update --targets solocli 2>&1)" && rc=0 || rc=$?
[[ "$(row solocli status)" == skipped && "$(row solocli reason)" == *"cannot be enforced"* ]] && pass "positive age on a non-npm route is held" || fail "solocli age: $(row solocli status) $(row solocli reason)"
! grep -q solocli "$WORK/upgrade.log" && pass "age-held self-update was not invoked" || fail "age-held self-update ran"

fresh_home
new_cli solocli
write_policy '{"schemaVersion":1,"tools":{"solocli":{"minReleaseAgeDays":0}}}'
out="$(run_update --targets solocli 2>&1)" && rc=0 || rc=$?
grep -q solocli "$WORK/upgrade.log" && pass "explicit age 0 opts a non-npm route out of the hold" || fail "age 0 did not run"

echo "# dry run reports effective policy and route holds"
fresh_home
new_npm_cli pincli @fake/pin
new_cli solocli
write_policy '{"schemaVersion":1,"tools":{"pincli":{"pin":"1.2.3"},"solocli":{"pin":"1.2.3"}}}'
out="$(run_update --dry-run --targets pincli,solocli 2>&1)" && rc=0 || rc=$?
grep -q '== update policy ==' <<< "$out" && pass "dry run prints the policy section" || fail "dry-run policy section"
grep -q 'pincli: pin=1.2.3' <<< "$out" && pass "dry run prints normalized rules" || fail "dry-run rules: $out"
grep -q 'hold: update policy pins solocli to 1.2.3' <<< "$out" && pass "dry run prints the non-npm hold reason" || fail "dry-run hold: $out"
[[ ! -f "$AICM_HOME/state/last-update.json" ]] && pass "dry run writes no state" || fail "dry run wrote state"

echo "# scheduled runs rerun after policy or global age changes, not after an unchanged run"
fresh_home
new_cli schedcli
write_policy '{"schemaVersion":1,"tools":{"schedcli":{}}}'
out="$(run_update --scheduled --targets schedcli 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && "$(okflag)" == true ]] && pass "scheduled policy run succeeds" || fail "scheduled rc=$rc $out"
fp1="$(fingerprint)"
[[ "$fp1" == policy:* ]] && pass "policy fingerprint is persisted" || fail "fingerprint '$fp1'"
out="$(run_update --scheduled --targets schedcli 2>&1)" && rc=0 || rc=$?
grep -q 'already updated today' <<< "$out" && pass "unchanged policy and targets skip the second scheduled run" || fail "second run: $out"
write_policy '{"schemaVersion":1,"tools":{"schedcli":{"minReleaseAgeDays":0}}}'
out="$(run_update --scheduled --targets schedcli 2>&1)" && rc=0 || rc=$?
! grep -q 'already updated today' <<< "$out" && pass "changing the policy reruns the same day" || fail "policy change skipped"
[[ "$(fingerprint)" != "$fp1" ]] && pass "fingerprint changed with the policy" || fail "fingerprint did not change"
out="$(AICM_MIN_RELEASE_AGE_DAYS=9 run_update --scheduled --targets schedcli 2>&1)" && rc=0 || rc=$?
! grep -q 'already updated today' <<< "$out" && pass "changing the global age baseline reruns the same day" || fail "global age change skipped"
rm_policy
out="$(run_update --scheduled --targets schedcli 2>&1)" && rc=0 || rc=$?
! grep -q 'already updated today' <<< "$out" && pass "removing the policy reruns the same day" || fail "policy removal skipped"
[[ "$(fingerprint)" == none:* ]] && pass "removal persists a no-policy fingerprint" || fail "no-policy fingerprint: $(fingerprint)"

echo "# legacy state without a fingerprint runs conservatively"
fresh_home
new_cli schedcli
mkdir -p "$AICM_HOME/state"
printf '{"localDate":"%s","targets":"schedcli","ok":true,"pending":false,"results":[]}\n' "$(today)" > "$AICM_HOME/state/last-update.json"
out="$(run_update --scheduled --targets schedcli 2>&1)" && rc=0 || rc=$?
! grep -q 'already updated today' <<< "$out" && pass "legacy state is not trusted for a same-day skip" || fail "legacy state skipped"

echo "# an invalid policy fails closed before logs, locks or state"
rm -rf "$AICM_HOME"
mkdir -p "$AICM_HOME"
export LOG_DIR="$AICM_HOME/logs" LOCK_DIR="$WORK/invalid.lock"
printf '{"schemaVersion":1,"tools":{"codex":{"pin":"^1.2.3"}}}\n' > "$AICM_HOME/update-policy.json"
out="$(run_update --targets pincli 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 ]] && grep -q 'update policy' <<< "$out" && pass "invalid policy fails the run" || fail "invalid rc=$rc $out"
[[ ! -e "$AICM_HOME/logs" && ! -e "$AICM_HOME/state" && ! -e "$WORK/invalid.lock" ]] && pass "invalid policy created no logs, lock or state" || fail "invalid policy had side effects"
printf '{"schemaVersion":1,"tools":{"nope":{"exclude":true}}}\n' > "$AICM_HOME/update-policy.json"
out="$(run_update --targets pincli 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 ]] && grep -q 'unknown CLI id' <<< "$out" && pass "unknown CLI id fails closed" || fail "unknown id rc=$rc $out"
[[ ! -e "$AICM_HOME/logs" && ! -e "$AICM_HOME/state" && ! -e "$WORK/invalid.lock" ]] && pass "unknown id created no logs, lock or state" || fail "unknown id had side effects"
rm -f "$AICM_HOME/update-policy.json"
unset LOG_DIR LOCK_DIR || true
export LOCK_DIR="$WORK/update.lock"

echo "# a policy file without Node.js fails closed"
rm -rf "$AICM_HOME"
mkdir -p "$AICM_HOME"
cp "$WORK/catalog.conf" "$AICM_HOME/ai-clis.local.conf"
write_policy '{"schemaVersion":1,"tools":{"schedcli":{"exclude":true}}}'
export AICM_HOME
loader_out="$(
  exec 2>&1
  PATH="$NO_NODE_PATH"
  export PATH
  . "$ROOT/lib/aicm-common.sh"
  aicm_load_catalog "" "" >/dev/null 2>&1 || true
  if aicm_policy_load 3; then rc=0; else rc=$?; fi
  echo "loader_rc=$rc"
)" || true
grep -q 'Node.js is required' <<< "$loader_out" && pass "missing Node.js is reported by the policy loader" || fail "no-node loader: $loader_out"
grep -q 'loader_rc=2' <<< "$loader_out" && pass "missing Node.js returns the fail-closed code" || fail "no-node code: $loader_out"
[[ ! -e "$AICM_HOME/logs" && ! -e "$AICM_HOME/state" ]] && pass "missing Node.js created no logs or state" || fail "no-node side effects"
rm -f "$AICM_HOME/update-policy.json"
unset LOG_DIR LOCK_DIR || true
export LOCK_DIR="$WORK/update.lock"

echo "# without a policy file the loader returns immediately and the old behavior is unchanged"
loader_out="$(
  PATH="$NO_NODE_PATH"
  export PATH
  . "$ROOT/lib/aicm-common.sh"
  aicm_policy_load 3
  echo "loader_rc=$? fingerprint=$AICM_POLICY_FINGERPRINT present=$AICM_POLICY_PRESENT"
)" 2>&1 || true
grep -q 'loader_rc=0 fingerprint=none:3 present=false' <<< "$loader_out" && pass "no policy file needs neither Node.js nor policy work" || fail "no-policy loader: $loader_out"
fresh_home
new_cli schedcli
out="$(run_update --targets schedcli 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && pass "no-policy run succeeds" || fail "backcompat rc=$rc $out"
! grep -q 'update policy' <<< "$out" && pass "no-policy run has no policy output" || fail "backcompat policy output: $out"
[[ "$(fingerprint)" == none:3 ]] && pass "no-policy fingerprint records the global age" || fail "no-policy fingerprint: $(fingerprint)"

echo "# broken policy locations fail closed instead of looking absent"
fresh_home
mkdir "$AICM_HOME/update-policy.json"
out="$(run_update --targets schedcli 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 ]] && grep -q 'not a readable file' <<< "$out" && pass "a policy directory fails the run" || fail "policy directory: rc=$rc $out"
[[ ! -e "$AICM_HOME/logs" && ! -e "$AICM_HOME/state" ]] && pass "policy directory created no logs or state" || fail "policy directory had side effects"
fresh_home
ln -s "$WORK/does-not-exist.json" "$AICM_HOME/update-policy.json"
out="$(run_update --targets schedcli 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 ]] && grep -q 'not a readable file' <<< "$out" && pass "a dangling policy symlink fails the run" || fail "dangling symlink: rc=$rc $out"
[[ ! -e "$AICM_HOME/logs" && ! -e "$AICM_HOME/state" ]] && pass "dangling symlink created no logs or state" || fail "dangling symlink had side effects"
rm -f "$AICM_HOME/update-policy.json"

echo "# the policy loader rejects empty or truncated reader output"
mkdir -p "$WORK/broken-node"
printf '#!/bin/bash\nexit 0\n' > "$WORK/broken-node/node"
chmod +x "$WORK/broken-node/node"
printf '{"schemaVersion":1,"tools":{}}\n' > "$AICM_HOME/update-policy.json"
loader_out="$(
  exec 2>&1
  PATH="$WORK/broken-node:$PATH"
  export PATH
  . "$ROOT/lib/aicm-common.sh"
  aicm_load_catalog "" "" >/dev/null 2>&1 || true
  if aicm_policy_load 3; then rc=0; else rc=$?; fi
  echo "loader_rc=$rc"
)" || true
grep -q 'incomplete output' <<< "$loader_out" && pass "empty reader output is refused" || fail "incomplete adapter: $loader_out"
grep -q 'loader_rc=1' <<< "$loader_out" && pass "empty reader output returns the fail-closed code" || fail "incomplete code: $loader_out"
rm -f "$AICM_HOME/update-policy.json"

echo "# recovery with a configured pin is held even when the version matches"
fresh_home
rm -f "$WORK/bin/reccli"
mkdir -p "$NPM_ROOT/@fake/.rec-AbCd1234"
printf '{"name":"@fake/rec","version":"1.0.0"}\n' > "$NPM_ROOT/@fake/.rec-AbCd1234/package.json"
rm -rf "$NPM_ROOT/@fake/rec"
cat > "$WORK/registry.json" <<'EOF'
{"@fake/rec":{"latest":"1.0.0","versions":{"1.0.0":{"daysAgo":1}}}}
EOF
mkdir -p "$AICM_HOME/state"
printf '@fake/rec\t1.0.0\n' > "$AICM_HOME/state/update-npm.tsv"
write_policy '{"schemaVersion":1,"tools":{"reccli":{"pin":"1.0.0"}}}'
out="$(run_update --targets reccli 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && pass "held recovery run exits 0" || fail "pin recovery rc=$rc $out"
grep -q 'automatic recovery is held' <<< "$out" && pass "matching pin recovery reports the conservative hold" || fail "pin recovery message: $out"
! grep -q 'install -g @fake/rec' "$WORK/npm.log" && pass "matching pin recovery never invokes npm install" || fail "pin recovery installed"
[[ -d "$NPM_ROOT/@fake/.rec-AbCd1234" ]] && pass "matching pin recovery preserves the backup" || fail "pin recovery removed the backup"
grep -q '@fake/rec' "$AICM_HOME/state/update-npm.tsv" && pass "matching pin recovery preserves known state" || fail "pin recovery lost state"

echo "# an explicit age with no old-enough candidate records a policy hold"
fresh_home
rm -rf "$NPM_ROOT/@fake/pin" "$PREFIX/bin/pincli" "$WORK/versions/pincli"
cat > "$WORK/registry.json" <<'EOF'
{"@fake/pin":{"latest":"2.0.0","command":"pincli","versions":{"1.0.0":{"daysAgo":4},"1.2.3":{"daysAgo":3},"2.0.0":{"daysAgo":1}}}}
EOF
write_policy '{"schemaVersion":1,"tools":{"pincli":{"minReleaseAgeDays":60}}}'
out="$(run_update --install-missing --targets pincli 2>&1)" && rc=0 || rc=$?
[[ "$(row pincli status)" == skipped && "$(row pincli reason)" == *"no release of @fake/pin is 60 days old"* ]] && pass "no-candidate age hold is a policy skip" || fail "no-candidate: $(row pincli status) / $(row pincli reason) $out"
grep -q 'no release of @fake/pin is 60 days old' <<< "$out" && pass "no-candidate age hold is reported" || fail "no-candidate output: $out"
! grep -q 'install -g @fake/pin' "$WORK/npm.log" && pass "no-candidate age does not install" || fail "no-candidate installed"

echo "# a held CLI with noisy --version output never runs the post-update hook"
fresh_home
cat > "$WORK/bin/noisycli" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
  n=\$(cat "$WORK/noise" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$WORK/noise"
  echo "noisycli 1.0.\$n"; exit 0
fi
echo upgrade >> "$WORK/upgrade.log"
EOF
chmod +x "$WORK/bin/noisycli"
printf 'noisycli | noisycli | Noisy CLI | | | | upgrade |\n' >> "$AICM_HOME/ai-clis.local.conf"
printf '{"schemaVersion":1,"tools":{"noisycli":{"pin":"1.2.3"}}}\n' > "$AICM_HOME/update-policy.json"
printf '#!/bin/sh\necho ran > "%s"\n' "$WORK/hook-ran" > "$AICM_HOME/hooks/post-update.sh"
chmod +x "$AICM_HOME/hooks/post-update.sh"
out="$(run_update --targets noisycli 2>&1)" && rc=0 || rc=$?
[[ "$(row noisycli status)" == skipped ]] && pass "held noisy CLI is skipped" || fail "noisy status: $(row noisycli status) $out"
[[ ! -e "$WORK/hook-ran" ]] && pass "held noisy CLI does not fire the post-update hook" || fail "held CLI fired the hook"
! grep -q noisycli "$WORK/upgrade.log" && pass "held noisy CLI was not updated" || fail "held noisy CLI updated"

echo "# a hidden npm Kimi copy must not take a pin while a standalone Kimi owns PATH"
fresh_home
new_cli kimi
cat > "$WORK/registry.json" <<'EOF'
{"@moonshot-ai/kimi-code":{"latest":"2.0.0","command":"kimi","versions":{"1.0.0":{"daysAgo":30},"2.0.0":{"daysAgo":1}}}}
EOF
set_installed @moonshot-ai/kimi-code kimi 1.0.0
write_policy '{"schemaVersion":1,"tools":{"kimi":{"pin":"1.2.3"}}}'
out="$(run_update --targets kimi 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && pass "standalone Kimi with a hidden npm copy exits 0" || fail "kimi rc=$rc $out"
grep -q 'requires the npm install route' <<< "$out" && pass "standalone Kimi takes the non-npm pin hold" || fail "kimi hold: $out"
! grep -q 'install -g @moonshot-ai/kimi-code' "$WORK/npm.log" && pass "hidden npm Kimi copy is not updated" || fail "hidden npm Kimi was updated"

echo "# an npm symlink Grok gets the npm route and its pin, never the vendor installer"
fresh_home
new_npm_cli grok @xai-official/grok
write_policy '{"schemaVersion":1,"tools":{"grok":{"pin":"1.0.0"}}}'
out="$(run_update --targets grok 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -q 'already at the pinned version: @xai-official/grok 1.0.0' <<< "$out" && ! grep -q 'requires the npm install route' <<< "$out" && ! grep -q 'install -g @xai-official/grok' "$WORK/npm.log" && pass "a normal npm Grok is recognized as npm and honors the pin" || fail "npm grok: rc=$rc $out"

echo "# a standalone Grok in a shared npm prefix keeps the vendor route and a pin holds it"
fresh_home
rm -f "$PREFIX/bin/grok"
set_installed @xai-official/grok grok 1.0.0
printf '#!/usr/bin/env bash\necho "grok 1.0.0"\n' > "$PREFIX/bin/grok"
chmod +x "$PREFIX/bin/grok"
write_policy '{"schemaVersion":1,"tools":{"grok":{"pin":"1.0.0"}}}'
out="$(run_update --targets grok 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -q 'requires the npm install route' <<< "$out" && grep -q 'managed by vendor' <<< "$out" && ! grep -q 'install -g @xai-official/grok' "$WORK/npm.log" && pass "a shared-prefix standalone Grok is held on the vendor route, not the hidden npm copy" || fail "standalone grok: rc=$rc $out"

echo "# an explicit per-tool age keeps a hidden npm backup and its known state"
fresh_home
new_cli reccli
rm -rf "$NPM_ROOT/@fake/rec"
mkdir -p "$NPM_ROOT/@fake/.rec-AbCd1234" "$AICM_HOME/state"
printf '{"name":"@fake/rec","version":"1.0.0"}\n' > "$NPM_ROOT/@fake/.rec-AbCd1234/package.json"
printf '@fake/rec\t1.0.0\n' > "$AICM_HOME/state/update-npm.tsv"
write_policy '{"schemaVersion":1,"tools":{"reccli":{"minReleaseAgeDays":7}}}'
out="$(run_update --targets reccli 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && [[ -d "$NPM_ROOT/@fake/.rec-AbCd1234" ]] && grep -q '@fake/rec' "$AICM_HOME/state/update-npm.tsv" && ! grep -q 'install -g @fake/rec' "$WORK/npm.log" && pass "an age rule preserves the backup and state without touching the hidden npm copy" || fail "age preservation: rc=$rc $out"
# An unselected target preserves the entry too, before policy and selection checks.
out="$(run_update --targets schedcli 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && [[ -d "$NPM_ROOT/@fake/.rec-AbCd1234" ]] && grep -q '@fake/rec' "$AICM_HOME/state/update-npm.tsv" && pass "an unselected target preserves the hidden npm state" || fail "unselected preservation: rc=$rc $out"
# With every relevant target selected and no policy, the entry is dropped, not revived daily.
rm -rf "$NPM_ROOT/@fake/.rec-AbCd1234"
rm_policy
out="$(run_update --targets reccli 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && ! grep -q '@fake/rec' "$AICM_HOME/state/update-npm.tsv" && ! grep -q 'install -g @fake/rec' "$WORK/npm.log" && pass "a no-policy selected run drops an intentionally removed hidden npm copy" || fail "no-policy drop: rc=$rc $out"

if [[ "$fails" == 0 ]]; then echo "ALL PASSED"; exit 0; fi
echo "$fails FAILED"
exit 1
