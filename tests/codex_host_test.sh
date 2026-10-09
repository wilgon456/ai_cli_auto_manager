#!/usr/bin/env bash
# Tests for lib/codex-host.sh: which app-servers count as stale, and the recycle flow with fake ps, lsof,
# paseo and kill. Never looks at or signals real processes.
# shellcheck disable=SC2015 # "check && pass || fail" is intended: pass never fails
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" AICM_HOME="$WORK/home/.ai-cli-auto-manager" AICM_NOTIFY=0
mkdir -p "$HOME"
# shellcheck source=lib/aicm-common.sh
. "$ROOT/lib/aicm-common.sh"
# shellcheck source=lib/codex-host.sh
. "$ROOT/lib/codex-host.sh"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }

# --- which mapped binary is stale ---
current="/usr/local/Caskroom/codex/0.160.0/bin/codex"
codex_server_is_stale "$current" "$current" && fail "same binary is stale" || pass "same binary is current"
codex_server_is_stale "$current" "" && fail "unknown mapping is stale" || pass "unknown mapping is left alone"
codex_server_is_stale "$current" "/Applications/ChatGPT.app/Contents/Resources/codex" && fail "ChatGPT.app is stale" || pass "ChatGPT.app is left alone"
for old in 0.159.3 0.159.3.upgrading 0.152.0; do
  codex_server_is_stale "$current" "/usr/local/Caskroom/codex/$old/bin/codex" && pass "old cask $old is stale" || fail "old cask $old"
done

out="$(printf '%s\n' 'ftxt' 'n/usr/lib/dyld' 'ftxt' 'n/usr/local/Caskroom/codex/0.159.3/bin/codex (deleted)' | codex_path_from_lsof_fn)"
[[ "$out" == /usr/local/Caskroom/codex/0.159.3/bin/codex ]] && pass "lsof: deleted suffix stripped" || fail "lsof deleted: $out"
out="$(printf '%s\n' 'n/usr/local/Caskroom/codex/0.160.0/bin/codex-code-mode-host' 'n/usr/lib/dyld' | codex_path_from_lsof_fn || true)"
[[ -z "$out" ]] && pass "lsof: host and dyld ignored" || fail "lsof host: $out"

# --- recycle flow ---
# A cask layout with the current Codex and its host, a fake app-server pid 4242 whose mapped binary is
# read from $WORK/mapped, and a paseo that fixes the server only when $WORK/paseo-fixes exists.
cask="$WORK/Caskroom/codex/0.2/bin"
mkdir -p "$cask" "$WORK/fakebin"
printf '#!/bin/sh\n' > "$cask/codex"
printf '#!/bin/sh\n' > "$cask/codex-code-mode-host"
chmod +x "$cask/codex" "$cask/codex-code-mode-host"
ln -s "$cask/codex" "$WORK/fakebin/codex"
current="$(aicm_realpath "$cask/codex")"
stale="$WORK/Caskroom/codex/0.1/bin/codex"

cat > "$WORK/fakebin/ps" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == -axo ]]; then echo "4242 $stale app-server --listen"; echo "77 /usr/bin/vim notes"; exit 0; fi
echo "$stale app-server --listen"
EOF
cat > "$WORK/fakebin/lsof" <<EOF
#!/usr/bin/env bash
echo ftxt; echo "n\$(cat "$WORK/mapped") (deleted)"
EOF
cat > "$WORK/fakebin/paseo" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$WORK/paseo.log"
[[ -e "$WORK/paseo-fixes" ]] && echo "$current" > "$WORK/mapped"
exit 0
EOF
chmod +x "$WORK/fakebin/"*
PATH="$WORK/fakebin:$PATH"
# Shadow the builtins: record signals instead of sending them, and do not wait.
kill() { echo "$*" >> "$WORK/kill.log"; [[ -e "$WORK/kill-fixes" ]] && echo "$current" > "$WORK/mapped"; return 0; }
sleep() { :; }

reset() { rm -f "$WORK/paseo.log" "$WORK/kill.log" "$WORK/paseo-fixes" "$WORK/kill-fixes"; echo "$1" > "$WORK/mapped"; }

reset "$current"
out="$(recycle_stale_codex_app_servers 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && ! -e "$WORK/paseo.log" && ! -e "$WORK/kill.log" ]] && grep -q 'no stale codex app-server' <<< "$out" && pass "current server: nothing restarted" || fail "current server: rc=$rc $out"

reset "$stale"; touch "$WORK/paseo-fixes"
out="$(recycle_stale_codex_app_servers 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -q '^restart --timeout' "$WORK/paseo.log" && [[ ! -e "$WORK/kill.log" ]] && pass "stale server: paseo restart is enough" || fail "paseo restart: rc=$rc $out"

reset "$stale"; touch "$WORK/kill-fixes"
out="$(recycle_stale_codex_app_servers 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -qx -- '-TERM 4242' "$WORK/kill.log" && pass "server outside paseo: only that pid is stopped" || fail "kill: rc=$rc $out"

reset "$stale"
out="$(recycle_stale_codex_app_servers 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 ]] && grep -q 'stale codex app-servers remain: 4242' <<< "$out" && pass "server that survives: reported as failed" || fail "survivor: rc=$rc $out"

rm "$cask/codex-code-mode-host"; reset "$stale"
out="$(recycle_stale_codex_app_servers 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && ! -e "$WORK/paseo.log" && ! -e "$WORK/kill.log" ]] && pass "no host beside codex: nothing touched" || fail "no host: rc=$rc $out"

# --- quarantine on the cask build ---
# Fake xattr keeps the quarantined paths in $WORK/qtn and ignores -d while $WORK/xattr-stuck exists.
# Fake codesign accepts everything unless $WORK/bad-signature exists.
printf '#!/bin/sh\n' > "$cask/codex-code-mode-host"
chmod +x "$cask/codex-code-mode-host"
host="$(aicm_realpath "$cask/codex-code-mode-host")"
root="$(dirname "$(dirname "$current")")"
cat > "$WORK/fakebin/xattr" <<EOF
#!/usr/bin/env bash
qtn="$WORK/qtn"; touch "\$qtn"
case "\$1" in
  -p) grep -qxF -- "\$3" "\$qtn" ;;
  -dr) echo "\$*" >> "$WORK/xattr.log"; [[ -e "$WORK/xattr-stuck" ]] && exit 0
       grep -vF -- "\$3/" "\$qtn" > "\$qtn.new" || true; mv "\$qtn.new" "\$qtn" ;;
  *) exit 2 ;;
esac
EOF
cat > "$WORK/fakebin/codesign" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$WORK/codesign.log"
[[ ! -e "$WORK/bad-signature" ]]
EOF
chmod +x "$WORK/fakebin/xattr" "$WORK/fakebin/codesign"
qreset() {
  rm -f "$WORK/qtn" "$WORK/xattr.log" "$WORK/codesign.log" "$WORK/bad-signature" "$WORK/xattr-stuck"
  touch "$WORK/qtn"
  if (($#)); then printf '%s\n' "$@" > "$WORK/qtn"; fi
}

qreset
out="$(release_codex_cask_quarantine 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && ! -e "$WORK/xattr.log" ]] && grep -q 'no quarantine' <<< "$out" && pass "quarantine: clean build untouched" || fail "clean build: rc=$rc $out"

qreset "$host"
out="$(release_codex_cask_quarantine 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 ]] && grep -qxF -- "-dr com.apple.quarantine $root" "$WORK/xattr.log" && ! grep -qF "$host" "$WORK/qtn" \
  && grep -qF '2DC432GLL2' "$WORK/codesign.log" && pass "quarantine: OpenAI-signed host is cleared" || fail "clear: rc=$rc $out"

qreset "$current" "$host"; touch "$WORK/bad-signature"
out="$(release_codex_cask_quarantine 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 && ! -e "$WORK/xattr.log" ]] && grep -q 'not a notarized OpenAI build' <<< "$out" && pass "quarantine: unverified build is left as is" || fail "bad signature: rc=$rc $out"

qreset "$host"; touch "$WORK/xattr-stuck"
out="$(release_codex_cask_quarantine 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 1 ]] && grep -q 'still set' <<< "$out" && pass "quarantine: a failed clear is reported" || fail "stuck: rc=$rc $out"

standalone="$WORK/home/.codex/packages/standalone/releases/0.2/bin"
mkdir -p "$standalone" "$WORK/fakebin2"
printf '#!/bin/sh\n' > "$standalone/codex"
chmod +x "$standalone/codex"
ln -s "$standalone/codex" "$WORK/fakebin2/codex"
qreset "$(aicm_realpath "$standalone/codex")"
out="$(PATH="$WORK/fakebin2:$PATH" release_codex_cask_quarantine 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && ! -e "$WORK/xattr.log" ]] && grep -q 'not a Homebrew cask' <<< "$out" && pass "quarantine: non-cask codex untouched" || fail "standalone: rc=$rc $out"

if ((fails)); then echo "$fails failed"; exit 1; fi
echo "all codex host tests passed"
