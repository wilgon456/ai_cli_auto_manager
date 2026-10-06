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
  for job in $(grep -o '"[a-z]*"' "$file" | tr -d '"' | grep -E '^(update|clean)$'); do
    [[ "$job" == "$skip" ]] && continue
    aicm_job_exists "$job" || echo "scheduled job '$job' is missing; run: aicm schedule install"
  done
}
