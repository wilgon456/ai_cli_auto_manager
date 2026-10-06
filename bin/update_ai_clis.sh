#!/usr/bin/env bash
set -Eeuo pipefail

# Auto-update local AI coding CLIs.
# Targets:
#   - GPT/Codex CLI: Homebrew cask/formula when present; npm global only if it is the active command
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

LOCK_DIR="${LOCK_DIR:-/tmp/ai-cli-auto-manager-update.lockdir}"
LOG_DIR="${LOG_DIR:-$AICM_HOME/logs}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
BREW="${BREW:-$(command -v brew 2>/dev/null || echo /usr/local/bin/brew)}"
NPM="${NPM:-$(command -v npm 2>/dev/null || echo /usr/local/bin/npm)}"
AI_CLI_TARGETS="${AI_CLI_TARGETS:-all}"
INSTALL_MISSING="${INSTALL_MISSING:-false}"
PATH="/usr/local/bin:/opt/homebrew/bin:${HOME:-}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
DRY_RUN=false
VERSION_TIMEOUT_SECONDS="${VERSION_TIMEOUT_SECONDS:-10}"
if [[ ! "$VERSION_TIMEOUT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || [[ "$VERSION_TIMEOUT_SECONDS" == 0 || "$VERSION_TIMEOUT_SECONDS" == 0.0 ]]; then
  VERSION_TIMEOUT_SECONDS=10
fi
while (($#)); do
  case "$1" in
    --dry-run|--check) DRY_RUN=true ;;
    --install-missing) INSTALL_MISSING=true ;;
    --targets)
      shift
      [[ "${1:-}" ]] || { echo "missing value for --targets" >&2; exit 2; }
      AI_CLI_TARGETS="$1"
      ;;
    --targets=*) AI_CLI_TARGETS="${1#--targets=}" ;;
    -h|--help)
      echo "Usage: $0 [--dry-run|--check] [--targets all|id,id (see rules/ai-clis.conf)] [--install-missing]"
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

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/update-$(date +%Y%m%d-%H%M%S).log"
LATEST_LOG="$LOG_DIR/latest.log"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [[ -f "$LOCK_DIR/pid" ]] && kill -0 "$(cat "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then
    echo "[$(ts)] another update run is already active" | tee -a "$LOG_FILE"
    exit 0
  fi
  echo "[$(ts)] removing stale lock: $LOCK_DIR" | tee -a "$LOG_FILE"
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "[$(ts)] another update run is already active" | tee -a "$LOG_FILE"
    exit 0
  fi
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"
trap 'rm -f "$LOCK_DIR/pid" 2>/dev/null || true; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

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
    outdated="$("$BREW" outdated --cask "$name" 2>&1)"
    rc=$?
    if ((rc != 0)) && [[ "$outdated" != *"$name"* ]]; then
      echo "$outdated"
      return "$rc"
    fi
    if [[ -n "$outdated" ]]; then
      "$BREW" upgrade --cask "$name"
    else
      echo "brew cask already up-to-date: $name"
    fi
  elif is_brew_formula_installed "$name"; then
    outdated="$("$BREW" outdated --formula "$name" 2>&1)"
    rc=$?
    if ((rc != 0)) && [[ "$outdated" != *"$name"* ]]; then
      echo "$outdated"
      return "$rc"
    fi
    if [[ -n "$outdated" ]]; then
      "$BREW" upgrade --formula "$name"
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

update_npm_package() {
  local pkg="$1" installed latest
  if is_npm_global_installed "$pkg"; then
    installed="$(npm_installed_version "$pkg")"
    latest="$("$NPM" view "$pkg" version 2>/dev/null || true)"
    if [[ -n "$installed" && "$installed" == "$latest" ]]; then
      echo "already current: $pkg $installed"
      return 0
    fi
    "$NPM" install -g "$pkg@latest"
  else
    echo "npm global package not installed: $pkg"
  fi
}

install_npm_package() {
  local pkg="$1"
  command -v "$NPM" >/dev/null 2>&1 || { echo "npm is not installed"; return 1; }
  "$NPM" install -g "$pkg@latest"
}

update_agy_cli() {
  if command -v agy >/dev/null 2>&1; then
    command_with_timeout 300 agy update
  else
    echo "agy command not installed"
  fi
}

update_claude_cli() {
  if is_brew_cask_installed claude-code || is_brew_formula_installed claude-code; then
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
  if is_brew_cask_installed opencode || is_brew_formula_installed opencode; then
    update_brew_package opencode
  elif is_npm_global_installed "opencode-ai"; then
    update_npm_package "opencode-ai"
  elif command -v opencode >/dev/null 2>&1; then
    command_with_timeout 300 opencode upgrade
  elif [[ "$INSTALL_MISSING" == "true" ]]; then
    install_npm_package "opencode-ai"
  else
    pass_missing opencode "command not found and no supported package manager install detected"
  fi
}

install_or_update_grok_cli() {
  command -v curl >/dev/null 2>&1 || { echo "curl is not installed"; return 1; }
  command_with_timeout 300 bash -c 'curl -fsSL https://x.ai/cli/install.sh | bash'
}

update_grok_cli() {
  if command -v grok >/dev/null 2>&1 && active_path_contains grok "/node_modules/" && is_npm_global_installed "@xai-official/grok"; then
    update_npm_package "@xai-official/grok"
  elif command -v grok >/dev/null 2>&1; then
    install_or_update_grok_cli
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
echo "host=$(hostname) user=$(id -un) dry_run=$DRY_RUN targets=$AI_CLI_TARGETS install_missing=$INSTALL_MISSING"
cleanup_old_logs
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
    run_step "brew update" "$BREW" update
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

# Optional user hook, e.g. reload a daemon that keeps old CLI binaries loaded. Failure is only a warning.
POST_UPDATE_HOOK="$AICM_HOME/hooks/post-update.sh"
if [[ -x "$POST_UPDATE_HOOK" ]]; then
  run_optional_step "post-update hook" "$POST_UPDATE_HOOK"
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

if [[ "$DRY_RUN" != "true" ]]; then
  update_ok=true; [[ -z "$failure_summary" ]] || update_ok=false
  aicm_state_write last-update "{\"finishedAt\":\"$(ts)\",\"version\":\"$(aicm_version)\",\"ok\":$update_ok,\"failures\":\"$(aicm_json_escape "$failure_summary")\",\"logFile\":\"$(aicm_json_escape "$LOG_FILE")\"}"
  attention="${failure_summary:+update failed: $failure_summary}"
  if ((${#problems[@]})); then
    attention="${attention:+$attention; }$(printf '%s; ' "${problems[@]}")"
    attention="${attention%; }"
  fi
  [[ -z "$attention" ]] || aicm_notify "AI CLI Auto Manager" "$attention"
fi

if [[ -n "$failure_summary" ]]; then
  echo "[$(ts)] AI CLI update finished with failures: $failure_summary"
  exit 1
fi

echo "[$(ts)] AI CLI update finished successfully"
