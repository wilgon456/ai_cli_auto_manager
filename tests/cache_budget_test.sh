#!/usr/bin/env bash
# Budget cleanup rules (run_budget_rule in bin/clean_ai_leftovers.sh) and byte sums above 2 GiB.
# Runs against a throwaway HOME with a fake lsof that reports the files listed in $WORK/open-list as
# open; the real profile, caches and processes are never touched.
# shellcheck disable=SC2015,SC2031 # "check && pass || fail" is intended; the library is sourced in subshells on purpose
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT

export HOME="$WORK/home" TMPDIR="$WORK/tmp" AICM_HOME="$WORK/home/.ai-cli-auto-manager" AICM_OS=linux AICM_NOTIFY=0
export CODEX_HOME="$WORK/home/.codex" USERPROFILE="$WORK/home" AICM_PROCESSES=0 AICM_WORKTREES=0 AICM_CLOCK_CHECK=0
unset XDG_CACHE_HOME AICM_BUDGET_MAX_FILES AICM_BUDGET_MAX_DEPTH AICM_BUDGET_SCAN_SECONDS
mkdir -p "$HOME" "$TMPDIR" "$WORK/fakebin" "$WORK/nolsof"
cat > "$WORK/fakebin/lsof" <<EOF
#!/bin/sh
[ -e "$WORK/lsof-error" ] && { echo check-failed >&2; exit 1; }
for a in "\$@"; do
  [ "\$a" = -t ] || [ "\$a" = -- ] && continue
  if [ -f "$WORK/open-list" ] && grep -qxF "\$a" "$WORK/open-list"; then echo 4242; exit 0; fi
done
exit 1
EOF
chmod +x "$WORK/fakebin/lsof"
export PATH="$WORK/fakebin:$PATH"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
stamp_days_ago() {
  local s=$(( $(date +%s) - $1 * 86400 ))
  date -d "@$s" +%Y%m%d%H%M 2>/dev/null || date -r "$s" +%Y%m%d%H%M
}
mib() { # path days_old [MiB]
  mkdir -p "$(dirname "$1")"
  head -c "$(( ${3:-1} * 1048576 ))" /dev/zero > "$1"
  touch -t "$(stamp_days_ago "$2")" "$1"
}
CLEAN="$ROOT/bin/clean_ai_leftovers.sh"
rules() { printf 'npm-cache | all | budget | %s | * | %s | %s | on | fixture\n' "$1" "$2" "$3" > "$WORK/rules.conf"; }
clean() { bash "$CLEAN" --rules-file "$WORK/rules.conf" --local-rules-file "$WORK/none.conf" --json "$@" 2> "$WORK/stderr.log"; }
field() { # json key -> value of the first rule
  node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8")); const v=d.rules[0][process.argv[1]]; process.stdout.write(String(v));' "$1"
}

echo "# byte sums above 2 GiB"
# shellcheck source=lib/aicm-common.sh
sum="$(. "$ROOT/lib/aicm-common.sh"; printf '3221225472\n1073741824\n' | aicm_sum_lines)"
[[ "$sum" == 4294967296 ]] && pass "aicm_sum_lines adds 3221225472 + 1073741824 = 4294967296" || fail "sum: $sum"
sum="$(. "$ROOT/lib/aicm-common.sh"; printf '9007199254740000\n992\n' | aicm_sum_lines)"
[[ "$sum" == 9007199254740992 ]] && pass "sums stay exact up to 2^53" || fail "2^53 sum: $sum"
mkdir -p "$HOME/sparse"
if dd if=/dev/zero of="$HOME/sparse/three.bin" bs=1 count=0 seek=3221225472 2>/dev/null &&
   dd if=/dev/zero of="$HOME/sparse/one.bin" bs=1 count=0 seek=1073741824 2>/dev/null; then
  rules "$HOME/sparse" 30 1
  out="$(clean --dry-run)"
  [[ "$(field totalBytes <<< "$out")" == 4294967296 ]] && pass "sparse 3 GiB + 1 GiB files count 4294967296 logical bytes" || fail "sparse total: $out"
  rm -rf "$HOME/sparse"
else
  echo "skip - no sparse files on this file system"
fi

echo "# rule grammar"
for bad in "30 | 0" "0 | 5" "30 | " "30 | 5x" "30 | -1"; do
  printf 'npm-cache | all | budget | %s | * | %s | on | x\n' "$HOME/c" "$bad" > "$WORK/bad.conf"
  if bash "$CLEAN" --rules-file "$WORK/bad.conf" --local-rules-file "$WORK/none.conf" --dry-run >/dev/null 2>&1; then
    fail "budget values '$bad' accepted"
  else
    pass "budget values '$bad' refused"
  fi
done
[[ ! -e "$AICM_HOME" ]] && pass "a refused rule file writes nothing" || fail "AICM_HOME created by a refused rule"
! grep -Eq '^[^#].*\| *budget *\|' "$ROOT/rules/clean-rules.conf" && pass "no default rule is a budget rule" || fail "a default budget rule exists"

echo "# over budget: oldest first; protected, recent, SQLite and linked files stay"
C="$HOME/cache"
mib "$C/a/oldest.bin" 90; mib "$C/b/older.bin" 60; mib "$C/old.bin" 45; mib "$C/fresh.bin" 0
mib "$C/.npmrc" 120; mib "$C/index.sqlite" 120; mib "$C/index.sqlite-wal" 120; mib "$C/memory/notes.bin" 120
mib "$C/hard.bin" 100; ln "$C/hard.bin" "$WORK/hard-twin.bin"
rules "$C" 30 6
out="$(clean --dry-run)"
[[ -e "$C/a/oldest.bin" && -e "$C/b/older.bin" && ! -e "$AICM_HOME" ]] && pass "a JSON preview deletes and writes nothing" || fail "preview changed files"
[[ "$(field totalBytes <<< "$out")" == $((9 * 1048576)) && "$(field budgetBytes <<< "$out")" == $((6 * 1048576)) ]] &&
  pass "the total counts every ordinary file, protected and busy ones too" || fail "totals: $out"
[[ "$(field projectedRemainingBytes <<< "$out")" == $((6 * 1048576)) && "$(field remainingBytes <<< "$out")" == $((9 * 1048576)) && "$(field candidates <<< "$out")" == 3 ]] &&
  pass "the preview projects the result without changing remainingBytes" || fail "projection: $out"
[[ "$(field scanStatus <<< "$out")" == complete ]] && pass "scanStatus complete" || fail "scan: $out"
[[ "$(printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{JSON.parse(s);console.log("one")})')" == one ]] && pass "stdout is one JSON document" || fail "not one document"
rules "$C" 30 7
out="$(clean)"
[[ ! -e "$C/a/oldest.bin" && ! -e "$C/b/older.bin" && -e "$C/old.bin" ]] && pass "the oldest go first and deletion stops at the budget" || fail "order: $(ls -R "$C")"
[[ -e "$C/fresh.bin" && -e "$C/.npmrc" && -e "$C/index.sqlite" && -e "$C/index.sqlite-wal" && -e "$C/memory/notes.bin" && -e "$C/hard.bin" ]] &&
  pass "recent, protected, SQLite, memory and hard-linked files stay" || fail "kept set: $(ls -aR "$C")"
[[ "$(field remainingBytes <<< "$out")" == $((7 * 1048576)) && "$(field removedBytes <<< "$out")" == $((2 * 1048576)) && "$(field budgetUnmetBytes <<< "$out")" == 0 ]] &&
  pass "a real run reports what is left" || fail "run: $out"
[[ ! -d "$C/a" ]] && pass "emptied folders are removed" || fail "empty folder kept"

echo "# open files and the open-file check"
C2="$HOME/cache2"
mib "$C2/busy.bin" 95; mib "$C2/old.bin" 90; mib "$C2/new.bin" 1
printf '%s\n' "$C2/busy.bin" > "$WORK/open-list"
rules "$C2" 30 1
out="$(clean)"
[[ -e "$C2/busy.bin" && ! -e "$C2/old.bin" ]] && pass "an open file is kept and the next oldest goes" || fail "busy: $(ls "$C2")"
[[ "$(field inUse <<< "$out")" == 1 && "$(field budgetUnmetBytes <<< "$out")" == $((1048576)) ]] && grep -q 'budget not reachable' "$WORK/stderr.log" &&
  pass "an unreachable budget is reported" || fail "unmet: $out"
rm -f "$WORK/open-list"
mib "$C2/old2.bin" 90
touch "$WORK/lsof-error"
out="$(clean)"
[[ -e "$C2/busy.bin" && -e "$C2/old2.bin" ]] && pass "a failing open-file check deletes nothing" || fail "lsof error: $(ls "$C2")"
rm -f "$WORK/lsof-error"
if ! PATH="$WORK/nolsof:/usr/bin:/bin" command -v lsof >/dev/null 2>&1; then
  for t in node bash; do ln -sf "$(command -v "$t")" "$WORK/nolsof/$t"; done
  out="$(PATH="$WORK/nolsof:/usr/bin:/bin" clean)"
  [[ -e "$C2/old2.bin" ]] && grep -q 'lsof not found' "$WORK/stderr.log" && pass "without lsof nothing is deleted" || fail "no lsof: $out"
else
  echo "skip - lsof is in /usr/bin or /bin here"
fi

echo "# under budget"
rules "$C2" 30 100
out="$(clean)"
[[ -e "$C2/busy.bin" && -e "$C2/old2.bin" && "$(field candidates <<< "$out")" == 0 ]] && pass "under budget nothing is deleted" || fail "under budget: $out"

echo "# links"
C3="$HOME/cache3"
mib "$WORK/outside/victim.bin" 90; mib "$C3/old.bin" 90
ln -s "$WORK/outside" "$C3/jump"; ln -s "$WORK/outside/victim.bin" "$C3/file-link"
rules "$C3" 30 1
out="$(clean)"
[[ -e "$WORK/outside/victim.bin" && -L "$C3/jump" && -L "$C3/file-link" ]] && pass "links are neither followed nor removed" || fail "link: $out"
[[ "$(field totalBytes <<< "$out")" == 1048576 ]] && pass "files behind links are not counted" || fail "link total: $out"
ln -s "$C3" "$HOME/cache-link"
rules "$HOME/cache-link" 30 1
out="$(clean)" || true
grep -Eq '"status":"(skipped: path is a link|refused: outside home and temp)"' <<< "$out" && [[ -e "$C3/old.bin" ]] && pass "a linked rule root is refused untouched" || fail "root link: $out"

echo "# a scan that is not complete deletes nothing"
C4="$HOME/cache4"
mib "$C4/x/y/z/deep.bin" 90; mib "$C4/top.bin" 90
rules "$C4" 30 1
out="$(AICM_BUDGET_MAX_DEPTH=2 clean)"
[[ -e "$C4/top.bin" && "$(field scanStatus <<< "$out")" == partial ]] && pass "the depth bound makes the scan partial" || fail "depth: $out"
out="$(AICM_BUDGET_MAX_FILES=1 clean)"
[[ -e "$C4/top.bin" && "$(field scanStatus <<< "$out")" == partial ]] && pass "the file-count bound makes the scan partial" || fail "count: $out"
if [[ "$(id -u)" != 0 ]]; then
  mkdir -p "$C4/locked"; mib "$C4/locked/hidden.bin" 90; chmod 000 "$C4/locked"
  printf 'npm-cache | all | budget | %s | * | 30 | 1 | on | x\nold-files | all | age-files | %s | *.tmp | 30 | | on | x\n' "$C4" "$HOME/other" > "$WORK/rules.conf"
  mib "$HOME/other/a.tmp" 90
  out="$(clean)"
  chmod 700 "$C4/locked"
  [[ -e "$C4/top.bin" && -e "$C4/locked/hidden.bin" && "$(field scanStatus <<< "$out")" == partial ]] && pass "an unreadable folder makes the scan partial and nothing is deleted" || fail "permission: $out"
  [[ ! -e "$HOME/other/a.tmp" ]] && pass "the other rules still run" || fail "other rule did not run"
else
  echo "skip - running as root, permissions are not enforced"
fi

echo
if ((fails)); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
