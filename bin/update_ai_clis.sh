#!/usr/bin/env bash
set -Eeuo pipefail

# Auto-update local AI coding CLIs.
# Targets:
#   - GPT/Codex CLI: Homebrew cask/formula when present; npm global only if it is the active command;
#     codex update for the official installer's copy
#   - OpenCode CLI: Homebrew, npm, or built-in opencode upgrade
#   - Antigravity CLI: agy built-in updater when present
#   - Kimi Code CLI: npm @moonshot-ai/kimi-code when npm-managed
#   - Claude Code CLI: Homebrew, npm, or built-in claude update
#   - Grok Build CLI: official xAI install script
#
# Safe behavior:
#   - serializes with flock
#   - logs before/after versions
#   - continues per-tool if one updater fails
#   - never prints secrets/env values

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/aicm-common.sh
. "$SCRIPT_DIR/../lib/aicm-common.sh"
ORIG_ARGS=("$@")
# shellcheck source=lib/codex-host.sh
. "$SCRIPT_DIR/../lib/codex-host.sh"

LOCK_DIR="${LOCK_DIR:-$(aicm_temp_dir)/ai-cli-auto-manager-update-$(id -u).lockdir}"
LOG_DIR="${LOG_DIR:-$AICM_HOME/logs}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
AI_CLI_TARGETS="${AI_CLI_TARGETS:-all}"
INSTALL_MISSING="${INSTALL_MISSING:-false}"
# The PATH captured at install comes first, so the job updates the copies the user runs (nvm before a
# stale Homebrew npm prefix, ~/.grok/bin before an old brew formula). The fallbacks only widen it.
PATH="${PATH:+$PATH:}/usr/local/bin:/opt/homebrew/bin:${HOME:-}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# Resolved after PATH is widened: cron and launchd start with a minimal PATH.
BREW="${BREW:-$(command -v brew 2>/dev/null || echo /usr/local/bin/brew)}"
NPM="${NPM:-$(command -v npm 2>/dev/null || echo /usr/local/bin/npm)}"
AICM_NPM_CMD="$NPM"
# Upper limit for one install, upgrade or brew update (seconds). A postinstall that hangs on the
# network would otherwise hold the lock, and every later run would exit as "already active".
INSTALL_TIMEOUT_SECONDS="${AICM_INSTALL_TIMEOUT_SECONDS:-1800}"
[[ "$INSTALL_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] && ((INSTALL_TIMEOUT_SECONDS > 0)) || INSTALL_TIMEOUT_SECONDS=1800
STUCK_HOURS=3
DRY_RUN=false
SCHEDULED=false
MIN_RELEASE_AGE_DAYS="$(aicm_min_release_age_days)"
VERSION_TIMEOUT_SECONDS="${VERSION_TIMEOUT_SECONDS:-10}"
if [[ ! "$VERSION_TIMEOUT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ "$VERSION_TIMEOUT_SECONDS" == 0 || "$VERSION_TIMEOUT_SECONDS" == 0.0 ]]; then
  VERSION_TIMEOUT_SECONDS=10
fi
while (($#)); do
  case "$1" in
    --dry-run|--check) DRY_RUN=true ;;
    --install-missing) INSTALL_MISSING=true ;;
    --scheduled) SCHEDULED=true ;;
    --targets)
      shift
      [[ "${1:-}" ]] || { echo "missing value for --targets" >&2; exit 2; }
      AI_CLI_TARGETS="$1"
      ;;
    --targets=*) AI_CLI_TARGETS="${1#--targets=}" ;;
    --min-release-age-days)
      shift
      [[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "--min-release-age-days needs a number" >&2; exit 2; }
      MIN_RELEASE_AGE_DAYS="$1"
      ;;
    -h|--help)
      echo "Usage: $0 [--dry-run|--check] [--targets all|id,id (see rules/ai-clis.conf)] [--install-missing] [--min-release-age-days N]"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# Update policy preflight. A policy file needs Node.js and must be valid before this run creates a
# log directory, lock or state file; a broken policy never starts a run.
if [[ -f "$AICM_HOME/update-policy.json" ]]; then
  aicm_load_catalog "" "" >/dev/null || { echo "update policy: cannot read the CLI catalog" >&2; exit 1; }
fi
if ! aicm_policy_load "$MIN_RELEASE_AGE_DAYS"; then
  echo "update policy: refusing to run" >&2
  exit 1
fi

# Codex cask quarantine/recycle is a local fix, but a pinned, excluded, or age-held Codex must not be
# touched at all (including the same-day fast path below).
policy_codex_local_fix_allowed() {
  aicm_policy_excluded codex && return 1
  [[ -n "$(aicm_policy_pin codex)" ]] && return 1
  local age
  age="$(aicm_policy_explicit_age codex)"
  [[ -n "$age" && "$age" -gt 0 ]] && return 1
  return 0
}

# A pin or a positive explicit age holds the Homebrew route: no metadata refresh or upgrade for it.
policy_brew_update_allowed() { # id
  [[ -n "$(aicm_policy_pin "$1")" ]] && return 1
  local age
  age="$(aicm_policy_explicit_age "$1")"
  [[ -n "$age" && "$age" -gt 0 ]] && return 1
  return 0
}

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

command_with_timeout() {
  local timeout_seconds="$1"; shift
  # timeout/gtimeout/perl first: on a fresh Mac, /usr/bin/python3 is a stub that opens an install dialog.
  if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || command -v perl >/dev/null 2>&1; then
    aicm_timeout "${timeout_seconds%%.*}" "$@" 2>&1
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
argv = sys.argv[2:]
try:
    completed = subprocess.run(
        argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
    )
    if completed.stdout:
        sys.stdout.write(completed.stdout)
    sys.exit(completed.returncode)
except subprocess.TimeoutExpired as exc:
    output = exc.stdout or ""
    if isinstance(output, bytes):
        output = output.decode(errors="replace")
    if output:
        sys.stdout.write(output)
    sys.stderr.write(f"TIMEOUT after {timeout:g}s\n")
    sys.exit(124)
PY
  else
    "$@" &
    local cmd_pid=$! watchdog_pid rc
    (
      sleep "$timeout_seconds"
      if kill -0 "$cmd_pid" 2>/dev/null; then
        echo "TIMEOUT after ${timeout_seconds}s" >&2
        kill -TERM "$cmd_pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$cmd_pid" 2>/dev/null || true
      fi
    ) &
    watchdog_pid=$!
    rc=0
    wait "$cmd_pid" || rc=$?
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    if ((rc == 143 || rc == 137)); then
      return 124
    fi
    return "$rc"
  fi
}

# The selected targets, normalized (no spaces, sorted, no duplicates): "all" or e.g. "claude,codex".
run_targets() {
  local t list
  list="$(printf '%s' "${AI_CLI_TARGETS//[[:space:]]/}" | tr ',' '\n' | awk 'NF' | sort -u | paste -sd ',' -)"
  t=",$list,"
  if [[ -z "$list" || "$t" == *,all,* ]]; then echo all; else echo "$list"; fi
}

# A scheduled retry has nothing to do when the last run finished today (local calendar day) without
# failures or pending work and covered every target of this run. A partial manual run
# (aicm update --targets claude) therefore does not stop the full scheduled run.
done_today() {
  local file="$AICM_HOME/state/last-update.json" state day covered want t fingerprint
  [[ -f "$file" ]] || return 1
  state="$(cat "$file")"
  [[ "$state" == *'"ok":true'* && "$state" != *'"pending":true'* ]] || return 1
  # State from before policy fingerprints is not trusted for a same-day skip: a policy may have
  # appeared, changed or been removed, and a conservative run is cheap.
  fingerprint="$(printf '%s' "$state" | sed -n 's/.*"policyFingerprint":"\([^"]*\)".*/\1/p')"
  [[ -n "$fingerprint" && "$fingerprint" == "$AICM_POLICY_FINGERPRINT" ]] || return 1
  day="$(printf '%s' "$state" | sed -n 's/.*"localDate":"\([0-9-]*\)".*/\1/p')"
  [[ -n "$day" && "$day" == "$(date +%Y-%m-%d)" ]] || return 1
  covered="$(printf '%s' "$state" | sed -n 's/.*"targets":"\([^"]*\)".*/\1/p')"
  [[ -n "$covered" ]] || return 1
  [[ ",$covered," == *,all,* ]] && return 0
  want="$(run_targets)"
  [[ "$want" == all ]] && return 1
  for t in ${want//,/ }; do [[ ",$covered," == *",$t,"* ]] || return 1; done
  return 0
}

# Another run holds the lock. When it started more than STUCK_HOURS ago it is probably stuck (a
# postinstall waiting on the network, say), and it blocks every later run; say so instead of exiting quietly.
check_stuck_run() {
  local started now
  started="$(cat "$LOCK_DIR/started" 2>/dev/null || true)"
  [[ "$started" =~ ^[0-9]+$ ]] || return 0
  now="$(date +%s)"
  ((now - started >= STUCK_HOURS * 3600)) || return 0
  echo "the run holding the lock (pid $(cat "$LOCK_DIR/pid" 2>/dev/null || echo '?')) started $(((now - started) / 3600)) hours ago"
  aicm_attention update-stuck "the daily update has been running for more than $STUCK_HOURS hours and blocks the next runs; if it is stuck, end it (its pid is in $LOCK_DIR/pid) and run 'aicm update'"
}

# cron and launchd append this script's output to these files; nothing else trims them. They are
# trimmed in place (not replaced): the scheduler keeps the file open for appending.
trim_schedule_logs() {
  local f lines bytes
  for f in "$AICM_HOME/logs/cron.update.log" "$AICM_HOME/logs/launchd.update.out.log" "$AICM_HOME/logs/launchd.update.err.log"; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    lines="$(wc -l < "$f" | tr -d ' ')"; bytes="$(wc -c < "$f" | tr -d ' ')"
    if ((lines > 4000 || bytes > 5242880)); then
      tail -n 2000 "$f" > "$f.$$.tmp" && cat "$f.$$.tmp" > "$f"
      rm -f "$f.$$.tmp"
      echo "trimmed $f to its last 2000 lines"
    fi
  done
}

# A real run claims (marks) the home; a dry run only checks it. A folder this tool did not create is
# refused before any log, lock or state is written into it.
if [[ "$DRY_RUN" == true ]]; then aicm_home_usable || exit 1; else
  aicm_claim_home || exit 1
  aicm_contain_script "$0" "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}"
fi
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/update-$(date +%Y%m%d-%H%M%S).log"
LATEST_LOG="$LOG_DIR/latest.log"

# Runs that do nothing (lock held, already done today) write no log file: a retry must not replace
# latest.log with one line.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [[ -f "$LOCK_DIR/pid" ]] && kill -0 "$(cat "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then
    echo "[$(ts)] another update run is already active"
    check_stuck_run
    exit 0
  fi
  echo "[$(ts)] removing stale lock: $LOCK_DIR"
  rm -f "$LOCK_DIR/pid" "$LOCK_DIR/started" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "[$(ts)] another update run is already active"
    exit 0
  fi
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"
date +%s > "$LOCK_DIR/started"
trap 'rm -f "$LOCK_DIR/pid" "$LOCK_DIR/started" 2>/dev/null || true; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
[[ -s "$AICM_HOME/state/attention-update-stuck.tsv" ]] && aicm_attention update-stuck

# The scheduled job retries during the day; after a complete success today there is nothing to do.
if [[ "$SCHEDULED" == true && "$DRY_RUN" != true ]] && done_today; then
  # A Codex cask upgraded by hand after today's run is still unquarantined (lib/codex-host.sh), unless
  # the policy excludes Codex or holds it by pin/age.
  if [[ "${AICM_CODEX_UNQUARANTINE:-1}" != 0 && "$(uname -s)" == Darwin ]] && policy_codex_local_fix_allowed; then
    release_codex_cask_quarantine_quiet | sed "s/^/[$(ts)] /" || true
  fi
  echo "[$(ts)] already updated today; nothing to retry"
  exit 0
fi
[[ "$DRY_RUN" != true ]] && trim_schedule_logs

# Mirror all output to a timestamped log and latest.log.
: > "$LATEST_LOG"
exec > >(tee -a "$LOG_FILE" "$LATEST_LOG") 2>&1

failures=()
version_failures=()

run_step() {
  local name="$1"; shift
  echo
  echo "== $name =="
  echo "+ $*"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "dry-run: skipped $name"
    return 0
  fi
  if "$@"; then
    echo "✓ $name ok"
  else
    local rc=$?
    echo "✗ $name failed rc=$rc"
    failures+=("$name rc=$rc")
  fi
}

run_optional_step() {
  local name="$1"; shift
  echo
  echo "== $name =="
  echo "+ $*"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "dry-run: skipped $name"
    return 0
  fi
  if "$@"; then
    echo "✓ $name ok"
  else
    local rc=$?
    echo "warn: optional $name failed rc=$rc"
  fi
}

pass_missing() {
  local tool="$1" reason="$2"
  echo "pass: $tool not installed or not managed here ($reason)"
}

target_enabled() {
  local target="$1"
  local normalized=",${AI_CLI_TARGETS//[[:space:]]/},"
  [[ "$normalized" == *,all,* || "$normalized" == *,"$target",* ]]
}

# True only when the id is named explicitly (not through "all"); used before installing anything new.
target_named() {
  local normalized=",${AI_CLI_TARGETS//[[:space:]]/},"
  [[ "$normalized" == *,"$1",* ]]
}

gpt_target_enabled() {
  target_enabled gpt || target_enabled codex
}

cleanup_old_logs() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "dry-run: skipped log cleanup"
    return 0
  fi
  if [[ ! "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    echo "warn: invalid LOG_RETENTION_DAYS=$LOG_RETENTION_DAYS; skipping log cleanup"
    return 0
  fi
  if ((LOG_RETENTION_DAYS == 0)); then
    echo "pass: log cleanup disabled"
    return 0
  fi

  local deleted=0 old_log
  while IFS= read -r old_log; do
    rm -f -- "$old_log" && ((deleted += 1))
  done < <(find "$LOG_DIR" -type f -name 'update-*.log' -mtime +"$LOG_RETENTION_DAYS" -print 2>/dev/null)
  echo "log cleanup: removed $deleted update logs older than ${LOG_RETENTION_DAYS}d"
}

record_version_failure() {
  local item="$1" existing
  if ((${#version_failures[@]})); then
    for existing in "${version_failures[@]}"; do
      [[ "$existing" == "$item" ]] && return 0
    done
  fi
  version_failures+=("$item")
}

# Per selected CLI: before/after --version of the PATH-selected executable (not an npm package
# hidden behind it). A bad probe before the update is not a failure once the after probe is healthy.
V_ID=(); V_CMD=(); V_IDX=()
V_BP=(); V_BV=(); V_BR=()
V_AP=(); V_AV=(); V_AR=()
V_STATUS=(); V_REASON=()
TFAIL_ID=(); TFAIL_REASON=()
POLICY_HOLD_ID=(); POLICY_HOLD_REASON=()
NPM_PENDING_PKGS=""
INSTALL_OK_PKGS=" "
INSTALL_OK_IDS=" "
PROBE_PATH=""; PROBE_VER=""; PROBE_RC=""

note_policy_hold() { # instrument-id reason
  local id="$1" reason="$2"
  [[ -n "$id" && -n "$reason" ]] || return 0
  POLICY_HOLD_ID+=("$id")
  POLICY_HOLD_REASON+=("$reason")
}

policy_hold_reason() { # id -> joined reasons
  local id="$1" i out=""
  for ((i = 0; i < ${#POLICY_HOLD_ID[@]}; i++)); do
    [[ "${POLICY_HOLD_ID[$i]}" == "$id" ]] || continue
    [[ -n "$out" ]] && out+="; "
    out+="${POLICY_HOLD_REASON[$i]}"
  done
  printf '%s' "$out"
}

# Prints and records a non-npm route hold. Returns 0 when the route must not be touched.
policy_hold_for_route() { # id method
  local id="$1" method="$2" why
  why="$(aicm_policy_route_hold "$id" "$method")"
  [[ -n "$why" ]] || return 1
  echo "hold: $why"
  note_policy_hold "$id" "$why"
  return 0
}

# Effective policy and the holds every route would take, printed outside run_step so dry-run shows it.
report_update_policy() {
  [[ "$AICM_POLICY_PRESENT" == true ]] || return 0
  local i id pin age eff hold method pkg installed
  echo
  echo "== update policy =="
  echo "file: $AICM_HOME/update-policy.json"
  echo "fingerprint: $AICM_POLICY_FINGERPRINT"
  echo "global_min_release_age_days: $MIN_RELEASE_AGE_DAYS"
  for ((i = 0; i < ${#AICM_POLICY_ID[@]}; i++)); do
    id="${AICM_POLICY_ID[$i]}"; pin="${AICM_POLICY_PIN[$i]}"; age="${AICM_POLICY_AGE[$i]}"; eff="${AICM_POLICY_EFF[$i]}"
    if [[ "${AICM_POLICY_EXCLUDE[$i]}" == 1 ]]; then
      echo "$id: excluded by update policy"
    else
      echo "$id: pin=${pin:--} minReleaseAgeDays=${age:--} effectiveMinReleaseAgeDays=$eff"
    fi
  done
  for ((i = 0; i < ${#AICM_CLI_ID[@]}; i++)); do
    id="${AICM_CLI_ID[$i]}"
    cli_is_selected "$id" || continue
    aicm_policy_excluded "$id" && continue
    pin="$(aicm_policy_pin "$id")"
    age="$(aicm_policy_explicit_age "$id")"
    [[ -n "$pin" || ( -n "$age" && "$age" -gt 0 ) ]] || continue
    active_install "$id" || continue
    [[ "$CLI_INSTALLED" == true ]] || continue
    method="$CLI_METHOD"
    hold="$(aicm_policy_route_hold "$id" "$method")"
    if [[ -n "$hold" ]]; then echo "hold: $hold"; continue; fi
    if [[ -n "$pin" && "$method" == npm ]]; then
      pkg="${CLI_NPMPKG:-${AICM_CLI_NPM[$i]}}"
      installed="$(npm_installed_version "$pkg")"
      if [[ -n "$installed" && "$installed" != "$pin" ]] && aicm_version_older "$pin" "$installed"; then
        echo "hold: installed $pkg $installed is newer than the pinned version $pin; no automatic downgrade"
      fi
    fi
  done
}

note_npm_pending() {
  local pkg="$1"
  PENDING=true
  [[ -n "$pkg" ]] || return 0
  case " $NPM_PENDING_PKGS " in
    *" $pkg "*) ;;
    *) NPM_PENDING_PKGS+=" $pkg " ;;
  esac
}

# Set only after an installer command itself exits 0. A hold or a skipped registry check is not an install.
note_install_pkg() {
  case "$INSTALL_OK_PKGS" in *" $1 "*) ;; *) INSTALL_OK_PKGS+="$1 " ;; esac
}
note_install_id() {
  case "$INSTALL_OK_IDS" in *" $1 "*) ;; *) INSTALL_OK_IDS+="$1 " ;; esac
}
cli_install_succeeded() {
  local idx="$1" id="$2" cand npm_names
  case "$INSTALL_OK_IDS" in *" $id "*) return 0 ;; esac
  npm_names="$(aicm_cli_npm_names "$idx" 2>/dev/null)" || true
  while IFS= read -r cand || [[ -n "$cand" ]]; do
    [[ -n "$cand" ]] || continue
    case "$INSTALL_OK_PKGS" in *" $cand "*) return 0 ;; esac
  done <<< "$npm_names"
  return 1
}

take_target_failures() {
  local id="$1" mark="$2" i
  for ((i = mark; i < ${#failures[@]}; i++)); do
    TFAIL_ID+=("$id")
    TFAIL_REASON+=("${failures[$i]}")
  done
}

target_fail_reason() {
  local id="$1" i out=""
  for ((i = 0; i < ${#TFAIL_ID[@]}; i++)); do
    [[ "${TFAIL_ID[$i]}" == "$id" ]] || continue
    [[ -n "$out" ]] && out+="; "
    out+="${TFAIL_REASON[$i]}"
  done
  printf '%s' "$out"
}

# "pending" when this CLI's npm package was skipped for a run-wide network hold, or the reason it was
# deferred because it is running. No per-CLI reason is invented for a hold that never named the package.
cli_pending_reason() {
  local idx="$1" pkg names why
  # Finish the producer before reading: avoid nested asynchronous process substitutions
  # in this captured function on Bash 3.2. Read the buffered output in the same shell.
  names="$(aicm_cli_npm_names "$idx")" || true
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if why="$(npm_deferred_reason "$pkg")"; then printf '%s' "$why"; return 0; fi
    case " $NPM_PENDING_PKGS " in
      *" $pkg "*) printf 'pending'; return 0 ;;
    esac
  done <<< "$names"
  return 1
}

cli_is_selected() {
  local id="$1"
  if [[ "$id" == codex ]]; then gpt_target_enabled; return; fi
  target_enabled "$id"
}

build_verify_rows() {
  local i id
  V_ID=(); V_CMD=(); V_IDX=()
  V_BP=(); V_BV=(); V_BR=()
  V_AP=(); V_AV=(); V_AR=()
  V_STATUS=(); V_REASON=()
  ((${#AICM_CLI_ID[@]})) || aicm_load_catalog "" "" >/dev/null 2>&1 || return 0
  for ((i = 0; i < ${#AICM_CLI_ID[@]}; i++)); do
    id="${AICM_CLI_ID[$i]}"
    cli_is_selected "$id" || continue
    V_ID+=("$id")
    V_CMD+=("${AICM_CLI_CMD[$i]}")
    V_IDX+=("$i")
    V_BP+=(""); V_BV+=(""); V_BR+=("")
    V_AP+=(""); V_AV+=(""); V_AR+=("")
    V_STATUS+=(""); V_REASON+=("")
  done
}

probe_cli() {
  local cmd="$1" path output rc line
  PROBE_PATH=""; PROBE_VER=""; PROBE_RC=""
  hash -r 2>/dev/null || true
  [[ -n "$cmd" ]] || return 0
  path="$(command -v -- "$cmd" 2>/dev/null || true)"
  [[ -n "$path" ]] || return 0
  PROBE_PATH="$path"
  rc=0
  output="$(command_with_timeout "$VERSION_TIMEOUT_SECONDS" "$cmd" --version 2>&1)" || rc=$?
  PROBE_RC="$rc"
  line="$(printf '%s\n' "$output" | sed -n '/[^[:space:]]/{p;q;}')"
  PROBE_VER="${line%$'\r'}"
}

print_probe() {
  local cmd="$1"
  if [[ -z "$PROBE_PATH" ]]; then
    echo "$cmd: not installed"
    return 0
  fi
  printf '%s: ' "$cmd"
  if [[ "$PROBE_RC" == 124 ]]; then
    echo "TIMEOUT after ${VERSION_TIMEOUT_SECONDS}s"
  elif [[ "$PROBE_RC" != 0 ]]; then
    echo "ERROR rc=$PROBE_RC${PROBE_VER:+: $PROBE_VER}"
  elif [[ -z "$PROBE_VER" ]]; then
    echo "ERROR empty version"
  else
    echo "$PROBE_VER"
  fi
  printf '  path: %s\n' "$PROBE_PATH"
}

capture_versions() {
  local side="$1" i
  for ((i = 0; i < ${#V_ID[@]}; i++)); do
    if aicm_policy_excluded "${V_ID[$i]}"; then
      echo "${V_ID[$i]}: excluded by update policy; version is not checked"
      continue
    fi
    if [[ -z "${V_CMD[$i]}" ]]; then
      echo "${V_ID[$i]}: no command; version is not checked"
      continue
    fi
    probe_cli "${V_CMD[$i]}"
    print_probe "${V_CMD[$i]}"
    if [[ "$side" == before ]]; then
      V_BP[i]="$PROBE_PATH"; V_BV[i]="$PROBE_VER"; V_BR[i]="$PROBE_RC"
    else
      V_AP[i]="$PROBE_PATH"; V_AV[i]="$PROBE_VER"; V_AR[i]="$PROBE_RC"
    fi
  done
}

# Healthy means exit 0 and a non-empty version line. Same text => unchanged; a different healthy
# line => updated. This never asks the registry which release is latest.
classify_results() {
  local i id cmd idx bp bv br ap av ar fail_reason defer_reason hold_reason
  for ((i = 0; i < ${#V_ID[@]}; i++)); do
    id="${V_ID[$i]}"; cmd="${V_CMD[$i]}"; idx="${V_IDX[$i]}"
    bp="${V_BP[$i]}"; bv="${V_BV[$i]}"; br="${V_BR[$i]}"
    ap="${V_AP[$i]}"; av="${V_AV[$i]}"; ar="${V_AR[$i]}"
    # Excluded rows are reported, but never probed or failed: exclusion wins over every route.
    if aicm_policy_excluded "$id"; then
      V_STATUS[i]=skipped
      V_REASON[i]="update policy excludes this CLI"
      continue
    fi
    fail_reason="$(target_fail_reason "$id")"
    defer_reason=""
    if defer_reason="$(cli_pending_reason "$idx")"; then :; else defer_reason=""; fi
    hold_reason="$(policy_hold_reason "$id")"
    if [[ -n "$bp" && -z "$ap" ]]; then
      V_STATUS[i]=verifyFailed
      V_REASON[i]="command missing after update"
      record_version_failure "$cmd missing after update"
      continue
    fi
    if [[ -n "$ap" && ( "$ar" != 0 || -z "$av" ) ]]; then
      V_STATUS[i]=verifyFailed
      if [[ "$ar" == 124 ]]; then
        V_REASON[i]="version timed out"
        record_version_failure "$cmd version timeout"
      elif [[ "$ar" != 0 ]]; then
        V_REASON[i]="version failed"
        record_version_failure "$cmd version rc=${ar:-unknown}"
      else
        V_REASON[i]="empty version"
        record_version_failure "$cmd version empty"
      fi
      continue
    fi
    if [[ -n "$fail_reason" ]]; then
      V_STATUS[i]=updateFailed
      V_REASON[i]="$fail_reason"
      continue
    fi
    if [[ -z "$cmd" ]]; then
      V_STATUS[i]=unsupported
      V_REASON[i]="unsupported verification"
      continue
    fi
    if [[ -n "$hold_reason" ]]; then
      V_STATUS[i]=skipped
      V_REASON[i]="$hold_reason"
      continue
    fi
    if [[ -n "$defer_reason" ]]; then
      V_STATUS[i]=deferred
      V_REASON[i]="$defer_reason"
      continue
    fi
    if [[ -z "$bp" && -z "$ap" ]]; then
      if cli_install_succeeded "$idx" "$id"; then
        V_STATUS[i]=verifyFailed
        V_REASON[i]="command missing after update"
        record_version_failure "${cmd:-$id} missing after update"
        continue
      fi
      V_STATUS[i]=skipped
      V_REASON[i]="not installed"
      continue
    fi
    if [[ "$br" == 0 && -n "$bv" && "$bv" == "$av" ]]; then
      V_STATUS[i]=unchanged
      V_REASON[i]=""
    else
      V_STATUS[i]=updated
      V_REASON[i]=""
    fi
  done
}

# After last-update.json is on disk. Stdout is discarded. A history failure is a warning only.
# Dry-run, already-updated-today, and lock refusal return before this is reached.
record_update_history() {
  local js err rc=0
  command -v node >/dev/null 2>&1 || return 0
  js="$AICM_ROOT/lib/maintenance.js"
  [[ -f "$js" ]] || return 0
  err="$(aicm_timeout 60 node "$js" history-add --kind update --file "$AICM_HOME/state/last-update.json" 2>&1 >/dev/null)" || rc=$?
  if [[ "$rc" != 0 ]]; then
    echo "warn: update history failed: ${err:-exit $rc}" >&2
  fi
  return 0
}

# True when some targeted CLI has a healthy after probe whose version differs from a healthy before
# probe, or whose before probe was missing or unhealthy. A broken or missing after probe never counts.
version_changed() {
  local i bv br av ar
  for ((i = 0; i < ${#V_ID[@]}; i++)); do
    # Only a row that actually reached "updated" may fire the hook. Excluded/held rows can show a
    # different --version text between probes (a nonstable version output) without any update.
    [[ "${V_STATUS[$i]}" == updated ]] || continue
    bv="${V_BV[$i]}"; br="${V_BR[$i]}"; av="${V_AV[$i]}"; ar="${V_AR[$i]}"
    [[ "$ar" == 0 && -n "$av" ]] || continue
    if [[ "$br" != 0 || -z "$bv" || "$bv" != "$av" ]]; then return 0; fi
  done
  return 1
}

json_rc() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}

verify_results_json() {
  local i out="" brj arj
  out="["
  for ((i = 0; i < ${#V_ID[@]}; i++)); do
    ((i > 0)) && out+=","
    brj="$(json_rc "${V_BR[$i]}")"
    arj="$(json_rc "${V_AR[$i]}")"
    out+="{\"id\":\"$(aicm_json_escape "${V_ID[$i]}")\",\"command\":\"$(aicm_json_escape "${V_CMD[$i]}")\""
    out+=",\"before\":{\"path\":\"$(aicm_json_escape "${V_BP[$i]}")\",\"version\":\"$(aicm_json_escape "${V_BV[$i]}")\",\"exitCode\":$brj}"
    out+=",\"after\":{\"path\":\"$(aicm_json_escape "${V_AP[$i]}")\",\"version\":\"$(aicm_json_escape "${V_AV[$i]}")\",\"exitCode\":$arj}"
    out+=",\"status\":\"$(aicm_json_escape "${V_STATUS[$i]}")\",\"reason\":\"$(aicm_json_escape "${V_REASON[$i]}")\"}"
  done
  out+="]"
  printf '%s' "$out"
}

is_brew_cask_installed() {
  command -v "$BREW" >/dev/null 2>&1 && "$BREW" list --cask "$1" >/dev/null 2>&1
}

is_brew_formula_installed() {
  command -v "$BREW" >/dev/null 2>&1 && "$BREW" list --formula "$1" >/dev/null 2>&1
}

is_npm_global_installed() {
  command -v "$NPM" >/dev/null 2>&1 && "$NPM" list -g --depth=0 "$1" >/dev/null 2>&1
}

npm_global_package_path() {
  local pkg="$1" root
  root="$("$NPM" root -g 2>/dev/null || true)"
  [[ -n "$root" ]] || return 1
  printf '%s/%s\n' "$root" "$pkg"
}

is_npm_global_package_writable() {
  local pkg="$1" pkg_path pkg_parent
  pkg_path="$(npm_global_package_path "$pkg")" || return 1
  pkg_parent="$(dirname "$pkg_path")"
  [[ -w "$pkg_path" && -w "$pkg_parent" ]]
}

update_brew_package() {
  local name="$1"
  local outdated rc
  if is_brew_cask_installed "$name"; then
    outdated="$(aicm_timeout 300 "$BREW" outdated --cask "$name" 2>&1)"
    rc=$?
    if ((rc != 0)) && [[ "$outdated" != *"$name"* ]]; then
      echo "$outdated"
      return "$rc"
    fi
    if [[ -n "$outdated" ]]; then
      aicm_timeout "$INSTALL_TIMEOUT_SECONDS" "$BREW" upgrade --cask "$name"
    else
      echo "brew cask already up-to-date: $name"
    fi
  elif is_brew_formula_installed "$name"; then
    outdated="$(aicm_timeout 300 "$BREW" outdated --formula "$name" 2>&1)"
    rc=$?
    if ((rc != 0)) && [[ "$outdated" != *"$name"* ]]; then
      echo "$outdated"
      return "$rc"
    fi
    if [[ -n "$outdated" ]]; then
      aicm_timeout "$INSTALL_TIMEOUT_SECONDS" "$BREW" upgrade --formula "$name"
    else
      echo "brew formula already up-to-date: $name"
    fi
  else
    echo "brew package not installed: $name"
  fi
}

npm_installed_version() {
  local root
  root="$("$NPM" root -g 2>/dev/null)" || return 0
  [[ -f "$root/$1/package.json" ]] || return 0
  node -p "require(process.argv[1]).version" "$root/$1/package.json" 2>/dev/null || true
}

# Only releases at least MIN_RELEASE_AGE_DAYS old are installed, and only after they look like the
# installed release (provenance kept, no new install scripts) and pass a staged signature check.
# Registry reachable? Checked once per run; when it is not, npm updates are skipped, not failed.
REGISTRY_OK=""
PENDING=false
registry_ok() {
  if [[ -z "$REGISTRY_OK" ]]; then
    if aicm_timeout 30 "$NPM" ping >/dev/null 2>&1; then REGISTRY_OK=yes; else REGISTRY_OK=no; echo "registry unreachable: npm updates are skipped this run and retried later"; fi
  fi
  [[ "$REGISTRY_OK" == yes ]]
}

# npm packages this run looked after ("pkg" lines) and those known from earlier runs that are still
# installed ("pkg<TAB>version" lines); written to state/update-npm.tsv at the end.
MANAGED_NPM=""
KNOWN_NPM=""
NPM_STATE="$AICM_HOME/state/update-npm.tsv"
remember_npm() { [[ $'\n'"$MANAGED_NPM" == *$'\n'"$1"$'\n'* ]] || MANAGED_NPM+="$1"$'\n'; }

# The real install. --before applies the waiting period to the dependencies too; the time limit keeps a
# postinstall that hangs on the network from holding the lock forever.
npm_global_install() { # spec [extra args]
  local rc=0
  aicm_timeout "$INSTALL_TIMEOUT_SECONDS" "$NPM" install -g "$@" || rc=$?
  ((rc == 124)) && echo "npm install $1 did not finish within ${INSTALL_TIMEOUT_SECONDS}s and was stopped"
  return "$rc"
}

# Processes running from global npm package $1, one "pid command" line each. npm replaces the package
# folder in place: a session that is already running keeps the old code in memory and may later load a
# file of the new release, so the update waits until the CLI is closed. A process counts when its
# command line names the package folder or an npm bin link, its title starts with a bin link's bare
# name, or lsof shows it executing a file a link points to. A CLI may rewrite its process title and
# close its script, making the bare name the only remaining clue. That clue can also match another
# installation of the same CLI, so it is deliberately conservative.
npm_package_users() { # pkg
  local pkg="$1" root prefix dir real link target links="" names="" targets=() pids="" lsof
  aicm_npm_cache
  root="$AICM_NPM_ROOT_CACHE"
  [[ -n "$root" && -d "$root/$pkg" ]] || return 0
  dir="$root/$pkg/"
  real="$(aicm_realpath "$root/$pkg")/"
  prefix="$AICM_NPM_PREFIX_CACHE"
  if [[ -n "$prefix" && -d "$prefix/bin" ]]; then
    for link in "$prefix/bin"/*; do
      [[ -L "$link" ]] || continue
      target="$(aicm_realpath "$link")"
      [[ "$target" == "$real"* ]] || continue
      links+="$link"$'\n'
      names+="${link##*/}"$'\n'
      [[ -f "$target" ]] && targets+=("$target")
    done
  fi
  lsof="$(command -v lsof 2>/dev/null || true)"
  [[ -z "$lsof" && -x /usr/sbin/lsof ]] && lsof=/usr/sbin/lsof
  if ((${#targets[@]})) && [[ -n "$lsof" ]]; then
    pids="$(aicm_timeout 15 "$lsof" -t -- "${targets[@]}" 2>/dev/null | sort -u | paste -sd ' ' -)" || true
  fi
  ps -A -ww -o pid= -o args= 2>/dev/null | D="$dir" R="$real" L="$links" N="$names" P=" $pids " SELF="$$" awk '
    BEGIN { n = split(ENVIRON["L"], links, "\n"); split(ENVIRON["N"], names, "\n") }
    {
      line = $0; sub(/^ +/, "", line)
      pid = line; sub(/ .*/, "", pid)
      if (pid == ENVIRON["SELF"]) next
      args = " " substr(line, length(pid) + 2) " "
      first = substr(line, length(pid) + 2); sub(/[[:space:]].*/, "", first)
      hit = index(args, ENVIRON["D"]) || index(args, ENVIRON["R"]) || index(ENVIRON["P"], " " pid " ")
      for (i = 1; !hit && i <= n; i++) {
        if (links[i] != "" && index(args, " " links[i] " ")) hit = 1
        else if (names[i] != "" && index(first, "/") == 0 && first == names[i]) hit = 1
      }
      if (hit) print line
    }' || true
}

# npm packages left alone this run because they are running (pkg and reason, same index).
DEFER_PKG=(); DEFER_WHY=(); DEFER_RESOLVED=()
DEFER_STATE="$AICM_HOME/state/update-deferred.tsv"

# Returns 0 (and records the deferral) when $1 is running. AICM_DEFER_RUNNING=0 updates it anyway.
defer_if_running() { # pkg
  local pkg="$1" users count first pid cmd why
  [[ "${AICM_DEFER_RUNNING:-1}" != 0 ]] || return 1
  users="$(npm_package_users "$pkg")"
  [[ -n "$users" ]] || return 1
  count="$(printf '%s\n' "$users" | awk 'END { print NR }')"
  first="${users%%$'\n'*}"; pid="${first%% *}"; cmd="${first#* }"; cmd="${cmd%% *}"
  why="is running ($count processes, e.g. ${cmd##*/} pid $pid)"
  echo "deferred: $pkg $why; retried on the next run"
  DEFER_PKG+=("$pkg"); DEFER_WHY+=("$why")
  PENDING=true
  return 0
}

npm_deferred_reason() { # pkg
  local i
  for ((i = 0; i < ${#DEFER_PKG[@]}; i++)); do
    if [[ "${DEFER_PKG[$i]}" == "$1" ]]; then printf '%s' "${DEFER_WHY[$i]}"; return 0; fi
  done
  return 1
}

# Preserve unresolved entries even during a partial or offline run. A successful install or a
# confirmed current version clears the entry; the third field records that the reminder was sent.
note_deferred_since() {
  local now i pkg first sent record old_pkg old_first old_sent keep out=""
  now="$(date +%s)"
  if [[ -f "$DEFER_STATE" ]]; then
    while IFS=$'\t' read -r old_pkg old_first old_sent; do
      [[ -n "$old_pkg" && "$old_first" =~ ^[0-9]+$ ]] || continue
      keep=1
      for ((i = 0; i < ${#DEFER_RESOLVED[@]}; i++)); do
        [[ "${DEFER_RESOLVED[$i]}" == "$old_pkg" ]] && keep=0
      done
      for ((i = 0; i < ${#DEFER_PKG[@]}; i++)); do
        [[ "${DEFER_PKG[$i]}" == "$old_pkg" ]] && keep=0
      done
      if ((keep)); then
        [[ "$old_sent" == 1 ]] || old_sent=0
        out+="$old_pkg"$'\t'"$old_first"$'\t'"$old_sent"$'\n'
      fi
    done < "$DEFER_STATE"
  fi
  for ((i = 0; i < ${#DEFER_PKG[@]}; i++)); do
    pkg="${DEFER_PKG[$i]}"
    [[ $'\n'"$out" == *$'\n'"$pkg"$'\t'* ]] && continue
    record=""
    [[ -f "$DEFER_STATE" ]] && record="$(P="$pkg" awk -F '\t' '$1 == ENVIRON["P"] { print $2 "\t" $3; exit }' "$DEFER_STATE")"
    first="${record%%$'\t'*}"; sent="${record#*$'\t'}"
    [[ "$first" =~ ^[0-9]+$ ]] || first="$now"
    [[ "$sent" == 1 ]] || sent=0
    if ((now - first >= 5 * 86400 && sent == 0)); then
      problems+=("$pkg has been deferred for at least 5 days because it was running; close its sessions for a moment or run 'aicm update' when it is idle")
      sent=1
    fi
    out+="$pkg"$'\t'"$first"$'\t'"$sent"$'\n'
  done
  mkdir -p "$AICM_HOME/state"
  printf '%s' "$out" > "$DEFER_STATE.$$.tmp" && mv -f "$DEFER_STATE.$$.tmp" "$DEFER_STATE"
}

update_npm_package() { # pkg [pin] [age] [id]
  local pkg="$1" pin="${2:-}" age="${3:-$MIN_RELEASE_AGE_DAYS}" id="${4:-}" installed target before hold amp="" existing
  # A hold recorded earlier in this run (for example an interrupted install kept for manual repair)
  # must not be bypassed by the normal npm update path.
  if [[ -n "$id" ]]; then
    existing="$(policy_hold_reason "$id")"
    if [[ -n "$existing" ]]; then echo "hold: $existing"; return 0; fi
  fi
  [[ "$age" =~ ^[0-9]+$ ]] || age="$MIN_RELEASE_AGE_DAYS"
  case "$pkg" in @ampcode/cli|@sourcegraph/amp) amp=1 ;; esac
  if ! registry_ok; then note_npm_pending "$pkg"; return 0; fi
  if is_npm_global_installed "$pkg"; then
    remember_npm "$pkg"
    installed="$(npm_installed_version "$pkg")"
    if [[ -n "$pin" ]]; then
      if [[ -n "$installed" && "$installed" == "$pin" ]]; then
        echo "already at the pinned version: $pkg $installed"
        DEFER_RESOLVED+=("$pkg")
        return 0
      fi
      # Two Amp commit builds with the same timestamp have no trustworthy order.
      if [[ "$amp" == 1 && "$installed" == 0.0.*-g* && "$pin" == 0.0.*-g* && "${installed%%-*}" == "${pin%%-*}" ]]; then
        hold="cannot order installed $pkg $installed against the pinned Amp build $pin (same timestamp); nothing was installed"
        echo "hold: $hold"
        note_policy_hold "$id" "update policy: $hold"
        return 0
      fi
      # Exact pins never fall back to latest and never downgrade. Amp's timestamp-hash versions can
      # only be ordered by their timestamp, so equal timestamps with different hashes are ambiguous.
      if [[ -n "$installed" ]] && aicm_version_older "$pin" "$installed"; then
        hold="installed $pkg $installed is newer than the pinned version $pin; no automatic downgrade"
        echo "hold: $hold"
        note_policy_hold "$id" "update policy: $hold"
        return 0
      fi
      if [[ -n "$installed" ]] && ! aicm_version_older "$installed" "$pin"; then
        hold="cannot order installed $pkg $installed against the pinned version $pin; no downgrade or upgrade was attempted"
        echo "hold: $hold"
        note_policy_hold "$id" "update policy: $hold"
        return 0
      fi
      hold="$(aicm_policy_validate_pin "$pkg" "$pin" "$age" "$amp")" || { echo "$hold"; return 1; }
      if [[ -n "$hold" ]]; then
        echo "hold: $hold"
        note_policy_hold "$id" "update policy: $hold"
        return 0
      fi
      echo "candidate: $pkg $installed -> $pin (pinned)"
      defer_if_running "$pkg" && return 0
      aicm_npm_check "$pkg" "$installed" "$pin" "$age" || return 1
      before="$(aicm_npm_before "$age")"
      defer_if_running "$pkg" && return 0
      if npm_global_install "$pkg@$pin" ${before:+"$before"}; then
        note_install_pkg "$pkg"
        DEFER_RESOLVED+=("$pkg")
      else
        return $?
      fi
      return 0
    fi
    target="$(aicm_npm_target "$pkg" "$age" "$installed" skip-deprecated)" || { echo "could not read the release list of $pkg"; return 1; }
    if [[ -z "$target" ]]; then
      echo "hold: no release of $pkg is $age days old yet"
      if [[ -n "$id" && -n "$(aicm_policy_explicit_age "$id")" ]]; then
        note_policy_hold "$id" "update policy: no release of $pkg is $age days old yet"
      fi
      return 0
    fi
    if [[ -n "$installed" ]] && ! aicm_version_older "$installed" "$target"; then
      echo "already current: $pkg $installed (newest release at least $age days old: $target)"
      DEFER_RESOLVED+=("$pkg")
      return 0
    fi
    echo "candidate: $pkg $installed -> $target"
    defer_if_running "$pkg" && return 0
    aicm_npm_check "$pkg" "$installed" "$target" "$age" || return 1
    before="$(aicm_npm_before "$age")"
    defer_if_running "$pkg" && return 0
    if npm_global_install "$pkg@$target" ${before:+"$before"}; then
      note_install_pkg "$pkg"
      DEFER_RESOLVED+=("$pkg")
    else
      return $?
    fi
  else
    echo "npm global package not installed: $pkg"
  fi
}

install_npm_package() { # pkg [pin] [age] [id]
  local pkg="$1" pin="${2:-}" age="${3:-$MIN_RELEASE_AGE_DAYS}" id="${4:-}" target before hold amp="" rc=0 existing
  # Same guard as update_npm_package: an earlier recovery hold blocks a fresh install too.
  if [[ -n "$id" ]]; then
    existing="$(policy_hold_reason "$id")"
    if [[ -n "$existing" ]]; then echo "hold: $existing"; return 0; fi
  fi
  [[ "$age" =~ ^[0-9]+$ ]] || age="$MIN_RELEASE_AGE_DAYS"
  case "$pkg" in @ampcode/cli|@sourcegraph/amp) amp=1 ;; esac
  command -v "$NPM" >/dev/null 2>&1 || { echo "npm is not installed"; return 1; }
  remember_npm "$pkg"
  if [[ -n "$pin" ]]; then
    hold="$(aicm_policy_validate_pin "$pkg" "$pin" "$age" "$amp")" || { echo "$hold"; return 1; }
    if [[ -n "$hold" ]]; then
      echo "hold: $hold"
      note_policy_hold "$id" "update policy: $hold"
      return 0
    fi
    echo "installing pinned version: $pkg $pin"
    aicm_npm_check "$pkg" "" "$pin" "$age" || return 1
    before="$(aicm_npm_before "$age")"
    npm_global_install "$pkg@$pin" ${before:+"$before"} || rc=$?
    if [[ "$rc" == 0 ]]; then note_install_pkg "$pkg"; fi
    return "$rc"
  fi
  target="$(aicm_npm_target "$pkg" "$age" "" skip-deprecated)" || { echo "could not read the release list of $pkg"; return 1; }
  [[ -n "$target" ]] || {
    echo "hold: no release of $pkg is $age days old yet"
    if [[ -n "$id" && -n "$(aicm_policy_explicit_age "$id")" ]]; then
      note_policy_hold "$id" "update policy: no release of $pkg is $age days old yet"
    fi
    return 0
  }
  aicm_npm_check "$pkg" "" "$target" "$age" || return 1
  before="$(aicm_npm_before "$age")"
  npm_global_install "$pkg@$target" ${before:+"$before"} || rc=$?
  if [[ "$rc" == 0 ]]; then note_install_pkg "$pkg"; fi
  return "$rc"
}

# npm CLIs this updater managed before. One that is gone now was either removed on purpose or lost to
# an interrupted install (npm moved it to a backup folder .<name>-XXXXXXXX and never finished). With
# such a backup it is reinstalled at the same version; otherwise it is reported once and forgotten,
# so an intentional uninstall is not fought every day.
restore_missing_npm() {
  local pkg version backup i cand skip_restore npm_shim real_bin real_cmd owner_id pin age why amp npm_names
  [[ -f "$NPM_STATE" ]] && command -v "$NPM" >/dev/null 2>&1 || return 0
  if ((${#AICM_CLI_ID[@]} == 0)); then aicm_load_catalog "" "" >/dev/null 2>&1 || true; fi
  while IFS=$'\t' read -r pkg version; do
    [[ -n "$pkg" ]] || continue
    if [[ -n "$(aicm_npm_pkg_version "$pkg")" ]]; then KNOWN_NPM+="$pkg"$'\t'"$version"$'\n'; continue; fi
    skip_restore=false
    owner_id=""
    for ((i = 0; i < ${#AICM_CLI_ID[@]}; i++)); do
      npm_names="$(aicm_cli_npm_names "$i")" || true
      while IFS= read -r cand; do
        [[ "$cand" == "$pkg" ]] || continue
        owner_id="${AICM_CLI_ID[$i]}"
        aicm_cli_install "$i"
        # A regular npm launcher can remain after its package was moved to a backup.
        # Its old managed state and location identify a recovery candidate, rather than
        # an unrelated standalone install. Resolved targets outside prefix/bin stay excluded.
        npm_shim=false
        if [[ "$CLI_METHOD" == standalone && -n "$AICM_NPM_PREFIX_CACHE" && -n "$CLI_PATH" ]]; then
          real_bin="$(aicm_realpath "$AICM_NPM_PREFIX_CACHE/bin")"
          real_cmd="$(aicm_realpath "$CLI_PATH")"
          if [[ -n "$real_bin" && "$real_cmd" == "$real_bin/"* && "$(head -c 2 "$CLI_PATH" 2>/dev/null)" == '#!' ]]; then
            if grep -Fq -- "$AICM_NPM_ROOT_CACHE/$pkg" "$CLI_PATH" || grep -Fq -- "node_modules/$pkg/" "$CLI_PATH"; then npm_shim=true; fi
          fi
        fi
        if [[ "$CLI_INSTALLED" == true && "$npm_shim" != true && ( "$CLI_METHOD" != npm || "$CLI_NPMPKG" != "$pkg" ) ]]; then
          echo "pass: unused npm copy $pkg is not restored while PATH selects ${CLI_PATH:-another package}"
          skip_restore=true
        fi
      done <<< "$npm_names"
    done
    [[ "$skip_restore" == true ]] && {
      # Keep the old entry while policy or target selection can still matter: removing the policy later
      # may need it to repair an interrupted install. With every target selected and no policy rule this
      # entry is dropped, so an intentionally removed hidden package is not revived.
      local held_age=""
      [[ -n "$owner_id" ]] && held_age="$(aicm_policy_explicit_age "$owner_id")"
      if [[ -n "$owner_id" ]] && {
        aicm_policy_excluded "$owner_id" ||
        [[ -n "$(aicm_policy_pin "$owner_id")" ]] ||
        [[ -n "$held_age" ]] ||
        ! cli_is_selected "$owner_id"
      }; then
        KNOWN_NPM+="$pkg"$'\t'"$version"$'\n'
      fi
      continue
    }
    # Recovery follows target selection and policy. A skipped package keeps its old entry so removing
    # the policy later can still repair an interrupted install.
    if [[ -n "$owner_id" ]]; then
      if ! cli_is_selected "$owner_id"; then
        echo "pass: $pkg is not restored because $owner_id is not selected for this run"
        KNOWN_NPM+="$pkg"$'\t'"$version"$'\n'
        continue
      fi
      if aicm_policy_excluded "$owner_id"; then
        echo "pass: $pkg is not restored because update policy excludes $owner_id"
        KNOWN_NPM+="$pkg"$'\t'"$version"$'\n'
        continue
      fi
      pin="$(aicm_policy_pin "$owner_id")"
      if [[ -n "$pin" ]]; then
        # A configured pin may be age-guarded by the inherited global age, and recovery
        # cannot safely rerun the full release/security guards here. Keep the backup and state so a
        # manual install (or removing the pin) can still repair it; never reinstall unchecked.
        if [[ "$version" == "$pin" ]]; then
          why="update policy pins $owner_id to $pin; automatic recovery is held to keep the release guards, so restore it manually with: npm install -g $pkg@$pin"
        else
          why="update policy pins $owner_id to $pin, so the interrupted $pkg $version install is not restored"
        fi
        echo "hold: $why"
        note_policy_hold "$owner_id" "$why"
        KNOWN_NPM+="$pkg"$'\t'"$version"$'\n'
        continue
      fi
      age="$(aicm_policy_explicit_age "$owner_id")"
      if [[ -n "$age" && "$age" -gt 0 ]]; then
        amp=""
        case "$pkg" in @ampcode/cli|@sourcegraph/amp) amp=1 ;; esac
        if ! why="$(aicm_policy_validate_pin "$pkg" "$version" "$age" "$amp")"; then
          echo "hold: could not check the release age of $pkg $version, so the interrupted install is not restored: $why"
          KNOWN_NPM+="$pkg"$'\t'"$version"$'\n'
          continue
        fi
        if [[ -n "$why" ]]; then
          echo "hold: update policy: $why; the interrupted $pkg install is not restored"
          note_policy_hold "$owner_id" "update policy: $why"
          KNOWN_NPM+="$pkg"$'\t'"$version"$'\n'
          continue
        fi
      fi
    elif [[ "$(run_targets)" != all ]]; then
      echo "pass: $pkg is not restored because it is not selected for this run"
      KNOWN_NPM+="$pkg"$'\t'"$version"$'\n'
      continue
    fi
    echo
    echo "== missing npm CLI: $pkg =="
    if ! backup="$(aicm_npm_backup "$pkg")"; then
      echo "fail: $pkg ($version) was installed at the last update and is gone now"
      failures+=("$pkg disappeared since the last update; reinstall it with 'npm install -g $pkg@$version', or ignore this if you removed it rc=1")
      continue
    fi
    echo "found npm's backup of an interrupted install: $backup"
    KNOWN_NPM+="$pkg"$'\t'"$version"$'\n'
    if ! registry_ok; then note_npm_pending "$pkg"; continue; fi
    if npm_global_install "$pkg@$version"; then
      echo "restored: $pkg $version"
    else
      failures+=("$pkg was lost by an interrupted install and could not be reinstalled; run 'npm install -g $pkg@$version' rc=1")
    fi
  done < "$NPM_STATE"
  return 0
}

save_npm_state() {
  local out="$KNOWN_NPM" pkg version
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    version="$(aicm_npm_pkg_version "$pkg")"
    [[ -n "$version" ]] || continue
    out="$(printf '%s' "$out" | awk -F '\t' -v p="$pkg" '$1 != p')"$'\n'"$pkg"$'\t'"$version"$'\n'
  done <<< "$MANAGED_NPM"
  mkdir -p "$AICM_HOME/state"
  printf '%s' "$out" | awk 'NF' > "$NPM_STATE.$$.tmp" && mv -f "$NPM_STATE.$$.tmp" "$NPM_STATE"
}

update_agy_cli() {
  if command -v agy >/dev/null 2>&1; then
    command_with_timeout 300 agy update
  else
    echo "agy command not installed"
  fi
}

# The copy on PATH decides how a CLI is updated. A second copy elsewhere (for example an npm copy
# behind a standalone one) is reported, because updating it would not change what the terminal runs.
active_install() { # id -> sets CLI_INSTALLED CLI_PATH CLI_METHOD CLI_NPMCOPY
  local idx
  if ((${#AICM_CLI_ID[@]} == 0)); then aicm_load_catalog "" "" >/dev/null 2>&1 || return 1; fi
  idx="$(aicm_cli_index "$1")" || return 1
  aicm_cli_install "$idx"
}

active_brew_install() { # catalog id, brew package
  active_install "$1" || return 1
  [[ "$CLI_INSTALLED" == true && "$CLI_METHOD" == brew ]] || return 1
  is_brew_cask_installed "$2" || is_brew_formula_installed "$2"
}

shadow_warning() {
  active_install "$1" || return 0
  if [[ -n "$CLI_NPMCOPY" && "$CLI_METHOD" != npm ]]; then
    echo "warn: PATH runs $CLI_PATH; the npm copy $CLI_NPMCOPY is a second install that the terminal does not use."
    echo "      $(aicm_shadow_fix "$CLI_PATH")"
  fi
  return 0
}

update_claude_cli() {
  local pin age
  pin="$(aicm_policy_pin claude)"
  age="$(aicm_policy_effective_age claude "$MIN_RELEASE_AGE_DAYS")"
  if active_install claude && [[ "$CLI_INSTALLED" == true && "$CLI_METHOD" == standalone ]]; then
    policy_hold_for_route claude standalone && return 0
    command_with_timeout 300 "$CLI_PATH" update || return $?
    shadow_warning claude
  elif active_brew_install claude claude-code; then
    policy_hold_for_route claude brew && return 0
    update_brew_package claude-code
  elif active_install claude && [[ "$CLI_METHOD" == npm ]] && is_npm_global_installed "@anthropic-ai/claude-code"; then
    update_npm_package "@anthropic-ai/claude-code" "$pin" "$age" claude
  elif command -v claude >/dev/null 2>&1; then
    policy_hold_for_route claude vendor && return 0
    command_with_timeout 300 claude update
  elif [[ "$INSTALL_MISSING" == "true" ]]; then
    install_npm_package "@anthropic-ai/claude-code" "$pin" "$age" claude
  else
    pass_missing claude "command not found and no supported package manager install detected"
  fi
}

update_opencode_cli() {
  local pin age
  pin="$(aicm_policy_pin opencode)"
  age="$(aicm_policy_effective_age opencode "$MIN_RELEASE_AGE_DAYS")"
  if active_install opencode && [[ "$CLI_INSTALLED" == true && "$CLI_METHOD" == standalone ]]; then
    policy_hold_for_route opencode standalone && return 0
    command_with_timeout 300 "$CLI_PATH" upgrade || return $?
    shadow_warning opencode
  elif active_brew_install opencode opencode; then
    policy_hold_for_route opencode brew && return 0
    update_brew_package opencode
  elif active_install opencode && [[ "$CLI_METHOD" == npm ]]; then
    # Keep the PATH-owning major version when V1 and V2 are both installed.
    update_npm_package "$CLI_NPMPKG" "$pin" "$age" opencode
  elif command -v opencode >/dev/null 2>&1; then
    policy_hold_for_route opencode vendor && return 0
    command_with_timeout 300 opencode upgrade
  elif [[ "$INSTALL_MISSING" == "true" ]]; then
    install_npm_package "@opencode/cli" "$pin" "$age" opencode
  else
    pass_missing opencode "command not found and no supported package manager install detected"
  fi
}

# Limitation: the vendor updaters (claude update, opencode upgrade, agy update, brew, catalog
# self-updates) install whatever their vendor serves; the npm waiting period and release checks cannot
# be applied to them. The installer-backed updaters of Grok and Codex are gated (see installer_update_due).
install_or_update_grok_cli() {
  command -v curl >/dev/null 2>&1 || { echo "curl is not installed"; return 1; }
  command_with_timeout 300 bash -c 'curl -fsSL https://x.ai/cli/install.sh | bash'
}

# A vendor installer is a remote script that always installs the newest release. Succeeds only when
# the installed version is known, a newer release exists, and that newest release is itself past the
# waiting period. The npm package carries the same version numbers and publish dates.
installer_update_due() { # name command npm-package [days]
  local name="$1" cmd="$2" pkg="$3" days="${4:-$MIN_RELEASE_AGE_DAYS}" have want newest
  [[ "$days" =~ ^[0-9]+$ ]] || days="$MIN_RELEASE_AGE_DAYS"
  have="$(aicm_timeout 15 "$cmd" --version 2>&1 | aicm_semver || true)"
  if [[ -z "$have" ]]; then
    echo "skip: cannot read the installed $name version, so the installer is not run unattended; update it by hand"
    return 1
  fi
  if ! command -v "$NPM" >/dev/null 2>&1; then
    echo "skip: npm is needed to look up $name release dates; the installer is not run unattended. Update $name by hand"
    return 1
  fi
  if ! registry_ok; then note_npm_pending "$pkg"; return 1; fi
  want="$(aicm_npm_target "$pkg" "$days" || true)"
  if [[ -z "$want" ]] || ! aicm_version_older "$have" "$want"; then
    echo "already current: $name $have (newest release at least $days days old: $want)"
    return 1
  fi
  if ((days > 0)); then
    newest="$(AICM_NPM_TIMEOUT=60 aicm_npm view "$pkg" version 2>/dev/null | aicm_semver || true)"
    if [[ -n "$newest" && "$newest" != "$want" ]]; then
      echo "hold: $name $want is old enough, but the installer would install $newest, which is still in its $days-day waiting period"
      return 1
    fi
  fi
  echo "candidate: $name $have -> $want"
}

# `codex update` reruns the official installer, so it is gated like the Grok installer.
update_codex_standalone() { # codex path [days]
  installer_update_due codex "$1" "@openai/codex" "${2:-$MIN_RELEASE_AGE_DAYS}" || return 0
  command_with_timeout 300 "$1" update
}

update_grok_cli() {
  local pin age
  pin="$(aicm_policy_pin grok)"
  age="$(aicm_policy_effective_age grok "$MIN_RELEASE_AGE_DAYS")"
  # The catalog owner detector decides the route, exactly like the other CLIs: an npm launcher
  # (prefix/bin symlink or package-owned shim) gets the npm pin/age checks, while a standalone copy
  # stays on the gated vendor installer even when a hidden npm package exists.
  if active_install grok && [[ "$CLI_INSTALLED" == true && "$CLI_METHOD" == npm ]] && is_npm_global_installed "${CLI_NPMPKG:-@xai-official/grok}"; then
    update_npm_package "${CLI_NPMPKG:-@xai-official/grok}" "$pin" "$age" grok
  elif active_install grok && [[ "$CLI_INSTALLED" == true ]]; then
    policy_hold_for_route grok vendor && return 0
    installer_update_due grok "$CLI_PATH" "@xai-official/grok" "$age" || return 0
    install_or_update_grok_cli || return $?
    shadow_warning grok
  elif [[ "$INSTALL_MISSING" == "true" ]]; then
    policy_hold_for_route grok vendor && return 0
    if install_or_update_grok_cli; then note_install_id grok; else return $?; fi
  else
    pass_missing grok "command not found"
  fi
}

self_update_cli() { # command args...
  local cmd="$1"; shift
  command_with_timeout 300 "$cmd" "$@"
}

# Catalog CLIs without dedicated logic (rules/ai-clis.conf). Only installed ones are touched.
EXTRA_IDX=()
collect_catalog_extras() {
  aicm_load_catalog "" "" || return 0
  local i id
  for ((i = 0; i < ${#AICM_CLI_ID[@]}; i++)); do
    id="${AICM_CLI_ID[$i]}"
    aicm_is_builtin "$id" && continue
    target_enabled "$id" || continue
    aicm_policy_excluded "$id" && continue
    [[ -n "${AICM_CLI_CMD[$i]}" ]] || continue
    aicm_cli_install "$i"
    if [[ "$CLI_INSTALLED" == true ]] || { [[ "$INSTALL_MISSING" == true && -n "${AICM_CLI_NPM[$i]}" ]] && target_named "$id"; }; then
      EXTRA_IDX+=("$i")
    fi
  done
}

update_catalog_extra() {
  local i="$1" name self_args id pin age
  id="${AICM_CLI_ID[$i]}"
  name="${AICM_CLI_NAME[$i]}"
  pin="$(aicm_policy_pin "$id")"
  age="$(aicm_policy_effective_age "$id" "$MIN_RELEASE_AGE_DAYS")"
  aicm_cli_install "$i"
  if [[ "$CLI_INSTALLED" != true ]]; then
    run_step "$name via npm install" install_npm_package "${AICM_CLI_NPM[$i]}" "$pin" "$age" "$id"
    return 0
  fi
  case "$CLI_METHOD" in
    npm) run_step "$name via npm" update_npm_package "${CLI_NPMPKG:-${AICM_CLI_NPM[$i]}}" "$pin" "$age" "$id" ;;
    brew)
      if policy_hold_for_route "$id" brew; then return 0; fi
      if [[ -n "${AICM_CLI_BREW[$i]}" ]]; then run_step "$name via brew" update_brew_package "${AICM_CLI_BREW[$i]}"
      else pass_missing "$id" "installed with Homebrew but the catalog has no Homebrew name"; fi ;;
    *)
      if policy_hold_for_route "$id" standalone; then return 0; fi
      if [[ -n "${AICM_CLI_SELF[$i]}" && "${AICM_CLI_SELF[$i]}" != "@installer" ]]; then
        read -r -a self_args <<< "${AICM_CLI_SELF[$i]}"
        run_step "$name self-update" self_update_cli "${AICM_CLI_CMD[$i]}" "${self_args[@]}"
      else
        echo
        echo "pass: $name is installed standalone without a self-update command; update it manually"
      fi ;;
  esac
}

update_kimi_cli() {
  local pin age method=""
  pin="$(aicm_policy_pin kimi)"
  age="$(aicm_policy_effective_age kimi "$MIN_RELEASE_AGE_DAYS")"
  # The copy on PATH decides the route. A standalone Kimi must never let a hidden npm copy take the
  # policy pin (the terminal would still run the standalone one).
  if active_install kimi && [[ "$CLI_INSTALLED" == true ]]; then method="$CLI_METHOD"; fi
  if [[ -n "$method" && "$method" != npm ]]; then
    policy_hold_for_route kimi "$method" && return 0
    echo "kimi command exists but is not npm-managed; skipping unattended update"
    echo "      reinstall/update with npm for automation: npm install -g @moonshot-ai/kimi-code@latest"
    return 0
  fi
  if is_npm_global_installed "@moonshot-ai/kimi-code"; then
    update_npm_package "@moonshot-ai/kimi-code" "$pin" "$age" kimi
  elif command -v kimi >/dev/null 2>&1; then
    policy_hold_for_route kimi standalone && return 0
    echo "kimi command exists but is not npm-managed; skipping unattended update"
    echo "      reinstall/update with npm for automation: npm install -g @moonshot-ai/kimi-code@latest"
  elif [[ "$INSTALL_MISSING" == "true" ]]; then
    install_npm_package "@moonshot-ai/kimi-code" "$pin" "$age" kimi
  else
    pass_missing kimi "command not found and npm global package not installed"
  fi
}

echo "[$(ts)] AI CLI update started"
echo "host=$(hostname) user=$(id -un) dry_run=$DRY_RUN targets=$AI_CLI_TARGETS install_missing=$INSTALL_MISSING min_release_age_days=$MIN_RELEASE_AGE_DAYS"
cleanup_old_logs
[[ "$DRY_RUN" != true ]] && restore_missing_npm
collect_catalog_extras
build_verify_rows
report_update_policy

echo
echo "== before versions =="
capture_versions before

if command -v "$BREW" >/dev/null 2>&1; then
  if { gpt_target_enabled && ! aicm_policy_excluded codex && policy_brew_update_allowed codex && active_brew_install codex codex; } || { target_enabled opencode && ! aicm_policy_excluded opencode && policy_brew_update_allowed opencode && active_brew_install opencode opencode; } || { target_enabled claude && ! aicm_policy_excluded claude && policy_brew_update_allowed claude && active_brew_install claude claude-code; }; then
    run_step "brew update" aicm_timeout "$INSTALL_TIMEOUT_SECONDS" "$BREW" update
  else
    echo "pass: no target Homebrew-managed CLIs installed; skipping brew update"
  fi
else
  echo "pass: brew not installed; skipping brew-managed CLIs"
fi

# Codex: prefer Homebrew when it manages the active install.
if gpt_target_enabled; then
  fail_mark=${#failures[@]}
  if aicm_policy_excluded codex; then
    echo "skip: codex excluded by update policy"
  else
    codex_pin="$(aicm_policy_pin codex)"
    codex_age="$(aicm_policy_effective_age codex "$MIN_RELEASE_AGE_DAYS")"
    if active_brew_install codex codex; then
      policy_hold_for_route codex brew || run_step "gpt/codex via brew" update_brew_package codex
    elif active_install codex && [[ "$CLI_INSTALLED" == true && "$CLI_METHOD" == npm ]]; then
      run_step "gpt/codex via npm" update_npm_package "@openai/codex" "$codex_pin" "$codex_age" codex
    elif active_install codex && [[ "$CLI_INSTALLED" == true ]] && aicm_codex_standalone "$CLI_PATH"; then
      # The official installer (~/.codex/packages/standalone) updates itself; the desktop app's copy does not live there.
      policy_hold_for_route codex standalone || run_step "gpt/codex standalone" update_codex_standalone "$CLI_PATH" "$codex_age"
    elif [[ "$INSTALL_MISSING" == "true" ]] && active_install codex && [[ "$CLI_INSTALLED" != true ]]; then
      run_step "gpt/codex via npm install" install_npm_package "@openai/codex" "$codex_pin" "$codex_age" codex
    else
      pass_missing gpt "codex command not found and no brew/npm package"
    fi

    # The Codex desktop app can put its own copy on PATH and updates it itself; say so when npm's copy is hidden.
    shadow_warning codex

    # A quarantined cask build cannot start its code-mode host while Gatekeeper's first-open prompt waits
    # (lib/codex-host.sh). Checked on every run, so a version installed by hand is fixed too. It runs
    # before the recycle below, so the restarted servers find a host that starts.
    if policy_codex_local_fix_allowed && [[ "${AICM_CODEX_UNQUARANTINE:-1}" != 0 ]] && [[ "$(uname -s)" == Darwin ]] && active_brew_install codex codex && is_brew_cask_installed codex; then
      run_step "codex cask quarantine" release_codex_cask_quarantine
    fi

    # A Homebrew upgrade deletes the old cask folder that a running `codex app-server` (Paseo keeps one)
    # still spawns its terminal host from (lib/codex-host.sh). Right after the upgrade: a later update
    # can hang.
    if policy_codex_local_fix_allowed && [[ "${AICM_CODEX_RECYCLE:-1}" != 0 ]] && active_brew_install codex codex; then
      run_step "stale codex app-servers" recycle_stale_codex_app_servers
    fi
  fi
  take_target_failures codex "$fail_mark"
fi

if target_enabled opencode; then
  fail_mark=${#failures[@]}
  if aicm_policy_excluded opencode; then echo "skip: opencode excluded by update policy"; else run_step "opencode" update_opencode_cli; fi
  take_target_failures opencode "$fail_mark"
fi

if target_enabled agy; then
  fail_mark=${#failures[@]}
  if aicm_policy_excluded agy; then
    echo "skip: agy excluded by update policy"
  elif command -v agy >/dev/null 2>&1; then
    policy_hold_for_route agy standalone || run_step "antigravity cli via agy" update_agy_cli
  else
    pass_missing agy "command not found"
  fi
  take_target_failures agy "$fail_mark"
fi

if target_enabled kimi; then
  fail_mark=${#failures[@]}
  if aicm_policy_excluded kimi; then echo "skip: kimi excluded by update policy"; else run_step "kimi code via npm" update_kimi_cli; fi
  take_target_failures kimi "$fail_mark"
fi

if target_enabled claude; then
  fail_mark=${#failures[@]}
  if aicm_policy_excluded claude; then echo "skip: claude excluded by update policy"; else run_step "claude code" update_claude_cli; fi
  take_target_failures claude "$fail_mark"
fi

if target_enabled grok; then
  fail_mark=${#failures[@]}
  if aicm_policy_excluded grok; then echo "skip: grok excluded by update policy"; else run_step "grok build" update_grok_cli; fi
  take_target_failures grok "$fail_mark"
fi

for idx in ${EXTRA_IDX[@]+"${EXTRA_IDX[@]}"}; do
  fail_mark=${#failures[@]}
  if aicm_policy_excluded "${AICM_CLI_ID[$idx]}"; then
    echo "skip: ${AICM_CLI_ID[$idx]} excluded by update policy"
  else
    update_catalog_extra "$idx"
  fi
  take_target_failures "${AICM_CLI_ID[$idx]}" "$fail_mark"
done

echo
echo "== after versions =="
hash -r || true
capture_versions after
classify_results

# Optional user hook. A broken or missing after probe never runs it.
POST_UPDATE_HOOK="$AICM_HOME/hooks/post-update.sh"
if [[ -x "$POST_UPDATE_HOOK" ]]; then
  if version_changed; then AI_CLI_MANAGER_SESSION="" run_optional_step "post-update hook" "$POST_UPDATE_HOOK"
  else echo; echo "post-update hook skipped: no CLI version changed"; fi
fi

echo
echo "log_file=$LOG_FILE"

failure_summary=""
if ((${#failures[@]})); then
  failure_summary="${failures[*]}"
fi
if ((${#version_failures[@]})); then
  failure_summary="${failure_summary:+$failure_summary }${version_failures[*]}"
fi

problems=()
schedule_problem_text="$(aicm_schedule_problems update)" || true
while IFS= read -r problem; do [[ -n "$problem" ]] && problems+=("$problem"); done <<< "$schedule_problem_text"
if ((${#problems[@]})); then
  for problem in "${problems[@]}"; do echo "problem: $problem"; done
fi
# MCP servers, browsers and agent CLIs left running after their session ended (lib/processes.js).
if [[ "${AICM_PROCESSES:-1}" != 0 && "$DRY_RUN" != "true" ]]; then
  echo
  echo "== processes left behind by agent sessions =="
  aicm_node_module processes
  if ((${#AICM_NODE_ATTENTION[@]})); then problems+=("${AICM_NODE_ATTENTION[@]}"); fi
fi

if [[ "$DRY_RUN" != "true" ]]; then
  update_ok=true; [[ -z "$failure_summary" ]] || update_ok=false
  note_deferred_since
  # npm CLIs looked after: the next run reports one that disappears (see restore_missing_npm).
  save_npm_state
  aicm_npm_leftovers
  aicm_update_app_copy
  aicm_state_write last-update "{\"finishedAt\":\"$(ts)\",\"localDate\":\"$(date +%Y-%m-%d)\",\"targets\":\"$(aicm_json_escape "$(run_targets)")\",\"policyFingerprint\":\"$(aicm_json_escape "$AICM_POLICY_FINGERPRINT")\",\"version\":\"$(aicm_version)\",\"ok\":$update_ok,\"pending\":$PENDING,\"failures\":\"$(aicm_json_escape "$failure_summary")\",\"logFile\":\"$(aicm_json_escape "$LOG_FILE")\",\"results\":$(verify_results_json)}"
  record_update_history
  notes=()
  # The step name without its exit code, so the same failure keeps the same key from day to day.
  if ((${#failures[@]})); then for f in "${failures[@]}"; do notes+=("update failed: ${f% rc=*}"); done; fi
  if ((${#version_failures[@]})); then for f in "${version_failures[@]}"; do notes+=("update failed: $f"); done; fi
  if ((${#problems[@]})); then notes+=("${problems[@]}"); fi
  if ((${#AICM_NPM_NOTES[@]})); then notes+=("${AICM_NPM_NOTES[@]}"); fi
  aicm_attention update ${notes[@]+"${notes[@]}"}
fi

if [[ -n "$failure_summary" ]]; then
  echo "[$(ts)] AI CLI update finished with failures: $failure_summary"
  exit 1
fi

echo "[$(ts)] AI CLI update finished successfully"
