#!/usr/bin/env bash
# Tests for bin/inventory_ai_clis.sh and the update path for npm-managed CLIs (waiting period,
# red-flag checks, staged signature check, catalog-driven updates).
# Uses fake CLIs and a fake npm (tests/fixtures/npm-fake.js) in a throwaway HOME;
# real CLIs and the real npm are never run.
# shellcheck disable=SC2015,SC2016 # "check && pass || fail" is intended; fake scripts are written with literal $
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home" TMPDIR="$WORK/tmp" AICM_HOME="$WORK/home/.ai-cli-auto-manager" AICM_OS=linux AICM_NOTIFY=0
# If a real codex were ever reached, it would only see the throwaway home.
export CODEX_HOME="$WORK/home/.codex" USERPROFILE="$WORK/home"
# The node checks have their own tests (tests/node); keep these runs away from real processes and repos.
export AICM_PROCESSES=0 AICM_WORKTREES=0
# The update lock of these runs (the real one lives in the temp folder).
export LOCK_DIR="$WORK/update.lockdir"
unset AICM_MIN_RELEASE_AGE_DAYS AICM_VERIFY_SIGNATURES AICM_ALLOW
PREFIX="$WORK/npmprefix"
export FAKE_NPM_DIR="$WORK" FAKE_NPM_PREFIX="$PREFIX" FAKE_NPM_ROOT="$PREFIX/lib/node_modules"
mkdir -p "$HOME" "$TMPDIR" "$AICM_HOME" "$WORK/fakebin" "$WORK/solo" "$PREFIX/bin" "$FAKE_NPM_ROOT"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
calls() { cat "$WORK/npm-calls.log" 2>/dev/null || true; }

printf '#!/usr/bin/env bash\nexec node "%s/tests/fixtures/npm-fake.js" "$@"\n' "$ROOT" > "$WORK/fakebin/npm"
chmod +x "$WORK/fakebin/npm"
export NPM="$WORK/fakebin/npm"

# Always shadow Homebrew, even on a developer machine with real CLIs installed through it.
cat > "$WORK/fakebin/brew" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$WORK/brew-calls.log"
case "\${1:-}" in
  --prefix) echo "\${FAKE_BREW_PREFIX:-$WORK/brew}" ;;
  list) [[ -f "$WORK/brew-installed" ]] ;;
  outdated) echo "\${@: -1}" ;;
  update|upgrade) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/fakebin/brew"
export BREW="$WORK/fakebin/brew" AICM_CODEX_RECYCLE=0 AICM_CODEX_UNQUARANTINE=0

cat > "$WORK/registry.json" <<'EOF'
{
  "@fake/npmcli": { "latest": "1.2.0", "versions": {
    "1.0.0": { "daysAgo": 30, "provenance": true },
    "1.1.0": { "daysAgo": 10, "provenance": true },
    "1.2.0": { "daysAgo": 1, "provenance": true } } },
  "@fake/shadow": { "latest": "3.1.0", "versions": {
    "3.0.0": { "daysAgo": 40 }, "3.1.0": { "daysAgo": 20 } } },
  "@fake/newcli": { "latest": "0.5.0", "versions": { "0.5.0": { "daysAgo": 20 } } },
  "@fake/evil": { "latest": "1.1.0", "versions": {
    "1.0.0": { "daysAgo": 30, "provenance": true },
    "1.1.0": { "daysAgo": 10, "scripts": { "postinstall": "npm install -g openclaw@latest" } } } },
  "@fake/badsig": { "latest": "1.1.0", "versions": {
    "1.0.0": { "daysAgo": 30 }, "1.1.0": { "daysAgo": 10, "badsig": true } } },
  "@opencode/cli": { "latest": "2.1.0", "versions": {
    "2.0.0": { "daysAgo": 30, "provenance": true }, "2.1.0": { "daysAgo": 10, "provenance": true } } }
}
EOF

npm_cli() { # command package version: global package plus a launcher in the npm prefix
  "$NPM" install -g "$2@$3" >/dev/null
  printf '#!/usr/bin/env bash\nv="$(sed -n '"'"'s/.*"version": "\\(.*\\)".*/\\1/p'"'"' "%s/%s/package.json")"\necho "%s $v"\n' "$FAKE_NPM_ROOT" "$2" "$1" > "$PREFIX/bin/$1"
  chmod +x "$PREFIX/bin/$1"
}
npm_cli fakenpm @fake/npmcli 1.0.0
npm_cli fakeevil @fake/evil 1.0.0
npm_cli fakebadsig @fake/badsig 1.0.0
"$NPM" install -g @fake/shadow@3.0.0 >/dev/null   # hidden npm copy behind the standalone fakeshadow
: > "$WORK/npm-calls.log"
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == upgrade ]]; then echo upgraded >> "%s/solo-upgrades.log"; exit 0; fi\necho "fakesolo version 2.0.0"\n' "$WORK" > "$WORK/solo/fakesolo"
printf '#!/usr/bin/env bash\necho "fakeshadow 3.1.0"\n' > "$WORK/solo/fakeshadow"
chmod +x "$WORK/solo/fakesolo" "$WORK/solo/fakeshadow"

export PATH="$WORK/fakebin:$PREFIX/bin:$WORK/solo:$PATH"

cat > "$WORK/catalog.conf" <<'EOF'
# id        | command    | name         | npm          | brew | winget | self_update | note
fakenpm     | fakenpm    | Fake NPM     | @fake/npmcli |      |        |             |
fakesolo    | fakesolo   | Fake Solo    |              |      |        | upgrade     |
fakeshadow  | fakeshadow | Fake Shadow  | @fake/shadow |      |        |             | ships with an app
fakegone    | fakegone   | Fake Missing | @fake/gone   |      |        |             |
fakenew     | fakenew    | Fake New     | @fake/newcli |      |        |             |
fakeevil    | fakeevil   | Fake Evil    | @fake/evil   |      |        |             |
fakebadsig  | fakebadsig | Fake Badsig  | @fake/badsig |      |        |             |
EOF
cp "$WORK/catalog.conf" "$AICM_HOME/ai-clis.local.conf"
INV=("$ROOT/bin/inventory_ai_clis.sh" --catalog-file "$WORK/catalog.conf" --local-catalog-file "$WORK/none.conf")
UPD="$ROOT/bin/update_ai_clis.sh"

echo "# first inventory"
out="$("${INV[@]}" 2>&1)" && rc=0 || rc=$?
echo "$out"
[[ "$rc" == 0 ]] && pass "inventory exits 0" || fail "inventory rc=$rc"
grep -Eq '^Fake NPM +npm +1\.0\.0 +1\.2\.0 +behind +yes' <<< "$out" && pass "npm CLI behind the 3-day-old release" || fail "npm CLI row"
grep -Eq '^Fake Solo +standalone +2\.0\.0 +installed +yes' <<< "$out" && pass "standalone CLI with self-update is covered" || fail "standalone row"
grep -Eq '^Fake Shadow +standalone +3\.1\.0 +3\.1\.0 +current +no: ships with an app' <<< "$out" && pass "standalone without updater is flagged" || fail "shadow row"
grep -q 'npm copy 3.0.0 is also installed, but PATH runs' <<< "$out" && pass "hidden npm copy reported" || fail "hidden npm copy"
! grep -q 'Fake Missing' <<< "$out" && pass "missing CLI not listed" || fail "missing CLI listed"
grep -q '5 AI CLIs installed (catalog has 7)' <<< "$out" && pass "count line" || fail "count line"
grep -q '| Fake NPM | npm | 1.0.0 | 1.2.0 | behind | yes |' "$AICM_HOME/inventory.md" && pass "markdown report" || fail "markdown report"
grep -q '"id":"fakesolo"' "$AICM_HOME/state/inventory.json" && pass "json state" || fail "json state"
grep -q 'Fake Shadow: PATH runs 3.1.0 at .*fakeshadow, and an inactive npm copy is also installed (3.0.0). fix: keep one copy' <<< "$out" && pass "unreachable duplicate reported with a fix" || fail "duplicate report"
[[ "$(grep -c 'notify:' <<< "$out")" == 1 ]] && grep -q 'notify: .*Fake Shadow: PATH runs' <<< "$out" && pass "first run notifies only about the duplicate" || fail "first run notifications"
grep -q 'Fake Shadow' "$AICM_HOME/state/inventory-shadow.txt" && pass "duplicate kept in state for doctor" || fail "shadow state"

echo "# offline"
out="$("${INV[@]}" --offline 2>&1)" || true
grep -Eq '^Fake NPM +npm +1\.0\.0 +installed' <<< "$out" && pass "--offline skips latest lookups" || fail "offline: $out"
! grep -q 'notify:' <<< "$out" && pass "a known duplicate does not notify again" || fail "duplicate notified twice"

mkdir -p "$AICM_HOME/hooks"
printf '#!/usr/bin/env bash\necho ran >> "%s/hook.log"\n' "$WORK" > "$AICM_HOME/hooks/post-update.sh"
chmod +x "$AICM_HOME/hooks/post-update.sh"

echo "# update waits 3 days and checks the release"
out="$("$UPD" --targets fakenpm,fakesolo,fakeshadow 2>&1)" && rc=0 || rc=$?
echo "$out"
[[ "$rc" == 0 ]] && pass "update exits 0" || fail "update rc=$rc"
grep -qx 'install -g @fake/npmcli@1.1.0' <<< "$(calls)" && pass "installs the newest release at least 3 days old (1.1.0, not 1.2.0)" || fail "waiting period: $(calls)"
grep -qx 'stage @fake/npmcli@1.1.0 --ignore-scripts' <<< "$(calls)" && pass "staged without running install scripts" || fail "staged install"
grep -Eq '^install -g @fake/npmcli@1\.1\.0 before=[0-9]{4}-' "$WORK/npm-before.log" && grep -Eq '^stage @fake/npmcli@1\.1\.0 before=[0-9]{4}-' "$WORK/npm-before.log" && pass "staged and real install pass --before (waiting period for dependencies)" || fail "--before: $(cat "$WORK/npm-before.log" 2>/dev/null)"
grep -q 'signatures ok' <<< "$out" && pass "signature check ran" || fail "signature check"
grep -q upgraded "$WORK/solo-upgrades.log" 2>/dev/null && pass "standalone CLI self-updated" || fail "self-update not run"
grep -q 'pass: Fake Shadow is installed standalone' <<< "$out" && pass "no updater: reported, not failed" || fail "shadow handling"
! grep -q '@fake/shadow' <<< "$(calls)" && pass "hidden npm copy is not touched" || fail "hidden copy was updated"

out="$("$UPD" --targets fakenpm 2>&1)" || true
grep -q 'already current: @fake/npmcli 1.1.0' <<< "$out" && pass "nothing newer than the waiting period: not reinstalled" || fail "reinstalled: $out"
[[ "$(grep -c ran "$WORK/hook.log" 2>/dev/null)" == 1 ]] && pass "post-update hook ran once: only the run that changed a version" || fail "hook runs: $(cat "$WORK/hook.log" 2>/dev/null)"
grep -q 'post-update hook skipped: no CLI version changed' <<< "$out" && pass "hook skipped when nothing changed" || fail "hook skip message"
# npm with an old .npmrc setting prints a warning on stderr; the JSON it prints must still parse.
out="$(FAKE_NPM_WARN=1 "$UPD" --targets fakenpm 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -q 'already current: @fake/npmcli 1.1.0' <<< "$out" && pass "npm warnings on stderr do not break the JSON" || fail "npm warning: rc=$rc $out"
out="$("${INV[@]}" 2>&1)" || true
grep -Eq '^Fake NPM +npm +1\.1\.0 +1\.2\.0 +held +yes' <<< "$out" && pass "inventory shows a release in its waiting period as held" || fail "held state: $out"

out="$(AICM_MIN_RELEASE_AGE_DAYS=0 "$UPD" --targets fakenpm 2>&1)" || true
grep -qx 'install -g @fake/npmcli@1.2.0' <<< "$(calls)" && pass "AICM_MIN_RELEASE_AGE_DAYS=0 takes the newest release" || fail "no waiting period"

echo "# red flags block the update"
out="$("$UPD" --targets fakeevil 2>&1)" && rc=0 || rc=$?
echo "$out" | grep -E 'red flag|blocked|notify' || true
[[ "$rc" != 0 ]] && pass "blocked update fails the run" || fail "blocked update exit 0"
grep -q 'red flag: @fake/evil provenance: 1.0.0 was published with a provenance attestation, 1.1.0 was not' <<< "$out" && pass "lost provenance flagged" || fail "provenance flag"
grep -q 'red flag: @fake/evil install script: 1.1.0 adds "postinstall"' <<< "$out" && pass "new install script flagged" || fail "install script flag"
! grep -q '@fake/evil@1.1.0' <<< "$(calls)" && pass "flagged release is neither staged nor installed" || fail "flagged release touched"
grep -q 'notify: .*update failed' <<< "$out" && pass "blocked update notifies" || fail "no notification"
AICM_ALLOW=@fake/evil@1.1.0 "$UPD" --targets fakeevil >/dev/null 2>&1 || true
grep -qx 'install -g @fake/evil@1.1.0' <<< "$(calls)" && pass "AICM_ALLOW accepts a reviewed release" || fail "allow list"

out="$("$UPD" --targets fakebadsig 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 ]] && grep -q 'signature check failed for @fake/badsig@1.1.0' <<< "$out" && pass "bad registry signature blocks the update" || fail "bad signature: $out"
! grep -qx 'install -g @fake/badsig@1.1.0' <<< "$(calls)" && pass "release with a bad signature not installed" || fail "bad signature installed"
out="$("$UPD" --targets fakebadsig 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 ]] && grep -q 'checked earlier today' <<< "$out" && [[ "$(grep -cx 'stage @fake/badsig@1.1.0 --ignore-scripts' <<< "$(calls)")" == 1 ]] && pass "a bad signature verdict is kept for the day: no second download" || fail "verdict cache: $out"

echo "# install-missing only when named"
# Never "--targets all" here: that would also run the dedicated updaters for real CLIs on this machine.
"$UPD" --targets fakenpm --install-missing >/dev/null 2>&1 || true
! grep -q '@fake/newcli' <<< "$(calls)" && pass "unnamed CLI is not installed" || fail "unnamed CLI installed"
"$UPD" --targets fakenew --install-missing >/dev/null 2>&1 || true
grep -qx 'install -g @fake/newcli@0.5.0' <<< "$(calls)" && pass "named target is installed with --install-missing (after checks)" || fail "named install"

echo "# changes since the last inventory"
rm -f "$WORK/solo/fakesolo"
out="$("${INV[@]}" 2>&1)" || true
grep -q 'removed: Fake Solo' <<< "$out" && pass "removed CLI reported" || fail "removed"
grep -q 'new: Fake New' <<< "$out" && pass "new CLI reported" || fail "new"
grep -q 'updated: Fake NPM 1.1.0 -> 1.2.0' <<< "$out" && pass "version change reported" || fail "updated"
grep -q 'notify: .*removed: Fake Solo' <<< "$out" && pass "added/removed CLIs raise a notification" || fail "notification"

echo "# retries, registry outages and npm leftovers"
mkdir -p "$FAKE_NPM_ROOT/@fake/.npmcli-AbCd1234"
echo x > "$FAKE_NPM_ROOT/@fake/.npmcli-AbCd1234/stale.txt"
touch -t "$(date -d '-3 days' +%Y%m%d%H%M 2>/dev/null || date -v-3d +%Y%m%d%H%M)" "$FAKE_NPM_ROOT/@fake/.npmcli-AbCd1234"
# A leftover whose package is not installed may be the only copy of an interrupted install: kept.
mkdir -p "$FAKE_NPM_ROOT/@fake/.gonecli-AbCd1234"
echo '{"name":"@fake/gonecli","version":"1.0.0"}' > "$FAKE_NPM_ROOT/@fake/.gonecli-AbCd1234/package.json"
touch -t "$(date -d '-3 days' +%Y%m%d%H%M 2>/dev/null || date -v-3d +%Y%m%d%H%M)" "$FAKE_NPM_ROOT/@fake/.gonecli-AbCd1234"
out="$("$UPD" --targets fakenpm 2>&1)" || true
[[ ! -e "$FAKE_NPM_ROOT/@fake/.npmcli-AbCd1234" ]] && pass "npm staging leftover removed" || fail "npm leftover kept"
[[ -d "$FAKE_NPM_ROOT/@fake/.gonecli-AbCd1234" ]] && grep -q 'kept npm leftover .*gonecli is not installed' <<< "$out" && pass "leftover of a package that is not installed is kept" || fail "only copy removed: $out"
rm -rf "$FAKE_NPM_ROOT/@fake/.gonecli-AbCd1234"
grep -q "\"localDate\":\"$(date +%Y-%m-%d)\"" "$AICM_HOME/state/last-update.json" && grep -q '"targets":"fakenpm"' "$AICM_HOME/state/last-update.json" && pass "state records the local date and the targets" || fail "state: $(cat "$AICM_HOME/state/last-update.json")"
logs_before="$(find "$AICM_HOME/logs" -name 'update-*.log' | wc -l | tr -d ' ')"
latest_before="$(cat "$AICM_HOME/logs/latest.log")"
out="$("$UPD" --targets fakenpm --scheduled 2>&1)" || true
grep -q 'already updated today' <<< "$out" && pass "later scheduled run the same day exits at once" || fail "early exit: $out"
[[ "$(find "$AICM_HOME/logs" -name 'update-*.log' | wc -l | tr -d ' ')" == "$logs_before" && "$(cat "$AICM_HOME/logs/latest.log")" == "$latest_before" ]] && pass "a retry with nothing to do writes no log and keeps latest.log" || fail "no-op retry touched the logs"
out="$("$UPD" --targets fakenpm,fakeshadow --scheduled 2>&1)" || true
! grep -q 'already updated today' <<< "$out" && pass "a partial run does not count for a run with more targets" || fail "partial run counted as done"
out="$(FAKE_NPM_OFFLINE=1 "$UPD" --targets fakenpm 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -q 'registry unreachable' <<< "$out" && grep -q '"pending":true' "$AICM_HOME/state/last-update.json" && pass "offline run succeeds and stays pending" || fail "offline: rc=$rc $out"
out="$("$UPD" --targets fakenpm --scheduled 2>&1)" || true
! grep -q 'already updated today' <<< "$out" && pass "a pending day is retried by the scheduled run" || fail "pending day not retried"

echo "# a timeout ends what the command started"
for timeout_tool in default perl; do
  rc=0
  forced=""; [[ "$timeout_tool" == perl ]] && forced=perl
  # shellcheck disable=SC2016 # expanded by the inner bash
  AICM_TIMEOUT_TOOL="$forced" bash -c '. "$1/lib/aicm-common.sh"; aicm_timeout 2 bash -c "sleep 120 & echo \$! > \"$2/grandchild\"; wait"' _ "$ROOT" "$WORK" || rc=$?
  sleep 1
  if [[ "$rc" == 124 ]] && ! kill -0 "$(cat "$WORK/grandchild")" 2>/dev/null; then pass "timeout ($timeout_tool) returns 124 and no grandchild survives"
  else fail "timeout ($timeout_tool): rc=$rc"; kill "$(cat "$WORK/grandchild")" 2>/dev/null || true; fi
done

echo "# semver order"
wrong=""
# shellcheck disable=SC1091
. "$ROOT/lib/aicm-common.sh"
while read -r a b want; do
  if aicm_version_older "$a" "$b"; then got=-1; elif aicm_version_older "$b" "$a"; then got=1; else got=0; fi
  [[ "$got" == "$want" ]] || wrong+=" $a/$b=$got"
done <<'EOF'
2.0.0-beta.3 2.0.0 -1
2.0.0-beta.2 2.0.0-beta.11 -1
2.0.0-alpha 2.0.0-alpha.1 -1
1.2.0 1.10.0 -1
1.0.0+build 1.0.0 0
2.0.0 2.0.0-rc.1 1
EOF
[[ -z "$wrong" ]] && pass "a prerelease is older than its release" || fail "compare:$wrong"

echo "# a run that holds the lock for hours is reported"
mkdir -p "$LOCK_DIR"
echo "$$" > "$LOCK_DIR/pid"
echo "$(($(date +%s) - 4 * 3600))" > "$LOCK_DIR/started"
logs_before="$(find "$AICM_HOME/logs" -name 'update-*.log' | wc -l | tr -d ' ')"
out="$("$UPD" --targets fakeshadow --scheduled 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -q 'already active' <<< "$out" && grep -q 'notify: .*running for more than 3 hours' <<< "$out" && pass "lock held for 3+ hours raises a notification" || fail "stuck run: $out"
[[ "$(find "$AICM_HOME/logs" -name 'update-*.log' | wc -l | tr -d ' ')" == "$logs_before" ]] && pass "a blocked run writes no log" || fail "blocked run wrote a log"
out="$("$UPD" --targets fakeshadow --scheduled 2>&1)" || true
! grep -q 'notify:' <<< "$out" && pass "the stuck-run notice is not repeated every retry" || fail "stuck notice repeated"
rm -rf "$LOCK_DIR"
out="$("$UPD" --targets fakeshadow 2>&1)" || true
[[ ! -e "$LOCK_DIR" ]] && ! grep -q 'already active' <<< "$out" && pass "lock and start time are released after a run" || fail "lock left: $out"

echo "# unpublished and deprecated releases are passed over; registries without signing keys"
node -e '
const fs = require("fs"); const f = process.argv[1]; const r = JSON.parse(fs.readFileSync(f, "utf8"));
r["@fake/depcli"] = { latest: "1.2.0", versions: { "1.0.0": { daysAgo: 30 }, "1.1.0": { daysAgo: 20 },
  "1.2.0": { daysAgo: 10, deprecated: "broken, use 1.1.0" }, "1.3.0": { daysAgo: 5, unpublished: true } } };
r["@fake/nokeys"] = { latest: "1.1.0", versions: { "1.0.0": { daysAgo: 30 }, "1.1.0": { daysAgo: 10, nokeys: true } } };
fs.writeFileSync(f, JSON.stringify(r, null, 2));' "$WORK/registry.json"
npm_cli fakedep @fake/depcli 1.0.0
npm_cli fakenokeys @fake/nokeys 1.0.0
printf 'fakedep | fakedep | Fake Dep | @fake/depcli | | | |\nfakenokeys | fakenokeys | Fake NoKeys | @fake/nokeys | | | |\n' >> "$AICM_HOME/ai-clis.local.conf"
out="$("$UPD" --targets fakedep 2>&1)" || true
grep -qx 'install -g @fake/depcli@1.1.0' <<< "$(calls)" && grep -q 'skip: @fake/depcli@1.2.0 is deprecated' <<< "$out" && pass "deprecated and unpublished releases are skipped" || fail "deprecated: $out"
out="$("$UPD" --targets fakenokeys 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -qx 'install -g @fake/nokeys@1.1.0' <<< "$(calls)" && grep -q 'notify: .*publishes no signing keys' <<< "$out" && pass "registry without signing keys: warned, not failed" || fail "no keys: rc=$rc $out"

echo "# a CLI lost by an interrupted install"
was="$(sed -n 's/.*"version": "\(.*\)".*/\1/p' "$FAKE_NPM_ROOT/@fake/npmcli/package.json")"
mv "$FAKE_NPM_ROOT/@fake/npmcli" "$FAKE_NPM_ROOT/@fake/.npmcli-XyZw9876"
n_before="$(grep -cx "install -g @fake/npmcli@$was" <<< "$(calls)" || true)"
# fakenpm is not selected: recovery must not touch its backup, package or state.
out="$("$UPD" --targets fakeshadow 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && ! grep -q "restored: @fake/npmcli $was" <<< "$out" && [[ -d "$FAKE_NPM_ROOT/@fake/.npmcli-XyZw9876" ]] && [[ ! -e "$FAKE_NPM_ROOT/@fake/npmcli" ]] && grep -q '@fake/npmcli' "$AICM_HOME/state/update-npm.tsv" && pass "an unselected CLI is not recovered and its backup and state are kept" || fail "unselected recovery: rc=$rc $out"
# Explicitly named: the interrupted install is recovered at the same version.
out="$("$UPD" --targets fakeshadow,fakenpm 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -q "restored: @fake/npmcli $was" <<< "$out" && [[ "$(grep -cx "install -g @fake/npmcli@$was" <<< "$(calls)")" == $((n_before + 1)) ]] && pass "a selected CLI whose install was cut off is reinstalled at the same version" || fail "restore: rc=$rc $out"
rm -rf "$FAKE_NPM_ROOT/@fake/.npmcli-XyZw9876" "$FAKE_NPM_ROOT/@fake/newcli"
rm -f "$PREFIX/bin/fakenew"
out="$("$UPD" --targets fakenew 2>&1)" && rc=0 || rc=$?
[[ "$rc" != 0 ]] && grep -q 'notify: .*@fake/newcli disappeared since the last update' <<< "$out" && pass "a selected managed CLI that is gone is reported as a failure" || fail "missing CLI: rc=$rc $out"
out="$("$UPD" --targets fakenew 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && ! grep -q 'disappeared' <<< "$out" && pass "it is reported once, then forgotten (it may have been removed on purpose)" || fail "missing CLI repeated: rc=$rc $out"

echo "# the scheduler's own log files are trimmed"
mkdir -p "$AICM_HOME/logs"
awk 'BEGIN { for (i = 1; i <= 6000; i++) print "line " i }' > "$AICM_HOME/logs/cron.update.log"
"$UPD" --targets fakeshadow >/dev/null 2>&1 || true
[[ "$(wc -l < "$AICM_HOME/logs/cron.update.log" | tr -d ' ')" == 2000 ]] && tail -n 1 "$AICM_HOME/logs/cron.update.log" | grep -qx 'line 6000' && pass "cron.update.log is trimmed to its last 2000 lines" || fail "cron log not trimmed: $(wc -l < "$AICM_HOME/logs/cron.update.log")"

echo "# Codex from the official installer updates itself, gated like the Grok installer"
# A second Homebrew installation must not take priority over the copy on PATH.
touch "$WORK/brew-installed"
: > "$WORK/brew-calls.log"
codex_registry() { # versions as version:daysAgo ...; the last one is latest
  node -e 'const fs=require("fs"),f=process.argv[1],r=JSON.parse(fs.readFileSync(f,"utf8")),v={};let l;
    for(const a of process.argv.slice(2)){const[n,d]=a.split(":");v[n]={daysAgo:+d,provenance:true};l=n;}
    r["@openai/codex"]={latest:l,versions:v};fs.writeFileSync(f,JSON.stringify(r));' "$WORK/registry.json" "$@"
}
codex_updates() { grep -c . "$WORK/codex-updates.log" 2>/dev/null || echo 0; }
mkdir -p "$CODEX_HOME/packages/standalone/current/bin" "$WORK/codexbin" "$WORK/appbin"
echo 0.1.0 > "$WORK/codex-version"
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == update ]]; then echo updated >> "%s/codex-updates.log"; exit 0; fi\necho "codex-cli $(cat "%s/codex-version")"\n' "$WORK" "$WORK" > "$CODEX_HOME/packages/standalone/current/bin/codex"
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == update ]]; then echo updated >> "%s/app-updates.log"; exit 0; fi\necho "codex-cli 0.1.0"\n' "$WORK" > "$WORK/appbin/codex"
chmod +x "$CODEX_HOME/packages/standalone/current/bin/codex" "$WORK/appbin/codex"
ln -s "$CODEX_HOME/packages/standalone/current/bin/codex" "$WORK/codexbin/codex"
codex_registry 0.1.0:30 0.2.0:10 0.3.0:1
out="$(PATH="$WORK/codexbin:$PATH" "$UPD" --targets codex 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && "$(codex_updates)" == 0 ]] && grep -q 'hold: codex 0.2.0 is old enough, but the installer would install 0.3.0' <<< "$out" && pass "codex update waits while the newest release is in its waiting period" || fail "codex hold: rc=$rc $out"
codex_registry 0.1.0:30 0.2.0:10
out="$(PATH="$WORK/codexbin:$PATH" "$UPD" --targets codex 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && "$(codex_updates)" == 1 ]] && pass "standalone Codex is updated with codex update" || fail "codex standalone: rc=$rc $out"
! grep -Eq '^(update|upgrade)( |$)' "$WORK/brew-calls.log" && pass "standalone Codex does not update the hidden Homebrew copy" || fail "hidden Homebrew Codex touched"
echo 0.2.0 > "$WORK/codex-version"
out="$(PATH="$WORK/codexbin:$PATH" "$UPD" --targets codex 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && "$(codex_updates)" == 1 ]] && grep -q 'already current: codex 0.2.0' <<< "$out" && pass "a current Codex does not rerun the installer" || fail "codex current: rc=$rc $out"
echo 0.1.0 > "$WORK/codex-version"
out="$(PATH="$WORK/codexbin:$PATH" "$ROOT/bin/inventory_ai_clis.sh" --offline 2>&1)" || true
grep -Eq '^OpenAI Codex +standalone +0\.1\.0 .* yes$' <<< "$out" && pass "standalone Codex is covered" || fail "codex coverage: $out"
npm_cli codex @openai/codex 0.1.0
out="$(PATH="$WORK/codexbin:$PATH" "$ROOT/bin/inventory_ai_clis.sh" --offline 2>&1)" || true
grep -Eq '^OpenAI Codex +standalone +0\.1\.0 .* yes$' <<< "$out" && pass "standalone Codex stays covered with a hidden npm copy" || fail "codex shadow coverage: $out"
shadow_installs_before="$(grep -c '^install -g @openai/codex@' "$WORK/npm-calls.log" || true)"
out="$(PATH="$WORK/appbin:$PATH" "$UPD" --targets codex 2>&1)" || true
[[ ! -e "$WORK/app-updates.log" ]] && pass "a Codex copy outside the installer (desktop app) is left to its app" || fail "desktop codex updated: $out"
[[ "$(grep -c '^install -g @openai/codex@' "$WORK/npm-calls.log" || true)" == "$shadow_installs_before" ]] && pass "desktop Codex does not update its hidden npm copy" || fail "hidden npm Codex touched"
out="$(PATH="$WORK/appbin:$PATH" "$UPD" --targets codex --install-missing 2>&1)" || true
[[ "$(grep -c '^install -g @openai/codex@' "$WORK/npm-calls.log" || true)" == "$shadow_installs_before" ]] && pass "install-missing does not install over a present desktop Codex" || fail "install-missing touched present Codex: $out"
out="$(PATH="$WORK/appbin:$PATH" "$ROOT/bin/inventory_ai_clis.sh" --offline 2>&1)" || true
grep -Eq '^OpenAI Codex +standalone +0\.1\.0 .* no: the Codex desktop app' <<< "$out" && pass "desktop Codex is reported as updated by its app" || fail "desktop codex coverage: $out"

echo "# OpenCode 2.x is published as @opencode/cli"
npm_cli opencode @opencode/cli 2.0.0
# NPM unset: the npm first on PATH must be used, not one in a fallback folder such as /usr/local/bin.
out="$(env -u NPM "$UPD" --targets opencode 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -qx 'install -g @opencode/cli@2.1.0' <<< "$(calls)" && pass "OpenCode 2.x is updated through the npm on PATH, not opencode upgrade" || fail "opencode 2.x: rc=$rc $out"
! grep -Eq '^(update|upgrade)( |$)' "$WORK/brew-calls.log" && pass "npm OpenCode does not update the hidden Homebrew copy" || fail "hidden Homebrew OpenCode touched"

echo "# OpenCode V1 keeps its npm owner when V2 is also installed"
node -e 'const fs=require("fs"),f=process.argv[1],r=JSON.parse(fs.readFileSync(f,"utf8"));r["opencode-ai"]={latest:"1.1.0",versions:{"1.0.0":{daysAgo:30},"1.1.0":{daysAgo:10}}};fs.writeFileSync(f,JSON.stringify(r));' "$WORK/registry.json"
"$NPM" install -g opencode-ai@1.0.0 >/dev/null
printf '#!/bin/sh\necho opencode 1.0.0\n' > "$FAKE_NPM_ROOT/opencode-ai/opencode"
chmod +x "$FAKE_NPM_ROOT/opencode-ai/opencode"
rm -f "$PREFIX/bin/opencode"
ln -s "$FAKE_NPM_ROOT/opencode-ai/opencode" "$PREFIX/bin/opencode"
: > "$WORK/npm-calls.log"
out="$("$UPD" --targets opencode 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -qx 'install -g opencode-ai@1.1.0' <<< "$(calls)" && ! grep -q '@opencode/cli@' <<< "$(calls)" && pass "OpenCode V1 updates without switching to V2" || fail "OpenCode V1 owner: rc=$rc $out"

out="$(/bin/bash -c '. "$1/lib/aicm-common.sh"; aicm_load_catalog; i="$(aicm_cli_index amp)"; AICM_CLI_NPM[$i]=@private/custom-amp; aicm_cli_npm_names "$i"' _ "$ROOT")"
[[ "$out" == '@private/custom-amp' ]] && pass "local Amp catalog overrides do not add public aliases" || fail "Amp override widened: $out"

echo "# npm Claude also takes priority over a hidden Homebrew copy"
node -e 'const fs=require("fs"),f=process.argv[1],r=JSON.parse(fs.readFileSync(f,"utf8"));r["@anthropic-ai/claude-code"]={latest:"2.1.0",versions:{"2.0.0":{daysAgo:30},"2.1.0":{daysAgo:10}}};fs.writeFileSync(f,JSON.stringify(r));' "$WORK/registry.json"
npm_cli claude @anthropic-ai/claude-code 2.0.0
out="$("$UPD" --targets claude 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -qx 'install -g @anthropic-ai/claude-code@2.1.0' <<< "$(calls)" && pass "npm Claude is updated while Homebrew also has it" || fail "Claude copy: $out"
! grep -Eq '^(update|upgrade)( |$)' "$WORK/brew-calls.log" && pass "npm Claude does not update the hidden Homebrew copy" || fail "hidden Homebrew Claude touched"

echo "# the active Homebrew copy still updates"
mkdir -p "$WORK/brew/Cellar/codex/0.1/bin" "$WORK/brewbin"
printf '#!/bin/sh\necho codex-cli 0.1.0\n' > "$WORK/brew/Cellar/codex/0.1/bin/codex"
chmod +x "$WORK/brew/Cellar/codex/0.1/bin/codex"
ln -s "$WORK/brew/Cellar/codex/0.1/bin/codex" "$WORK/brewbin/codex"
out="$(PATH="$WORK/brewbin:$PATH" "$UPD" --targets codex 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -qx update "$WORK/brew-calls.log" && grep -qx 'upgrade --cask codex' "$WORK/brew-calls.log" && pass "active Homebrew Codex is updated through the fake brew" || fail "active brew: $out"

echo "# Amp uses @ampcode/cli, keeps legacy @sourcegraph/amp, and updates the PATH owner"
node -e 'const fs=require("fs"),f=process.argv[1],r=JSON.parse(fs.readFileSync(f,"utf8"));
  r["@ampcode/cli"]={latest:"1.1.0",versions:{"1.0.0":{daysAgo:30},"1.1.0":{daysAgo:10}}};
  r["@sourcegraph/amp"]={latest:"0.2.0",versions:{"0.1.0":{daysAgo:30},"0.2.0":{daysAgo:10}}};
  fs.writeFileSync(f,JSON.stringify(r));' "$WORK/registry.json"
amp_pkg_cli() { # package version: launcher inside the package so PATH ownership is proven
  "$NPM" install -g "$1@$2" >/dev/null
  printf '#!/usr/bin/env bash\necho "amp %s"\n' "$2" > "$FAKE_NPM_ROOT/$1/amp"
  chmod +x "$FAKE_NPM_ROOT/$1/amp"
  mkdir -p "$PREFIX/bin"
  ln -sfn "$FAKE_NPM_ROOT/$1/amp" "$PREFIX/bin/amp"
}
amp_pkg_cli @ampcode/cli 1.0.0
: > "$WORK/npm-calls.log"
out="$("$UPD" --targets amp 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -qx 'install -g @ampcode/cli@1.1.0' <<< "$(calls)" && pass "canonical Amp package is updated" || fail "amp canonical: rc=$rc $out"
! grep -q '@sourcegraph/amp' <<< "$(calls)" && pass "missing legacy Amp package is not checked as the install" || fail "legacy probed on canonical-only: $(calls)"
rm -f "$PREFIX/bin/amp"
"$NPM" install -g @sourcegraph/amp@0.1.0 >/dev/null
amp_pkg_cli @sourcegraph/amp 0.1.0
: > "$WORK/npm-calls.log"
out="$("$UPD" --targets amp 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -qx 'install -g @sourcegraph/amp@0.2.0' <<< "$(calls)" && pass "legacy Amp package is updated when it owns PATH" || fail "amp legacy: rc=$rc $out"
! grep -q '@ampcode/cli@' <<< "$(calls)" && pass "canonical Amp is not updated while PATH is the legacy copy" || fail "canonical updated behind legacy: $(calls)"
"$NPM" install -g @ampcode/cli@1.0.0 >/dev/null
amp_pkg_cli @ampcode/cli 1.0.0
: > "$WORK/npm-calls.log"
out="$("$UPD" --targets amp 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -qx 'install -g @ampcode/cli@1.1.0' <<< "$(calls)" && pass "PATH-owning Amp package is selected when both exist" || fail "amp both: rc=$rc $out"
! grep -q '@sourcegraph/amp@0.2.0' <<< "$(calls)" && pass "hidden Amp alternate is not updated" || fail "hidden amp updated: $(calls)"
out="$("$ROOT/bin/inventory_ai_clis.sh" --offline --local-catalog-file "$WORK/none.conf" 2>&1)" || true
grep -Eq '^Amp +npm +1\.0\.0 ' <<< "$out" && pass "inventory reports the Amp copy the updater uses" || fail "amp inventory: $out"

echo "# Copilot Homebrew cask is covered and updated on the installed channel"
mkdir -p "$WORK/brew/Caskroom/copilot-cli/0.1/bin" "$WORK/caskbin"
printf '#!/bin/sh\necho copilot 0.1.0\n' > "$WORK/brew/Caskroom/copilot-cli/0.1/bin/copilot"
chmod +x "$WORK/brew/Caskroom/copilot-cli/0.1/bin/copilot"
ln -sfn "$WORK/brew/Caskroom/copilot-cli/0.1/bin/copilot" "$WORK/caskbin/copilot"
touch "$WORK/brew-installed"
: > "$WORK/brew-calls.log"
out="$(PATH="$WORK/caskbin:$PATH" "$ROOT/bin/inventory_ai_clis.sh" --offline --local-catalog-file "$WORK/none.conf" 2>&1)" || true
grep -Eq '^GitHub Copilot CLI +brew .* yes$' <<< "$out" && pass "brew Copilot is covered" || fail "copilot brew coverage: $out"
out="$(PATH="$WORK/caskbin:$PATH" "$UPD" --targets copilot 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -qx 'upgrade --cask copilot-cli' "$WORK/brew-calls.log" && pass "installed brew Copilot is upgraded" || fail "copilot brew update: rc=$rc $out"
npm_installs_before="$(grep -c '^install -g @github/copilot' "$WORK/npm-calls.log" || true)"
out="$(PATH="$WORK/caskbin:$PATH" "$UPD" --targets copilot --install-missing 2>&1)" || true
[[ "$(grep -c '^install -g @github/copilot' "$WORK/npm-calls.log" || true)" == "$npm_installs_before" ]] && pass "Copilot stays on the brew channel" || fail "copilot channel changed: $out"

echo "# shared npm/Homebrew prefix: Caskroom ownership wins; standalone agy is not brew"
SHARED="$WORK/sharedprefix"
mkdir -p "$SHARED/bin" "$SHARED/lib/node_modules" "$SHARED/Caskroom/codex/0.1/bin"
printf '#!/bin/sh\necho "codex-cli 0.1.0"\n' > "$SHARED/Caskroom/codex/0.1/bin/codex"
chmod +x "$SHARED/Caskroom/codex/0.1/bin/codex"
ln -sfn "$SHARED/Caskroom/codex/0.1/bin/codex" "$SHARED/bin/codex"
printf '#!/bin/sh\necho "agy 1.0.0"\n' > "$SHARED/bin/agy"
chmod +x "$SHARED/bin/agy"
: > "$WORK/brew-calls.log"
out="$(FAKE_NPM_PREFIX="$SHARED" FAKE_NPM_ROOT="$SHARED/lib/node_modules" FAKE_BREW_PREFIX="$SHARED" PATH="$SHARED/bin:$WORK/fakebin:$PATH" "$ROOT/bin/inventory_ai_clis.sh" --offline --local-catalog-file "$WORK/none.conf" 2>&1)" || true
grep -Eq '^OpenAI Codex +brew .* yes$' <<< "$out" && pass "shared-prefix Caskroom Codex is brew" || fail "shared prefix brew: $out"
grep -Eq '^Antigravity CLI +standalone .* yes$' <<< "$out" && pass "shared-prefix agy is standalone, not brew" || fail "shared prefix agy: $out"
out="$(FAKE_NPM_PREFIX="$SHARED" FAKE_NPM_ROOT="$SHARED/lib/node_modules" FAKE_BREW_PREFIX="$SHARED" PATH="$SHARED/bin:$WORK/fakebin:$PATH" "$UPD" --targets codex 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -qx 'upgrade --cask codex' "$WORK/brew-calls.log" && pass "shared-prefix Caskroom Codex is updated through brew" || fail "shared prefix update: rc=$rc $out"
! grep -q '@openai/codex' <<< "$(calls)" && pass "shared-prefix Codex is not treated as npm" || fail "shared prefix npm: $(calls)"

# Regression: short-lived alias producers must not overlap while the captured updater keeps
# walking the recovery catalog. Repeats also prove Caskroom stays on brew in a shared npm prefix.
repeat_ok=true
for repeat in 1 2 3 4; do
  out="$(FAKE_NPM_PREFIX="$SHARED" FAKE_NPM_ROOT="$SHARED/lib/node_modules" FAKE_BREW_PREFIX="$SHARED" PATH="$SHARED/bin:$WORK/fakebin:$PATH" "$UPD" --targets codex 2>&1)" && rc=0 || rc=$?
  [[ "$rc" == 0 ]] || { repeat_ok=false; fail "repeated captured updater $repeat: rc=$rc $out"; }
done
[[ "$repeat_ok" == true && "$(grep -cx 'upgrade --cask codex' "$WORK/brew-calls.log")" == 5 ]] && pass "five captured updates preserve the shared-prefix brew route" || fail "repeated brew route"
! grep -q '@openai/codex' <<< "$(calls)" && pass "repeated brew updates never install the hidden npm Codex" || fail "repeat selected npm instead of brew"

# A list can end with a false alias condition and still contain valid candidates.
for alias_kind in amp opencode; do
  case "$alias_kind" in amp) alias_pkg=@sourcegraph/amp; expected=$'@sourcegraph/amp\n@ampcode/cli' ;; *) alias_pkg=opencode-ai; expected=$'opencode-ai\n@opencode/cli' ;; esac
  rc=0
  # shellcheck disable=SC2016 # literal inner shell, not the test's arrays
  out="$(/bin/bash -c '. "$1/lib/aicm-common.sh"; AICM_CLI_ID=("$2"); AICM_CLI_NPM=("$3"); aicm_cli_npm_names 0' _ "$ROOT" "$alias_kind" "$alias_pkg")" || rc=$?
  [[ "$rc" == 0 && "$out" == "$expected" ]] && pass "$alias_kind legacy list returns success and preserves canonical fallback" || fail "alias list $alias_kind: rc=$rc $out"
done

echo "# bad catalog"
printf 'Bad Id | x | x |  |  |  |  |\n' > "$WORK/bad.conf"
if "$ROOT/bin/inventory_ai_clis.sh" --catalog-file "$WORK/bad.conf" >/dev/null 2>&1; then fail "bad catalog accepted"; else pass "bad catalog rejected"; fi

echo
if ((fails)); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
