#!/usr/bin/env bash
# Tests for bin/inventory_ai_clis.sh and the catalog-driven part of bin/update_ai_clis.sh.
# Uses fake CLIs and a fake npm in a throwaway HOME; real CLIs are never run or updated.
# shellcheck disable=SC2015,SC2016 # "check && pass || fail" is intended; fake scripts are written with literal $
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home" TMPDIR="$WORK/tmp" AICM_HOME="$WORK/home/.ai-cli-auto-manager" AICM_OS=linux AICM_NOTIFY=0
PREFIX="$WORK/npmprefix"
mkdir -p "$HOME" "$TMPDIR" "$AICM_HOME" "$WORK/fakebin" "$WORK/solo" "$PREFIX/bin" "$PREFIX/lib/node_modules"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

npm_pkg() { # name version
  mkdir -p "$PREFIX/lib/node_modules/$1"
  printf '{\n  "name": "%s",\n  "version": "%s"\n}\n' "$1" "$2" > "$PREFIX/lib/node_modules/$1/package.json"
}

# Fake npm: prefix/root, ls/list, view <pkg> version (from latest.txt), install -g <pkg>@latest.
cat > "$WORK/fakebin/npm" <<EOF
#!/usr/bin/env bash
prefix="$PREFIX"; root="\$prefix/lib/node_modules"; latest="$WORK/latest.txt"
case "\$1" in
  prefix) echo "\$prefix" ;;
  root) echo "\$root" ;;
  ls|list) pkg="\${@: -1}"; [[ "\$pkg" == --* || "\$pkg" == -g ]] && exit 0; [[ -f "\$root/\$pkg/package.json" ]] ;;
  view) awk -v p="\$2" '\$1 == p { print \$2 }' "\$latest" ;;
  install)
    spec="\${@: -1}"; pkg="\${spec%@latest}"; echo "\$pkg" >> "$WORK/npm-installs.log"
    v="\$(awk -v p="\$pkg" '\$1 == p { print \$2 }' "\$latest")"
    mkdir -p "\$root/\$pkg"; printf '{\n  "name": "%s",\n  "version": "%s"\n}\n' "\$pkg" "\$v" > "\$root/\$pkg/package.json" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/fakebin/npm"
export NPM="$WORK/fakebin/npm"

printf '%s\n' '@fake/npmcli 1.2.0' '@fake/shadow 3.1.0' '@fake/newcli 0.5.0' > "$WORK/latest.txt"

# npm-managed CLI: launcher in the npm prefix bin folder.
npm_pkg @fake/npmcli 1.0.0
printf '#!/usr/bin/env bash\nv="$(sed -n '"'"'s/.*"version": "\\(.*\\)".*/\\1/p'"'"' "%s/lib/node_modules/@fake/npmcli/package.json")"\necho "fakenpm $v"\n' "$PREFIX" > "$PREFIX/bin/fakenpm"
chmod +x "$PREFIX/bin/fakenpm"
# Standalone CLI with a self-update command.
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == upgrade ]]; then echo upgraded >> "%s/solo-upgrades.log"; exit 0; fi\necho "fakesolo version 2.0.0"\n' "$WORK" > "$WORK/solo/fakesolo"
chmod +x "$WORK/solo/fakesolo"
# Standalone CLI on PATH with an older npm copy hidden behind it.
printf '#!/usr/bin/env bash\necho "fakeshadow 3.1.0"\n' > "$WORK/solo/fakeshadow"
chmod +x "$WORK/solo/fakeshadow"
npm_pkg @fake/shadow 3.0.0

export PATH="$WORK/fakebin:$PREFIX/bin:$WORK/solo:$PATH"

cat > "$WORK/catalog.conf" <<'EOF'
# id        | command    | name         | npm          | brew | winget | self_update | note
fakenpm     | fakenpm    | Fake NPM     | @fake/npmcli |      |        |             |
fakesolo    | fakesolo   | Fake Solo    |              |      |        | upgrade     |
fakeshadow  | fakeshadow | Fake Shadow  | @fake/shadow |      |        |             | ships with an app
fakegone    | fakegone   | Fake Missing | @fake/gone   |      |        |             |
fakenew     | fakenew    | Fake New     | @fake/newcli |      |        |             |
EOF
cp "$WORK/catalog.conf" "$AICM_HOME/ai-clis.local.conf"
INV=("$ROOT/bin/inventory_ai_clis.sh" --catalog-file "$WORK/catalog.conf" --local-catalog-file "$WORK/none.conf")

echo "# first inventory"
out="$("${INV[@]}" 2>&1)" && rc=0 || rc=$?
echo "$out"
[[ "$rc" == 0 ]] && pass "inventory exits 0" || fail "inventory rc=$rc"
grep -Eq '^Fake NPM +npm +1\.0\.0 +1\.2\.0 +behind +yes' <<< "$out" && pass "npm CLI: method, versions, behind, covered" || fail "npm CLI row"
grep -Eq '^Fake Solo +standalone +2\.0\.0 +installed +yes' <<< "$out" && pass "standalone CLI with self-update is covered" || fail "standalone row"
grep -Eq '^Fake Shadow +standalone +3\.1\.0 +3\.1\.0 +current +no: ships with an app' <<< "$out" && pass "standalone without updater is flagged" || fail "shadow row"
grep -q 'npm copy 3.0.0 is also installed, but PATH runs' <<< "$out" && pass "hidden npm copy reported" || fail "hidden npm copy"
! grep -q 'Fake Missing' <<< "$out" && pass "missing CLI not listed" || fail "missing CLI listed"
grep -q '3 AI CLIs installed (catalog has 5)' <<< "$out" && pass "count line" || fail "count line"
[[ -f "$AICM_HOME/inventory.md" ]] && grep -q '| Fake NPM | npm | 1.0.0 | 1.2.0 | behind | yes |' "$AICM_HOME/inventory.md" && pass "markdown report" || fail "markdown report"
grep -q '"id":"fakesolo"' "$AICM_HOME/state/inventory.json" && pass "json state" || fail "json state"
! grep -q 'notify:' <<< "$out" && pass "first run does not notify" || fail "first run notified"

echo "# offline"
out="$("${INV[@]}" --offline 2>&1)" || true
grep -Eq '^Fake NPM +npm +1\.0\.0 +installed' <<< "$out" && pass "--offline skips latest lookups" || fail "offline: $out"

echo "# update through the catalog"
out="$("$ROOT/bin/update_ai_clis.sh" --targets fakenpm,fakesolo,fakeshadow 2>&1)" && rc=0 || rc=$?
echo "$out"
[[ "$rc" == 0 ]] && pass "update exits 0" || fail "update rc=$rc"
grep -qx '@fake/npmcli' "$WORK/npm-installs.log" && pass "npm CLI updated through npm" || fail "npm CLI not updated"
grep -q upgraded "$WORK/solo-upgrades.log" 2>/dev/null && pass "standalone CLI self-updated" || fail "self-update not run"
grep -q 'pass: Fake Shadow is installed standalone' <<< "$out" && pass "no updater: reported, not failed" || fail "shadow handling"
! grep -q '@fake/shadow' "$WORK/npm-installs.log" && pass "hidden npm copy is not touched" || fail "hidden copy was updated"
out="$("$ROOT/bin/update_ai_clis.sh" --targets fakenpm 2>&1)" || true
grep -q 'already current: @fake/npmcli 1.2.0' <<< "$out" && pass "current npm CLI not reinstalled" || fail "reinstalled a current CLI"
[[ "$(grep -c . "$WORK/npm-installs.log")" == 1 ]] && pass "only one npm install happened" || fail "npm install count"

echo "# install-missing only when named"
# Never "--targets all" here: that would also run the dedicated updaters for real CLIs on this machine.
"$ROOT/bin/update_ai_clis.sh" --targets fakenpm --install-missing >/dev/null 2>&1 || true
! grep -q '@fake/newcli' "$WORK/npm-installs.log" && pass "unnamed CLI is not installed" || fail "unnamed CLI installed"
"$ROOT/bin/update_ai_clis.sh" --targets fakenew --install-missing >/dev/null 2>&1 || true
grep -q '@fake/newcli' "$WORK/npm-installs.log" && pass "named target is installed with --install-missing" || fail "named install"

echo "# changes since the last inventory"
rm -f "$WORK/solo/fakesolo"
out="$("${INV[@]}" 2>&1)" || true
echo "$out" | sed -n '/changes since/,$p'
grep -q 'removed: Fake Solo' <<< "$out" && pass "removed CLI reported" || fail "removed"
grep -q 'new: Fake New' <<< "$out" && pass "new CLI reported" || fail "new"
grep -q 'updated: Fake NPM 1.0.0 -> 1.2.0' <<< "$out" && pass "version change reported" || fail "updated"
grep -q 'notify: .*removed: Fake Solo' <<< "$out" && pass "added/removed CLIs raise a notification" || fail "notification"

echo "# bad catalog"
printf 'Bad Id | x | x |  |  |  |  |\n' > "$WORK/bad.conf"
if "$ROOT/bin/inventory_ai_clis.sh" --catalog-file "$WORK/bad.conf" >/dev/null 2>&1; then fail "bad catalog accepted"; else pass "bad catalog rejected"; fi

echo
if ((fails)); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
