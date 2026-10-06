#!/usr/bin/env bash
# shellcheck disable=SC2034 # the rule arrays and AICM_PROTECT_ARGS are read by the scripts that source this file
# Shared helpers for AI CLI Auto Manager on macOS and Linux.
# Source this file; it defines functions and variables only.
# Must keep working on the bash 3.2 that ships with macOS (no associative arrays, no mapfile, no ${x,,}).

AICM_ROOT="${AICM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AICM_HOME="${AICM_HOME:-${HOME:-/tmp}/.ai-cli-auto-manager}"

aicm_version() {
  if [[ -f "$AICM_ROOT/VERSION" ]]; then
    head -n 1 "$AICM_ROOT/VERSION" | tr -d '[:space:]'
  else
    echo unknown
  fi
}

aicm_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# mac | linux. AICM_OS overrides detection (used by tests).
aicm_os() {
  if [[ -n "${AICM_OS:-}" ]]; then
    echo "$AICM_OS"
    return
  fi
  case "$(uname -s)" in
    Darwin) echo mac ;;
    *) echo linux ;;
  esac
}

aicm_os_matches() {
  local rule_os="$1" os
  os="$(aicm_os)"
  case "$rule_os" in
    all|unix) return 0 ;;
    "$os") return 0 ;;
    *) return 1 ;;
  esac
}

aicm_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

aicm_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

aicm_temp_dir() {
  local t="${TMPDIR:-/tmp}"
  t="${t%/}"
  printf '%s' "${t:-/tmp}"
}

aicm_cache_dir() {
  if [[ "$(aicm_os)" == mac ]]; then
    printf '%s' "$HOME/Library/Caches"
  else
    printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}"
  fi
}

aicm_expand_path() {
  local p="$1"
  # shellcheck disable=SC2088 # the rules file holds a literal ~
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  p="${p//\{temp\}/$(aicm_temp_dir)}"
  p="${p//\{cache\}/$(aicm_cache_dir)}"
  p="${p//\{localappdata\}/$(aicm_cache_dir)}"
  while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
  [[ "$p" != / ]] && p="${p%/}"
  printf '%s' "$p"
}

# A rule may only touch the home folder (never the home folder itself) or the temp folder.
aicm_path_allowed() {
  local p="$1" home temp
  home="${HOME%/}"
  temp="$(aicm_temp_dir)"
  case "/$p/" in
    */../*|*/./*) return 1 ;;
  esac
  [[ "$p" == "$home" ]] && return 1
  [[ "$p" == "$temp" || "$p" == "$temp/"* ]] && return 0
  [[ "$p" == "$home/"* ]] && return 0
  return 1
}

aicm_display_path() {
  local p="$1"
  if [[ "$p" == "$HOME/"* ]]; then
    # shellcheck disable=SC2088 # a literal ~ is the intended display
    printf '~/%s' "${p#"$HOME"/}"
  else
    printf '%s' "$p"
  fi
}

aicm_format_size() {
  awk -v b="${1:-0}" 'BEGIN { if (b >= 1073741824) printf "%.1f GB", b/1073741824; else printf "%.1f MB", b/1048576 }'
}

# Prints byte sizes of NUL-separated paths read from stdin, one per line.
aicm_sizes_stdin() {
  if stat -c %s / >/dev/null 2>&1; then
    xargs -0 stat -c %s 2>/dev/null || true
  else
    xargs -0 stat -f %z 2>/dev/null || true
  fi
}

aicm_sum_lines() { awk '{ s += $1 } END { printf "%d", s }'; }

# Rules: parallel arrays filled by aicm_load_rules (bash 3.2 has no associative arrays).
AICM_RULE_ID=(); AICM_RULE_KIND=(); AICM_RULE_PATH=(); AICM_RULE_PATTERN=()
AICM_RULE_DAYS=(); AICM_RULE_LIMIT=(); AICM_RULE_ENABLED=(); AICM_RULE_NOTE=()

aicm_rule_index() {
  local id="$1" i
  for ((i = 0; i < ${#AICM_RULE_ID[@]}; i++)); do
    if [[ "${AICM_RULE_ID[$i]}" == "$id" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

aicm_load_rule_file() {
  local file="$1" line id os kind path pattern days limit default note rest idx source
  source="$(basename "$file")"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$(aicm_trim "$line")" ]] && continue
    [[ "$(aicm_trim "$line")" == \#* ]] && continue
    IFS='|' read -r id os kind path pattern days limit default note rest <<< "$line"
    id="$(aicm_trim "$id")"; os="$(aicm_lower "$(aicm_trim "$os")")"; kind="$(aicm_lower "$(aicm_trim "$kind")")"
    path="$(aicm_trim "$path")"; pattern="$(aicm_trim "$pattern")"; days="$(aicm_trim "$days")"
    limit="$(aicm_trim "$limit")"; default="$(aicm_lower "$(aicm_trim "$default")")"; note="$(aicm_trim "$note")"
    case "$kind" in age|cap|keep-latest|command) ;; *) echo "invalid rule kind '$kind' in $source: $line" >&2; return 1 ;; esac
    case "$default" in on|off) ;; *) echo "invalid default '$default' in $source: $line" >&2; return 1 ;; esac
    [[ -z "$days" || "$days" =~ ^[0-9]+$ ]] || { echo "invalid days in $source: $line" >&2; return 1; }
    [[ -z "$limit" || "$limit" =~ ^[0-9]+$ ]] || { echo "invalid limit in $source: $line" >&2; return 1; }
    if [[ "$kind" == age ]] && (( ${days:-0} < 1 )); then echo "age rule needs days >= 1 in $source: $line" >&2; return 1; fi
    if [[ "$kind" == keep-latest ]] && (( ${limit:-0} < 1 )); then echo "keep-latest rule needs limit >= 1 in $source: $line" >&2; return 1; fi
    aicm_os_matches "$os" || continue
    if idx="$(aicm_rule_index "$id")"; then :; else idx=${#AICM_RULE_ID[@]}; fi
    AICM_RULE_ID[idx]="$id"; AICM_RULE_KIND[idx]="$kind"; AICM_RULE_PATH[idx]="$path"
    AICM_RULE_PATTERN[idx]="${pattern:-*}"; AICM_RULE_DAYS[idx]="${days:-0}"; AICM_RULE_LIMIT[idx]="${limit:-0}"
    AICM_RULE_NOTE[idx]="$note"
    if [[ "$default" == on ]]; then AICM_RULE_ENABLED[idx]=1; else AICM_RULE_ENABLED[idx]=0; fi
  done < "$file"
}

aicm_load_rules() {
  AICM_RULE_ID=(); AICM_RULE_KIND=(); AICM_RULE_PATH=(); AICM_RULE_PATTERN=()
  AICM_RULE_DAYS=(); AICM_RULE_LIMIT=(); AICM_RULE_ENABLED=(); AICM_RULE_NOTE=()
  aicm_load_rule_file "$1" || return 1
  aicm_load_rule_file "$2" || return 1
}

# find(1) arguments that keep protected files out of every result.
AICM_PROTECT_ARGS=(
  ! -iname MEMORY.md ! -iname CLAUDE.md ! -iname AGENTS.md ! -iname GEMINI.md
  ! -iname auth.json ! -iname .credentials.json ! -iname credentials.json ! -iname credentials
  ! -iname settings.json ! -iname settings.local.json ! -iname config.toml ! -iname config.json ! -iname config.yaml
  ! -iname '*.env' ! -iname .env ! -path '*/memory/*'
)

aicm_state_write() {
  local name="$1" body="$2"
  mkdir -p "$AICM_HOME/state"
  printf '%s\n' "$body" > "$AICM_HOME/state/$name.json"
}

aicm_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
  printf '%s' "$s"
}

# Desktop notification. Never fails the caller. Disable with AICM_NOTIFY=0.
aicm_notify() {
  local title="$1" body="$2"
  echo "notify: $title - $body"
  [[ "${AICM_NOTIFY:-1}" == 0 ]] && return 0
  if command -v osascript >/dev/null 2>&1; then
    local t b
    t="${title//\\/\\\\}"; t="${t//\"/\\\"}"
    b="${body//\\/\\\\}"; b="${b//\"/\\\"}"
    osascript -e "display notification \"$b\" with title \"$t\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$body" >/dev/null 2>&1 || true
  fi
  return 0
}

AICM_LAUNCHD_PREFIX="io.github.wilgon456.ai-cli-auto-manager"

aicm_job_exists() {
  local job="$1"
  if [[ "$(aicm_os)" == mac ]]; then
    [[ -f "$HOME/Library/LaunchAgents/$AICM_LAUNCHD_PREFIX.$job.plist" ]] || return 1
    launchctl list 2>/dev/null | grep -q "$AICM_LAUNCHD_PREFIX.$job" || return 1
  else
    crontab -l 2>/dev/null | grep -q "# aicm:$job\$" || return 1
  fi
}

# Prints one line per scheduled job that was installed but is now missing.
aicm_schedule_problems() {
  local skip="${1:-}" file="$AICM_HOME/state/schedule.json" job
  [[ -f "$file" ]] || return 0
  for job in $(grep -o '"[a-z]*"' "$file" | tr -d '"' | grep -E '^(update|clean|inventory)$'); do
    [[ "$job" == "$skip" ]] && continue
    aicm_job_exists "$job" || echo "scheduled job '$job' is missing; run: aicm schedule install"
  done
}

# ---------------------------------------------------------------------------
# Running CLIs and the AI CLI catalog
# ---------------------------------------------------------------------------

# aicm_timeout SECONDS CMD ARGS...: exit 124 when the command runs too long.
aicm_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    local rc=0
    perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@" || rc=$?
    ((rc == 142)) && return 124
    return "$rc"
  else
    "$@"
  fi
}

aicm_semver() {
  grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([-+][0-9A-Za-z.-]+)?' | head -n 1
}

# Succeeds when version $1 is older than $2 (numeric compare of the dotted part).
aicm_version_older() {
  local a="${1%%[-+]*}" b="${2%%[-+]*}"
  [[ -n "$a" && -n "$b" && "$a" != "$b" ]] || return 1
  awk -v a="$a" -v b="$b" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, "."); k = (n > m) ? n : m
    for (i = 1; i <= k; i++) { xi = x[i] + 0; yi = y[i] + 0; if (xi < yi) exit 0; if (xi > yi) exit 1 }
    exit 1 }'
}

aicm_realpath() {
  local p="$1"
  if command -v perl >/dev/null 2>&1; then
    perl -MCwd -e 'print Cwd::abs_path(shift)' "$p" 2>/dev/null && return 0
  fi
  readlink -f "$p" 2>/dev/null || printf '%s' "$p"
}

AICM_BUILTIN_IDS=" claude codex opencode grok kimi agy "
AICM_CLI_ID=(); AICM_CLI_CMD=(); AICM_CLI_NAME=(); AICM_CLI_NPM=(); AICM_CLI_BREW=()
AICM_CLI_WINGET=(); AICM_CLI_SELF=(); AICM_CLI_NOTE=()

aicm_cli_index() {
  local id="$1" i
  for ((i = 0; i < ${#AICM_CLI_ID[@]}; i++)); do
    [[ "${AICM_CLI_ID[$i]}" == "$id" ]] && { echo "$i"; return 0; }
  done
  return 1
}

aicm_cli_col() { local v; v="$(aicm_trim "$1")"; [[ "$v" == - ]] && v=""; printf '%s' "$v"; }

aicm_load_catalog_file() {
  local file="$1" line id cmd name npm brew winget self note rest idx source
  [[ -f "$file" ]] || return 0
  source="$(basename "$file")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$(aicm_trim "$line")" || "$(aicm_trim "$line")" == \#* ]] && continue
    IFS='|' read -r id cmd name npm brew winget self note rest <<< "$line"
    id="$(aicm_cli_col "$id")"; cmd="$(aicm_cli_col "$cmd")"; name="$(aicm_cli_col "$name")"
    npm="$(aicm_cli_col "$npm")"; brew="$(aicm_cli_col "$brew")"; winget="$(aicm_cli_col "$winget")"
    self="$(aicm_cli_col "$self")"; note="$(aicm_cli_col "$note")"
    [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "invalid catalog id '$id' in $source" >&2; return 1; }
    [[ -n "$cmd" || -n "$winget" ]] || { echo "catalog row '$id' in $source needs a command or a winget id" >&2; return 1; }
    if idx="$(aicm_cli_index "$id")"; then :; else idx=${#AICM_CLI_ID[@]}; fi
    AICM_CLI_ID[idx]="$id"; AICM_CLI_CMD[idx]="$cmd"; AICM_CLI_NAME[idx]="${name:-$id}"; AICM_CLI_NPM[idx]="$npm"
    AICM_CLI_BREW[idx]="$brew"; AICM_CLI_WINGET[idx]="$winget"; AICM_CLI_SELF[idx]="$self"; AICM_CLI_NOTE[idx]="$note"
  done < "$file"
}

aicm_load_catalog() {
  AICM_CLI_ID=(); AICM_CLI_CMD=(); AICM_CLI_NAME=(); AICM_CLI_NPM=(); AICM_CLI_BREW=()
  AICM_CLI_WINGET=(); AICM_CLI_SELF=(); AICM_CLI_NOTE=()
  aicm_load_catalog_file "${1:-$AICM_ROOT/rules/ai-clis.conf}" || return 1
  aicm_load_catalog_file "${2:-$AICM_HOME/ai-clis.local.conf}" || return 1
}

aicm_is_builtin() { [[ "$AICM_BUILTIN_IDS" == *" $1 "* ]]; }

AICM_NPM_CMD="${NPM:-$(command -v npm 2>/dev/null || true)}"
AICM_NPM_PREFIX_CACHE=""; AICM_NPM_ROOT_CACHE=""; AICM_NPM_CACHED=false

aicm_npm_cache() {
  [[ "$AICM_NPM_CACHED" == true ]] && return 0
  AICM_NPM_CACHED=true
  [[ -n "$AICM_NPM_CMD" ]] && command -v "$AICM_NPM_CMD" >/dev/null 2>&1 || return 0
  AICM_NPM_PREFIX_CACHE="$(aicm_timeout 30 "$AICM_NPM_CMD" prefix -g 2>/dev/null | head -n 1 || true)"
  AICM_NPM_ROOT_CACHE="$(aicm_timeout 30 "$AICM_NPM_CMD" root -g 2>/dev/null | head -n 1 || true)"
}

# Version of a globally installed npm package, empty when not installed.
aicm_npm_pkg_version() {
  aicm_npm_cache
  local file="$AICM_NPM_ROOT_CACHE/$1/package.json"
  [[ -n "$1" && -n "$AICM_NPM_ROOT_CACHE" && -f "$file" ]] || return 0
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1
}

# Lists global npm packages as "name version" lines.
aicm_npm_globals() {
  aicm_npm_cache
  [[ -n "$AICM_NPM_ROOT_CACHE" && -d "$AICM_NPM_ROOT_CACHE" ]] || return 0
  local d name
  for d in "$AICM_NPM_ROOT_CACHE"/* "$AICM_NPM_ROOT_CACHE"/@*/*; do
    [[ -f "$d/package.json" ]] || continue
    name="${d#"$AICM_NPM_ROOT_CACHE"/}"
    echo "$name $(aicm_npm_pkg_version "$name")"
  done
}

AICM_BREW_PREFIX_CACHE="unset"
aicm_brew_prefix() {
  if [[ "$AICM_BREW_PREFIX_CACHE" == unset ]]; then
    AICM_BREW_PREFIX_CACHE=""
    command -v brew >/dev/null 2>&1 && AICM_BREW_PREFIX_CACHE="$(brew --prefix 2>/dev/null || true)"
  fi
  printf '%s' "$AICM_BREW_PREFIX_CACHE"
}

# Sets CLI_INSTALLED CLI_PATH CLI_METHOD (npm|brew|standalone) CLI_NPMCOPY for catalog index $1.
aicm_cli_install() {
  local i="$1" cmd npm_version real brew_prefix
  CLI_INSTALLED=false; CLI_PATH=""; CLI_METHOD=""; CLI_NPMCOPY=""
  cmd="${AICM_CLI_CMD[$i]}"
  [[ -n "$cmd" ]] || return 0
  npm_version="$(aicm_npm_pkg_version "${AICM_CLI_NPM[$i]}")"
  CLI_PATH="$(command -v "$cmd" 2>/dev/null || true)"
  if [[ -z "$CLI_PATH" ]]; then
    if [[ -n "$npm_version" ]]; then CLI_INSTALLED=true; CLI_METHOD=npm; CLI_PATH="(npm package, command not on PATH)"; fi
    return 0
  fi
  CLI_INSTALLED=true
  real="$(aicm_realpath "$CLI_PATH")"
  aicm_npm_cache
  brew_prefix="$(aicm_brew_prefix)"
  if [[ "$real" == */node_modules/* ]] || { [[ -n "$AICM_NPM_PREFIX_CACHE" ]] && [[ "$CLI_PATH" == "$AICM_NPM_PREFIX_CACHE/bin/"* ]]; }; then
    CLI_METHOD=npm
  elif [[ "$real" == */Cellar/* || "$real" == */Caskroom/* ]] || { [[ -n "$brew_prefix" ]] && [[ "$real" == "$brew_prefix/"* ]]; }; then
    CLI_METHOD=brew
  else
    CLI_METHOD=standalone
  fi
  [[ "$CLI_METHOD" != npm && -n "$npm_version" ]] && CLI_NPMCOPY="$npm_version"
  return 0
}

# Prints whether the daily update keeps the copy on PATH current: "yes" or "no: <why>".
aicm_cli_coverage() {
  local i="$1" id
  id="${AICM_CLI_ID[$i]}"
  case "$CLI_METHOD" in
    npm) if [[ -n "${AICM_CLI_NPM[$i]}" ]]; then echo yes; else echo "no: unknown npm package"; fi ;;
    brew)
      if [[ -n "${AICM_CLI_BREW[$i]}" ]] || [[ " claude codex opencode " == *" $id "* ]]; then echo yes
      else echo "no: add its Homebrew name to the catalog"; fi ;;
    standalone)
      if aicm_is_builtin "$id" && [[ -n "$CLI_NPMCOPY" && " claude codex opencode kimi " == *" $id "* ]]; then
        echo "no: the update refreshes the npm copy, not the one on PATH"
      elif [[ -n "${AICM_CLI_SELF[$i]}" ]]; then echo yes
      elif [[ -n "${AICM_CLI_NOTE[$i]}" ]]; then echo "no: ${AICM_CLI_NOTE[$i]}"
      else echo "no: installed standalone without a self-update command"; fi ;;
    *) echo no ;;
  esac
}
