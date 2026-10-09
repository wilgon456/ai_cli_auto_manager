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
VERSION_TEXT=""
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
  local file="$AICM_HOME/state/last-update.json" state day covered want t
  [[ -f "$file" ]] || return 1
  state="$(cat "$file")"
  [[ "$state" == *'"ok":true'* && "$state" != *'"pending":true'* ]] || return 1
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

version_of() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '%s: ' "$cmd"
    local version_output version_rc first_line
    version_rc=0
    version_output="$(command_with_timeout "$VERSION_TIMEOUT_SECONDS" "$cmd" --version 2>&1)" || version_rc=$?
    first_line="${version_output%%$'\n'*}"
    VERSION_TEXT+="$cmd=$first_line;"
    if ((version_rc == 124)); then
      echo "TIMEOUT after ${VERSION_TIMEOUT_SECONDS}s"
      echo "warn: $cmd --version timed out; continuing updater"
      record_version_failure "$cmd version timeout"
    elif ((version_rc != 0)); then
      echo "ERROR rc=$version_rc${first_line:+: $first_line}"
      echo "warn: $cmd --version failed rc=$version_rc; continuing updater"
      record_version_failure "$cmd version rc=$version_rc"
    else
      echo "${first_line:-unknown}"
    fi
    printf '  path: '
    command -v "$cmd" || true
  else
    echo "$cmd: not installed"
  fi
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

active_path_contains() {
  local cmd="$1" needle="$2"
  local p
  p="$(command -v "$cmd" 2>/dev/null || true)"
  [[ "$p" == *"$needle"* ]]
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

update_npm_package() {
  local pkg="$1" installed target before
  if ! registry_ok; then PENDING=true; return 0; fi
  if is_npm_global_installed "$pkg"; then
    remember_npm "$pkg"
    installed="$(npm_installed_version "$pkg")"
    target="$(aicm_npm_target "$pkg" "$MIN_RELEASE_AGE_DAYS" "$installed" skip-deprecated)" || { echo "could not read the release list of $pkg"; return 1; }
    if [[ -z "$target" ]]; then
      echo "hold: no release of $pkg is $MIN_RELEASE_AGE_DAYS days old yet"
      return 0
    fi
    if [[ -n "$installed" ]] && ! aicm_version_older "$installed" "$target"; then
      echo "already current: $pkg $installed (newest release at least $MIN_RELEASE_AGE_DAYS days old: $target)"
      return 0
    fi
    echo "candidate: $pkg $installed -> $target"
    aicm_npm_check "$pkg" "$installed" "$target" "$MIN_RELEASE_AGE_DAYS" || return 1
    before="$(aicm_npm_before "$MIN_RELEASE_AGE_DAYS")"
    npm_global_install "$pkg@$target" ${before:+"$before"}
  else
    echo "npm global package not installed: $pkg"
  fi
}

install_npm_package() {
  local pkg="$1" target before
  command -v "$NPM" >/dev/null 2>&1 || { echo "npm is not installed"; return 1; }
  remember_npm "$pkg"
  target="$(aicm_npm_target "$pkg" "$MIN_RELEASE_AGE_DAYS" "" skip-deprecated)" || { echo "could not read the release list of $pkg"; return 1; }
  [[ -n "$target" ]] || { echo "hold: no release of $pkg is $MIN_RELEASE_AGE_DAYS days old yet"; return 0; }
  aicm_npm_check "$pkg" "" "$target" "$MIN_RELEASE_AGE_DAYS" || return 1
  before="$(aicm_npm_before "$MIN_RELEASE_AGE_DAYS")"
  npm_global_install "$pkg@$target" ${before:+"$before"}
}

# npm CLIs this updater managed before. One that is gone now was either removed on purpose or lost to
# an interrupted install (npm moved it to a backup folder .<name>-XXXXXXXX and never finished). With
# such a backup it is reinstalled at the same version; otherwise it is reported once and forgotten,
# so an intentional uninstall is not fought every day.
restore_missing_npm() {
  local pkg version backup
  [[ -f "$NPM_STATE" ]] && command -v "$NPM" >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r pkg version; do
    [[ -n "$pkg" ]] || continue
    if [[ -n "$(aicm_npm_pkg_version "$pkg")" ]]; then KNOWN_NPM+="$pkg"$'\t'"$version"$'\n'; continue; fi
    echo
    echo "== missing npm CLI: $pkg =="
    if ! backup="$(aicm_npm_backup "$pkg")"; then
      echo "fail: $pkg ($version) was installed at the last update and is gone now"
      failures+=("$pkg disappeared since the last update; reinstall it with 'npm install -g $pkg@$version', or ignore this if you removed it rc=1")
      continue
    fi
    echo "found npm's backup of an interrupted install: $backup"
    KNOWN_NPM+="$pkg"$'\t'"$version"$'\n'
    if ! registry_ok; then PENDING=true; continue; fi
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

shadow_warning() {
  active_install "$1" || return 0
  if [[ -n "$CLI_NPMCOPY" && "$CLI_METHOD" != npm ]]; then
    echo "warn: PATH runs $CLI_PATH; the npm copy $CLI_NPMCOPY is a second install that the terminal does not use."
    echo "      $(aicm_shadow_fix "$CLI_PATH")"
  fi
  return 0
}

update_claude_cli() {
  if active_install claude && [[ "$CLI_INSTALLED" == true && "$CLI_METHOD" == standalone ]]; then
    command_with_timeout 300 "$CLI_PATH" update || return $?
    shadow_warning claude
  elif is_brew_cask_installed claude-code || is_brew_formula_installed claude-code; then
    update_brew_package claude-code
  elif is_npm_global_installed "@anthropic-ai/claude-code"; then
    update_npm_package "@anthropic-ai/claude-code"
  elif command -v claude >/dev/null 2>&1; then
    command_with_timeout 300 claude update
  elif [[ "$INSTALL_MISSING" == "true" ]]; then
    install_npm_package "@anthropic-ai/claude-code"
  else
    pass_missing claude "command not found and no supported package manager install detected"
  fi
}

update_opencode_cli() {
  if active_install opencode && [[ "$CLI_INSTALLED" == true && "$CLI_METHOD" == standalone ]]; then
    command_with_timeout 300 "$CLI_PATH" upgrade || return $?
    shadow_warning opencode
  elif is_brew_cask_installed opencode || is_brew_formula_installed opencode; then
    update_brew_package opencode
  elif is_npm_global_installed "@opencode/cli"; then
    # OpenCode 2.x is published as @opencode/cli; opencode-ai is the 1.x line.
    update_npm_package "@opencode/cli"
  elif is_npm_global_installed "opencode-ai"; then
    update_npm_package "opencode-ai"
  elif command -v opencode >/dev/null 2>&1; then
    command_with_timeout 300 opencode upgrade
  elif [[ "$INSTALL_MISSING" == "true" ]]; then
    install_npm_package "@opencode/cli"
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
installer_update_due() { # name command npm-package
  local name="$1" cmd="$2" pkg="$3" have want newest
  have="$(aicm_timeout 15 "$cmd" --version 2>&1 | aicm_semver || true)"
  if [[ -z "$have" ]]; then
    echo "skip: cannot read the installed $name version, so the installer is not run unattended; update it by hand"
    return 1
  fi
  if ! command -v "$NPM" >/dev/null 2>&1; then
    echo "skip: npm is needed to look up $name release dates; the installer is not run unattended. Update $name by hand"
    return 1
  fi
  if ! registry_ok; then PENDING=true; return 1; fi
  want="$(aicm_npm_target "$pkg" "$MIN_RELEASE_AGE_DAYS" || true)"
  if [[ -z "$want" ]] || ! aicm_version_older "$have" "$want"; then
    echo "already current: $name $have (newest release at least $MIN_RELEASE_AGE_DAYS days old: $want)"
    return 1
  fi
  if ((MIN_RELEASE_AGE_DAYS > 0)); then
    newest="$(AICM_NPM_TIMEOUT=60 aicm_npm view "$pkg" version 2>/dev/null | aicm_semver || true)"
    if [[ -n "$newest" && "$newest" != "$want" ]]; then
      echo "hold: $name $want is old enough, but the installer would install $newest, which is still in its $MIN_RELEASE_AGE_DAYS-day waiting period"
      return 1
    fi
  fi
  echo "candidate: $name $have -> $want"
}

# `codex update` reruns the official installer, so it is gated like the Grok installer.
update_codex_standalone() { # codex path
  installer_update_due codex "$1" "@openai/codex" || return 0
  command_with_timeout 300 "$1" update
}

update_grok_cli() {
  if command -v grok >/dev/null 2>&1 && active_path_contains grok "/node_modules/" && is_npm_global_installed "@xai-official/grok"; then
    update_npm_package "@xai-official/grok"
  elif command -v grok >/dev/null 2>&1; then
    installer_update_due grok grok "@xai-official/grok" || return 0
    install_or_update_grok_cli || return $?
    shadow_warning grok
  elif [[ "$INSTALL_MISSING" == "true" ]]; then
    install_or_update_grok_cli
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
    [[ -n "${AICM_CLI_CMD[$i]}" ]] || continue
    aicm_cli_install "$i"
    if [[ "$CLI_INSTALLED" == true ]] || { [[ "$INSTALL_MISSING" == true && -n "${AICM_CLI_NPM[$i]}" ]] && target_named "$id"; }; then
      EXTRA_IDX+=("$i")
    fi
  done
}

update_catalog_extra() {
  local i="$1" name self_args
  name="${AICM_CLI_NAME[$i]}"
  aicm_cli_install "$i"
  if [[ "$CLI_INSTALLED" != true ]]; then
    run_step "$name via npm install" install_npm_package "${AICM_CLI_NPM[$i]}"
    return 0
  fi
  case "$CLI_METHOD" in
    npm) run_step "$name via npm" update_npm_package "${AICM_CLI_NPM[$i]}" ;;
    brew)
      if [[ -n "${AICM_CLI_BREW[$i]}" ]]; then run_step "$name via brew" update_brew_package "${AICM_CLI_BREW[$i]}"
      else pass_missing "${AICM_CLI_ID[$i]}" "installed with Homebrew but the catalog has no Homebrew name"; fi ;;
    *)
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
  if is_npm_global_installed "@moonshot-ai/kimi-code"; then
    update_npm_package "@moonshot-ai/kimi-code"
  elif command -v kimi >/dev/null 2>&1; then
    echo "kimi command exists but is not npm-managed; skipping unattended update"
    echo "      reinstall/update with npm for automation: npm install -g @moonshot-ai/kimi-code@latest"
  elif [[ "$INSTALL_MISSING" == "true" ]]; then
    install_npm_package "@moonshot-ai/kimi-code"
  else
    pass_missing kimi "command not found and npm global package not installed"
  fi
}

echo "[$(ts)] AI CLI update started"
echo "host=$(hostname) user=$(id -un) dry_run=$DRY_RUN targets=$AI_CLI_TARGETS install_missing=$INSTALL_MISSING min_release_age_days=$MIN_RELEASE_AGE_DAYS"
cleanup_old_logs
[[ "$DRY_RUN" != true ]] && restore_missing_npm
collect_catalog_extras

echo
echo "== before versions =="
gpt_target_enabled && version_of codex
target_enabled opencode && version_of opencode
target_enabled agy && version_of agy
target_enabled kimi && version_of kimi
target_enabled claude && version_of claude
target_enabled grok && version_of grok
for idx in ${EXTRA_IDX[@]+"${EXTRA_IDX[@]}"}; do version_of "${AICM_CLI_CMD[$idx]}"; done

if command -v "$BREW" >/dev/null 2>&1; then
  if { gpt_target_enabled && { is_brew_cask_installed codex || is_brew_formula_installed codex; }; } || { target_enabled opencode && { is_brew_cask_installed opencode || is_brew_formula_installed opencode; }; } || { target_enabled claude && { is_brew_cask_installed claude-code || is_brew_formula_installed claude-code; }; }; then
    run_step "brew update" aicm_timeout "$INSTALL_TIMEOUT_SECONDS" "$BREW" update
  else
    echo "pass: no target Homebrew-managed CLIs installed; skipping brew update"
  fi
else
  echo "pass: brew not installed; skipping brew-managed CLIs"
fi

# Codex: prefer Homebrew when it manages the active install.
if gpt_target_enabled; then
  if is_brew_cask_installed codex || is_brew_formula_installed codex; then
    run_step "gpt/codex via brew" update_brew_package codex
  elif active_path_contains codex "/node_modules/" || is_npm_global_installed "@openai/codex"; then
    run_step "gpt/codex via npm" update_npm_package "@openai/codex"
  elif active_install codex && [[ "$CLI_INSTALLED" == true ]] && aicm_codex_standalone "$CLI_PATH"; then
    # The official installer (~/.codex/packages/standalone) updates itself; the desktop app's copy does not live there.
    run_step "gpt/codex standalone" update_codex_standalone "$CLI_PATH"
  elif [[ "$INSTALL_MISSING" == "true" ]]; then
    run_step "gpt/codex via npm install" install_npm_package "@openai/codex"
  else
    pass_missing gpt "codex command not found and no brew/npm package"
  fi

  # Keep a stale npm Codex install current only if it exists AND is not shadowing brew unexpectedly.
  # This prevents future PATH flips from resurrecting an old Codex binary.
  if is_npm_global_installed "@openai/codex"; then
    if is_npm_global_package_writable "@openai/codex"; then
      run_optional_step "codex npm shadow copy" update_npm_package "@openai/codex"
    else
      echo "pass: codex npm shadow copy is installed but inactive/not writable; skipping optional stale shadow update"
      echo "      path: $(npm_global_package_path "@openai/codex" 2>/dev/null || echo "@openai/codex")"
    fi
  fi
  # The Codex desktop app can put its own copy on PATH and updates it itself; say so when npm's copy is hidden.
  shadow_warning codex

  # A quarantined cask build cannot start its code-mode host when Gatekeeper's online check stalls
  # (lib/codex-host.sh). Checked on every run, so a version installed by hand is fixed too. It runs
  # before the recycle below, so the restarted servers find a host that starts.
  if [[ "${AICM_CODEX_UNQUARANTINE:-1}" != 0 ]] && [[ "$(uname -s)" == Darwin ]] && is_brew_cask_installed codex; then
    run_step "codex cask quarantine" release_codex_cask_quarantine
  fi

  # A Homebrew upgrade deletes the old cask folder that a running `codex app-server` (Paseo keeps one)
  # still spawns its terminal host from (lib/codex-host.sh). Right after the upgrade: a later update
  # can hang.
  if [[ "${AICM_CODEX_RECYCLE:-1}" != 0 ]] && { is_brew_cask_installed codex || is_brew_formula_installed codex; }; then
    run_step "stale codex app-servers" recycle_stale_codex_app_servers
  fi
fi

if target_enabled opencode; then
  run_step "opencode" update_opencode_cli
fi

if target_enabled agy; then
  if command -v agy >/dev/null 2>&1; then
    run_step "antigravity cli via agy" update_agy_cli
  else
    pass_missing agy "command not found"
  fi
fi

if target_enabled kimi; then
  run_step "kimi code via npm" update_kimi_cli
fi

if target_enabled claude; then
  run_step "claude code" update_claude_cli
fi

if target_enabled grok; then
  run_step "grok build" update_grok_cli
fi

for idx in ${EXTRA_IDX[@]+"${EXTRA_IDX[@]}"}; do
  update_catalog_extra "$idx"
done

versions_before="$VERSION_TEXT"
VERSION_TEXT=""
echo
echo "== after versions =="
hash -r || true
gpt_target_enabled && version_of codex
target_enabled opencode && version_of opencode
target_enabled agy && version_of agy
target_enabled kimi && version_of kimi
target_enabled claude && version_of claude
target_enabled grok && version_of grok
for idx in ${EXTRA_IDX[@]+"${EXTRA_IDX[@]}"}; do version_of "${AICM_CLI_CMD[$idx]}"; done

# Optional user hook, e.g. reload a daemon that keeps old CLI binaries loaded. Runs only when a CLI
# version actually changed (the job retries during the day). Failure is only a warning.
POST_UPDATE_HOOK="$AICM_HOME/hooks/post-update.sh"
if [[ -x "$POST_UPDATE_HOOK" ]]; then
  if [[ "$versions_before" != "$VERSION_TEXT" ]]; then run_optional_step "post-update hook" "$POST_UPDATE_HOOK"
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
while IFS= read -r problem; do [[ -n "$problem" ]] && problems+=("$problem"); done < <(aicm_schedule_problems update)
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
  # npm CLIs looked after: the next run reports one that disappears (see restore_missing_npm).
  save_npm_state
  aicm_npm_leftovers
  aicm_update_app_copy
  aicm_state_write last-update "{\"finishedAt\":\"$(ts)\",\"localDate\":\"$(date +%Y-%m-%d)\",\"targets\":\"$(aicm_json_escape "$(run_targets)")\",\"version\":\"$(aicm_version)\",\"ok\":$update_ok,\"pending\":$PENDING,\"failures\":\"$(aicm_json_escape "$failure_summary")\",\"logFile\":\"$(aicm_json_escape "$LOG_FILE")\"}"
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
