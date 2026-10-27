#!/usr/bin/env bash
# Focused checks for category rejection, JSON early exits, weekly scope and archive/history CLI.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AICM="$ROOT/bin/aicm"
CLEAN="$ROOT/bin/clean_ai_leftovers.sh"
WORK="$(mktemp -d)"
export HOME="$WORK/user"
export AICM_HOME="$HOME/.ai-cli-auto-manager"
export AICM_WORKTREES=0
export AICM_CRONTAB="$WORK/crontab.txt"
mkdir -p "$HOME" "$AICM_HOME"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

if "$CLEAN" --category= >/dev/null 2>&1; then fail "empty --category= accepted"; else pass "empty --category= rejected"; fi
if "$AICM" schedule install --clean-category >/dev/null 2>&1; then fail "missing --clean-category accepted"; else pass "missing --clean-category rejected"; fi
[[ -e "$AICM_HOME/.aicm-home" ]] && fail "invalid schedule created a home marker"
pass "invalid schedule created no marker"
# From here on the home is an existing install's (marked). The fixtures below write state/ or archive/
# before a run, and an unmarked folder holding those without an installed copy is no longer adopted.
printf 'AI CLI Auto Manager home (logs, state, archive, installed copy)\n' > "$AICM_HOME/.aicm-home"

exp="$("$CLEAN" --explain --category temp)" || true
printf '%s\n' "$exp" | grep -q 'codex-tmp' || fail "explain missing codex-tmp"
printf '%s\n' "$exp" | grep -q 'limit=' || fail "explain missing limit"
printf '%s\n' "$exp" | grep -q 'protection=' || fail "explain missing protection"
pass "explain shows limit and protection"

json="$("$CLEAN" --json --explain --category temp 2>/dev/null)" || true
printf '%s\n' "$json" | grep -q '"days":' || fail "json missing days: $json"
printf '%s\n' "$json" | grep -q '"protection":' || fail "json missing protection"
pass "json explain includes days and protection"

# Clock refusal must still be one JSON document.
mkdir -p "$AICM_HOME/state"
printf '%s\n' '{"finishedAt":"2030-01-01T00:00:00Z","ok":true}' > "$AICM_HOME/state/last-clean.json"
touch -t 203001010000 "$AICM_HOME/state/last-clean.json"
clock="$("$CLEAN" --json --category temp >"$WORK/clock.out" 2>"$WORK/clock.err"; echo $?)"
grep -q '"status":"error"' "$WORK/clock.out" || fail "clock json: $(cat "$WORK/clock.out")"
[[ "$clock" == 1 ]] || fail "clock exit $clock"
pass "clock refusal emits JSON"

rm -f "$AICM_HOME/state/last-clean.json"
lock="${TMPDIR:-/tmp}/ai-cli-auto-manager-clean-$(id -u).lockdir"
rm -rf "$lock"
mkdir -p "$lock"
echo "$$" > "$lock/pid"
held="$("$CLEAN" --json --category temp >"$WORK/held.out" 2>"$WORK/held.err"; echo $?)"
rm -rf "$lock"
grep -q '"status":"skipped"' "$WORK/held.out" || fail "held json: $(cat "$WORK/held.out")"
[[ "$held" == 0 ]] || fail "held exit $held"
pass "held lock emits JSON"

# Weekly scope. Legacy last-clean (no scope) covers a full clean. cache-only does not.
day="$(date +%u)"
printf '%s\n' '{"finishedAt":"2020-01-01T00:00:00Z","ok":true}' > "$AICM_HOME/state/last-clean.json"
touch "$AICM_HOME/state/last-clean.json"
out="$("$AICM" scheduled clean --weekly "$day" 00:00 --dry-run 2>&1)" || true
printf '%s\n' "$out" | grep -q 'already happened' || fail "legacy full did not cover weekly: $out"
pass "legacy last-clean covers a full weekly clean"

printf '%s\n' '{"finishedAt":"2020-01-01T00:00:00Z","ok":true,"scopeCategories":"cache","scopeRules":""}' > "$AICM_HOME/state/last-clean.json"
touch "$AICM_HOME/state/last-clean.json"
out="$("$AICM" scheduled clean --weekly "$day" 00:00 --dry-run 2>&1)" || true
printf '%s\n' "$out" | grep -q 'already happened' && fail "cache-only satisfied a full weekly clean: $out"
pass "cache-only does not cover a full weekly clean"
out="$("$AICM" scheduled clean --weekly "$day" 00:00 --category cache --dry-run 2>&1)" || true
printf '%s\n' "$out" | grep -q 'already happened' || fail "cache-only did not cover cache weekly: $out"
pass "cache-only covers the same category"

# Generic archive -> list -> dry restore -> conflict -> restore -> history. Codex files stay put.
proj="$HOME/.claude/projects/demo"
mkdir -p "$proj"
printf '%s\n' '{"old":true}' > "$proj/chat.jsonl"
touch -t 202001010000 "$proj/chat.jsonl"
roll="$HOME/.codex/sessions/2020/01/01"
mkdir -p "$roll"
printf '%s\n' x > "$roll/rollout-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
touch -t 202001010000 "$roll/rollout-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
before="$(find "$AICM_HOME/state/history" -type f 2>/dev/null | wc -l | tr -d ' ')"
"$CLEAN" --dry-run --rules claude-transcripts >/dev/null 2>&1 || true
after="$(find "$AICM_HOME/state/history" -type f 2>/dev/null | wc -l | tr -d ' ')"
[[ "$before" == "$after" ]] || fail "dry-run recorded history"
pass "preview records no history"
"$CLEAN" --rules claude-transcripts >/dev/null 2>&1 || true
[[ -f "$proj/chat.jsonl" ]] && fail "transcript was not archived"
[[ -f "$roll/rollout-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl" ]] || fail "codex rollout was moved"
pass "native codex file was not a generic archive"
list="$("$AICM" archive list)" || fail "archive list"
printf '%s\n' "$list" | grep -q 'archived ' || fail "list: $list"
id="$(printf '%s\n' "$list" | awk '/^archived / { print $2; exit }')"
[[ -n "$id" ]] || fail "no archive id"
"$AICM" restore "$id" --dry-run >/dev/null || fail "dry restore"
[[ ! -f "$proj/chat.jsonl" ]] || fail "dry restore wrote the file"
mkdir -p "$proj"
printf '%s\n' blocked > "$proj/chat.jsonl"
if "$AICM" restore "$id" >/dev/null 2>&1; then fail "restore overwrote"; fi
rm -f "$proj/chat.jsonl"
"$AICM" restore "$id" >/dev/null || fail "restore"
[[ -f "$proj/chat.jsonl" ]] || fail "restored file missing"
hist="$("$AICM" history --json)" || fail "history"
printf '%s\n' "$hist" | grep -q '"kind":"clean"' || fail "history missing clean: $hist"
printf '%s\n' "$hist" | grep -q '"kind":"restore"' || fail "history missing restore: $hist"
pass "archive list, restore conflict, restore and history"

# Off archive rules still delete expired date folders. Dry-run JSON must plan those bytes.
ISO="$WORK/off-archive"
export HOME="$ISO/user"
export AICM_HOME="$HOME/.ai-cli-auto-manager"
mkdir -p "$HOME/.claude/projects" "$AICM_HOME/archive/claude-transcripts/20200102" "$ISO/fakebin"
printf '%064d' 0 > "$AICM_HOME/archive/claude-transcripts/20200102/kept.jsonl"
printf 'AI CLI Auto Manager home (logs, state, archive, installed copy)\n' > "$AICM_HOME/.aicm-home"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$ISO/fakebin/lsof"
chmod +x "$ISO/fakebin/lsof"
printf '%s\n' 'claude-transcripts | all | archive | ~/.claude/projects | *.jsonl | 30 | 60 | off |' > "$ISO/rules.conf"
: > "$ISO/none.conf"
state_before="$(find "$AICM_HOME/state" -type f 2>/dev/null | wc -l | tr -d ' ')"
preview="$(PATH="$ISO/fakebin:$PATH" "$CLEAN" --json --dry-run --rules-file "$ISO/rules.conf" --local-rules-file "$ISO/none.conf" 2>"$ISO/dry.err")" || fail "off-archive dry-run failed"
python3 - "$preview" <<'PY' || fail "off-archive dry-run json: $preview"
import json, sys
d = json.loads(sys.argv[1])
assert d["schemaVersion"] == 1 and d["dryRun"] is True and d["errors"] == []
r = d["rules"][0]
assert r["id"] == "claude-transcripts" and r["enabled"] is False and r["status"] == "off"
assert r["candidates"] == 0 and r["candidateBytes"] == 0
assert r["purgeCandidates"] == 1 and r["purgeCandidateBytes"] == 64
assert r["purged"] == 0 and r["purgedBytes"] == 0
assert d["summary"]["plannedBytes"] == 64 and d["summary"]["freedBytes"] == 0
print("ok")
PY
[[ -f "$AICM_HOME/archive/claude-transcripts/20200102/kept.jsonl" ]] || fail "dry-run removed the expired archive"
state_after="$(find "$AICM_HOME/state" -type f 2>/dev/null | wc -l | tr -d ' ')"
[[ "$state_before" == "$state_after" ]] || fail "dry-run wrote state or history"
pass "off archive dry-run plans purge bytes and writes nothing"

cache="$(PATH="$ISO/fakebin:$PATH" "$CLEAN" --json --dry-run --category cache --rules-file "$ISO/rules.conf" --local-rules-file "$ISO/none.conf" 2>"$ISO/cache.err")" || fail "cache dry-run failed"
python3 - "$cache" <<'PY' || fail "cache json included the sessions archive: $cache"
import json, sys
d = json.loads(sys.argv[1])
assert d["categories"] == ["cache"]
assert d["rules"] == []
assert d["summary"]["plannedBytes"] == 0
print("ok")
PY
PATH="$ISO/fakebin:$PATH" "$CLEAN" --category cache --rules-file "$ISO/rules.conf" --local-rules-file "$ISO/none.conf" >/dev/null 2>&1 || true
[[ -f "$AICM_HOME/archive/claude-transcripts/20200102/kept.jsonl" ]] || fail "category cache deleted the sessions archive"
pass "category cache does not plan or delete the sessions archive"

live="$(PATH="$ISO/fakebin:$PATH" "$CLEAN" --json --rules-file "$ISO/rules.conf" --local-rules-file "$ISO/none.conf" 2>"$ISO/live.err")" || fail "off-archive clean failed: $(cat "$ISO/live.err")"
python3 - "$live" <<'PY' || fail "off-archive live json: $live"
import json, sys
d = json.loads(sys.argv[1])
assert d["dryRun"] is False
r = d["rules"][0]
assert r["purgeCandidates"] == 1 and r["purgeCandidateBytes"] == 64
assert r["purged"] == 1 and r["purgedBytes"] == 64
assert d["summary"]["plannedBytes"] == 64 and d["summary"]["freedBytes"] == 64
print("ok")
PY
[[ ! -e "$AICM_HOME/archive/claude-transcripts/20200102" ]] || fail "expired archive folder survived the real clean"
pass "off archive clean frees the planned purge bytes"

rm -rf "$WORK"
echo "maintenance integration checks passed"
