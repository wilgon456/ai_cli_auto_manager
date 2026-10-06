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
    "1.0.0": { "daysAgo": 30 }, "1.1.0": { "daysAgo": 10, "badsig": true } } }
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
grep -q 'Fake Shadow: PATH runs 3.1.0 at .*fakeshadow, but the daily update refreshes the npm copy (3.0.0). fix: keep one copy' <<< "$out" && pass "unreachable duplicate reported with a fix" || fail "duplicate report"
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
grep -q 'signatures ok' <<< "$out" && pass "signature check ran" || fail "signature check"
grep -q upgraded "$WORK/solo-upgrades.log" 2>/dev/null && pass "standalone CLI self-updated" || fail "self-update not run"
grep -q 'pass: Fake Shadow is installed standalone' <<< "$out" && pass "no updater: reported, not failed" || fail "shadow handling"
! grep -q '@fake/shadow' <<< "$(calls)" && pass "hidden npm copy is not touched" || fail "hidden copy was updated"

out="$("$UPD" --targets fakenpm 2>&1)" || true
grep -q 'already current: @fake/npmcli 1.1.0' <<< "$out" && pass "nothing newer than the waiting period: not reinstalled" || fail "reinstalled: $out"
[[ "$(grep -c ran "$WORK/hook.log" 2>/dev/null)" == 1 ]] && pass "post-update hook ran once: only the run that changed a version" || fail "hook runs: $(cat "$WORK/hook.log" 2>/dev/null)"
grep -q 'post-update hook skipped: no CLI version changed' <<< "$out" && pass "hook skipped when nothing changed" || fail "hook skip message"
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
"$UPD" --targets fakenpm >/dev/null 2>&1 || true
[[ ! -e "$FAKE_NPM_ROOT/@fake/.npmcli-AbCd1234" ]] && pass "npm staging leftover removed" || fail "npm leftover kept"
out="$("$UPD" --targets fakenpm --scheduled 2>&1)" || true
grep -q 'already updated today' <<< "$out" && pass "later scheduled run the same day exits at once" || fail "early exit: $out"
out="$(FAKE_NPM_OFFLINE=1 "$UPD" --targets fakenpm 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -q 'registry unreachable' <<< "$out" && grep -q '"pending":true' "$AICM_HOME/state/last-update.json" && pass "offline run succeeds and stays pending" || fail "offline: rc=$rc $out"
out="$("$UPD" --targets fakenpm --scheduled 2>&1)" || true
! grep -q 'already updated today' <<< "$out" && pass "a pending day is retried by the scheduled run" || fail "pending day not retried"

echo "# bad catalog"
printf 'Bad Id | x | x |  |  |  |  |\n' > "$WORK/bad.conf"
if "$ROOT/bin/inventory_ai_clis.sh" --catalog-file "$WORK/bad.conf" >/dev/null 2>&1; then fail "bad catalog accepted"; else pass "bad catalog rejected"; fi

echo
if ((fails)); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
