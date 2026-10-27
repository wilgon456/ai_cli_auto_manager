#!/usr/bin/env bash
# shellcheck disable=SC2034 # the rule arrays and AICM_PROTECT_ARGS are read by the scripts that source this file
# Shared helpers for AI CLI Auto Manager on macOS and Linux.
# Source this file; it defines functions and variables only.
# Must keep working on the bash 3.2 that ships with macOS (no associative arrays, no mapfile, no ${x,,}).

AICM_ROOT="${AICM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AICM_HOME_SET="${AICM_HOME:+1}"
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
  # Codex reads CODEX_HOME, so its sessions and database live there when it is set.
  p="${p//\{codex\}/${CODEX_HOME:-$HOME/.codex}}"
  p="${p//\{temp\}/$(aicm_temp_dir)}"
  p="${p//\{cache\}/$(aicm_cache_dir)}"
  p="${p//\{localappdata\}/$(aicm_cache_dir)}"
  while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
  [[ "$p" != / ]] && p="${p%/}"
  printf '%s' "$p"
}

# The folder itself with symlinks resolved, or the text as given when it does not exist.
aicm_real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

# The temp folder counts as a cleanup area only when it really is a temp folder: never /, the home
# folder or a folder above it, and named tmp/temp/T (macOS: /var/folders/../T) or under /tmp or /var/folders.
# A TMPDIR pointing at / or /home would otherwise let a {temp} rule sweep the home folder.
aicm_temp_usable() {
  local temp home
  temp="$(aicm_real_dir "$(aicm_temp_dir)")"; home="$(aicm_real_dir "${HOME%/}")"
  [[ -n "$temp" && "$temp" != / && -n "$home" && "$home" != / ]] || return 1
  [[ "$home/" == "$temp/"* ]] && return 1
  case "$(aicm_lower "$(basename "$temp")")" in tmp|temp|t) return 0 ;; esac
  case "$temp" in /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;; esac
  return 1
}

# A rule may only touch the home folder (never the home folder itself) or the temp folder.
# $2 = 1: the rule's path is written with {temp}; it is allowed only while TMPDIR looks right.
aicm_path_allowed() {
  local p="$1" from_temp="${2:-0}" home temp in_temp=1 anchor check real real_home real_anchor
  home="${HOME%/}"
  temp="$(aicm_temp_dir)"
  case "/$p/" in
    */../*|*/./*) return 1 ;;
  esac
  # No home folder (HOME unset or /) means no safe area at all.
  [[ -n "$home" && "$home" != / && "$p" == /* ]] || return 1
  # The home folder itself, or anything above it, never.
  [[ "$home/" == "$p/"* ]] && return 1
  if [[ "$p" == "$temp" || "$p" == "$temp/"* ]] && aicm_temp_usable; then in_temp=0; fi
  [[ "$from_temp" == 1 && "$in_temp" != 0 ]] && return 1
  if ((in_temp == 0)); then anchor="$temp"
  elif [[ "$p" == "$home/"* ]]; then anchor="$home"
  else return 1; fi
  # A link in any component below the trusted home/temp root can redirect find and rm outside it.
  # Do not reject system aliases such as macOS /var -> /private/var above the trusted root.
  check="$p"
  while [[ "$check" != "$anchor" ]]; do
    [[ -L "$check" ]] && return 1
    [[ "$check" == / ]] && return 1
    check="$(dirname "$check")"
  done
  real_home="$(cd -P -- "$home" 2>/dev/null && pwd -P)" || return 1
  real_anchor="$(cd -P -- "$anchor" 2>/dev/null && pwd -P)" || return 1
  if [[ -e "$p" ]]; then
    real="$(cd -P -- "$p" 2>/dev/null && pwd -P)" || return 1
  else
    # Missing rule folders are harmless. Resolve the trusted anchor so system aliases such as
    # /var and /private/var compare consistently even before the folder has been created.
    real="$real_anchor${p#"$anchor"}"
  fi
  [[ "$real_home/" == "$real/"* ]] && return 1
  [[ "$real" == "$real_anchor" || "$real" == "$real_anchor/"* ]]
}

# Moves into AICM_HOME/archive and purges of date folders must stay inside that tree.
# Linked ancestors (including archive itself or a nested destination) are refused.
# aicm_path_allowed already preserves macOS /var -> /private/var aliases above HOME/TMP.
aicm_archive_dest_ok() {
  local dest="$1" archive="${AICM_HOME%/}/archive"
  [[ -n "$dest" && -n "$AICM_HOME" ]] || return 1
  case "$dest" in
    "$archive"|"$archive"/*) ;;
    *) return 1 ;;
  esac
  aicm_path_allowed "$dest" 0
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

# Sums one byte count per line. printf "%d" is a 32-bit conversion in some awks (mawk clamps it at
# 2147483647), so the sum is printed with %.0f: exact for every whole number below 2^53 (8 PiB).
aicm_sum_lines() { awk '{ s += $1 } END { printf "%.0f", s }'; }

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
    case "$kind" in age|age-files|cap|budget|keep-latest|command|archive|codex) ;; *) echo "invalid rule kind '$kind' in $source: $line" >&2; return 1 ;; esac
    case "$default" in on|off) ;; *) echo "invalid default '$default' in $source: $line" >&2; return 1 ;; esac
    [[ -z "$days" || "$days" =~ ^[0-9]+$ ]] || { echo "invalid days in $source: $line" >&2; return 1; }
    [[ -z "$limit" || "$limit" =~ ^[0-9]+$ ]] || { echo "invalid limit in $source: $line" >&2; return 1; }
    if [[ "$kind" == age || "$kind" == age-files ]] && (( ${days:-0} < 1 )); then echo "$kind rule needs days >= 1 in $source: $line" >&2; return 1; fi
    if [[ "$kind" == budget ]] && (( ${days:-0} < 1 || ${limit:-0} < 1 )); then echo "budget rule needs days >= 1 (minimum age) and limit >= 1 (total MiB) in $source: $line" >&2; return 1; fi
    if [[ "$kind" == keep-latest ]] && (( ${limit:-0} < 1 )); then echo "keep-latest rule needs limit >= 1 in $source: $line" >&2; return 1; fi
    if [[ "$kind" == archive ]] && (( ${days:-0} < 1 || ${limit:-0} < 1 )); then echo "archive rule needs days >= 1 (archive after) and limit >= 1 (delete after) in $source: $line" >&2; return 1; fi
    if [[ "$kind" == codex ]] && (( ${days:-0} < 1 )); then echo "codex rule needs days >= 1 in $source: $line" >&2; return 1; fi
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

# id -> category. Ids missing from the map are "other" (custom and local rules).
AICM_CAT_ID=(); AICM_CAT_NAME=()

aicm_load_categories() {
  local file="$AICM_ROOT/rules/clean-categories.conf" line id cat
  AICM_CAT_ID=(); AICM_CAT_NAME=()
  [[ -f "$file" ]] || { echo "category map missing: $file" >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$(aicm_trim "$line")" ]] && continue
    [[ "$(aicm_trim "$line")" == \#* ]] && continue
    IFS='|' read -r id cat _ <<< "$line"
    id="$(aicm_trim "$id")"; cat="$(aicm_lower "$(aicm_trim "$cat")")"
    [[ -n "$id" && -n "$cat" ]] || { echo "invalid category row: $line" >&2; return 1; }
    case "$cat" in
      sessions|cache|logs|temp|other) ;;
      *) echo "invalid category '$cat' for $id" >&2; return 1 ;;
    esac
    local i
    for ((i = 0; i < ${#AICM_CAT_ID[@]}; i++)); do
      [[ "${AICM_CAT_ID[$i]}" == "$id" ]] && { echo "duplicate category id: $id" >&2; return 1; }
    done
    AICM_CAT_ID+=("$id"); AICM_CAT_NAME+=("$cat")
  done < "$file"
}

aicm_rule_category() { # id
  local id="$1" i
  for ((i = 0; i < ${#AICM_CAT_ID[@]}; i++)); do
    if [[ "${AICM_CAT_ID[$i]}" == "$id" ]]; then
      printf '%s' "${AICM_CAT_NAME[$i]}"
      return 0
    fi
  done
  printf '%s' other
}

# Prints a normalized comma list (sessions,cache,logs,temp,other,all). Empty input prints nothing.
# "all" cannot be combined. Duplicates, blanks and unknown names fail.
aicm_normalize_categories() {
  local raw="$1" tok seen="" out=""
  local parts=()
  [[ -n "$raw" ]] || return 0
  # read drops a trailing empty field, so a final comma has to be rejected first.
  [[ "$raw" == *, || "$raw" == ,* ]] && { echo "empty category in '$raw'" >&2; return 1; }
  IFS=',' read -r -a parts <<< "$raw"
  for tok in "${parts[@]}"; do
    tok="$(aicm_lower "$(aicm_trim "$tok")")"
    [[ -n "$tok" ]] || { echo "empty category in '$raw'" >&2; return 1; }
    case "$tok" in
      sessions|cache|logs|temp|other|all) ;;
      *) echo "unknown category: $tok" >&2; return 1 ;;
    esac
    case " $seen " in
      *" $tok "*) echo "duplicate category: $tok" >&2; return 1 ;;
    esac
    seen="$seen $tok"
    out="${out:+$out,}$tok"
  done
  if [[ "$out" == *all* && "$out" != all ]]; then
    echo "category 'all' cannot be combined with other categories" >&2
    return 1
  fi
  printf '%s' "$out"
}

aicm_protection_policy() { printf '%s' 'never removes memory, credentials, settings or keys'; }

# Records one local history entry through maintenance.js. Failure warns and does not change the caller's result.
aicm_record_history() { # kind json-file
  local js="$AICM_ROOT/lib/maintenance.js" errf rc=0
  if ! command -v node >/dev/null 2>&1; then
    echo "warning: history was not recorded (Node.js is not available)" >&2
    return 0
  fi
  if [[ ! -f "$js" ]]; then
    echo "warning: history was not recorded (lib/maintenance.js is missing)" >&2
    return 0
  fi
  if [[ ! -f "${2:-}" ]]; then
    echo "warning: history was not recorded (summary file is missing)" >&2
    return 0
  fi
  errf="$(mktemp)"
  node "$js" history-add --kind "$1" --file "$2" --json >"$errf.out" 2>"$errf" || rc=$?
  if ((rc != 0)); then
    echo "warning: history was not recorded: $(tr '\n' ' ' < "$errf" | head -c 300)" >&2
  fi
  rm -f "$errf" "$errf.out"
  return 0
}

aicm_rule_action() { # kind limit
  case "$1" in
    archive) printf '%s' archive ;;
    codex) if [[ "${2:-0}" == 0 ]]; then printf '%s' delete; else printf '%s' archive; fi ;;
    command) printf '%s' run ;;
    keep-latest) printf '%s' keep ;;
    *) printf '%s' delete ;;
  esac
}

# Read-only reason: the rule note, plus the earlier archive age when the CLI deletes on its own.
aicm_rule_reason() { # id kind days note
  local id="$1" kind="$2" days="$3" note="$4" reason="$4" eff native extra
  if [[ "$kind" == archive ]]; then
    eff="$(aicm_archive_days "$id" "$days")"
    if [[ "$eff" != "$days" ]]; then
      native="$(aicm_native_retention_days "$id")"
      extra="archive after ${eff}d (the CLI deletes after ${native}d)"
      if [[ -n "$reason" ]]; then reason="$reason; $extra"; else reason="$extra"; fi
    fi
  fi
  if [[ -z "$reason" ]]; then
    reason="$kind"
    [[ "${days:-0}" != 0 ]] && reason="$reason after ${days}d"
  fi
  printf '%s' "$reason"
}

# find(1) arguments that keep protected files out of every result.
AICM_PROTECT_ARGS=(
  ! -iname MEMORY.md ! -iname CLAUDE.md ! -iname AGENTS.md ! -iname GEMINI.md
  ! -iname auth.json ! -iname .credentials.json ! -iname credentials.json ! -iname credentials
  ! -iname settings.json ! -iname settings.local.json ! -iname config.toml ! -iname config.json ! -iname config.yaml
  ! -iname '*.env' ! -iname .env ! -iname .npmrc ! -iname .netrc
  ! -iname '*.pem' ! -iname '*.key' ! -iname 'id_rsa*' ! -iname 'id_ed25519*' ! -iname 'id_ecdsa*' ! -iname 'id_dsa*'
  ! -ipath '*/memory/*'
)

# Writes to a temp file and renames it into place, so a crash mid-write never leaves a half-written state file.
aicm_state_write() {
  local name="$1" body="$2" file
  mkdir -p "$AICM_HOME/state"
  file="$AICM_HOME/state/$name.json"
  printf '%s\n' "$body" > "$file.$$.tmp" && mv -f "$file.$$.tmp" "$file"
}

aicm_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
  printf '%s' "$s"
}

# Notifies the items that are new or were last announced 7+ days ago, so a lasting problem does not
# raise a notification every day. Items that went away are forgotten.
aicm_attention() { # key items...
  local key="$1" file now item last out="" joined
  shift
  local due=()
  file="$AICM_HOME/state/attention-$key.tsv"
  now="$(date +%s)"
  mkdir -p "$AICM_HOME/state"
  for item in "$@"; do
    [[ -n "$item" ]] || continue
    last=""
    [[ -f "$file" ]] && last="$(I="$item" awk -F '\t' '$2 == ENVIRON["I"] { print $1; exit }' "$file")"
    if [[ -z "$last" ]] || ((now - last >= 7 * 86400)); then due+=("$item"); last="$now"; fi
    out+="$last"$'\t'"$item"$'\n'
  done
  printf '%s' "$out" > "$file.$$.tmp" && mv -f "$file.$$.tmp" "$file"
  if ((${#due[@]})); then
    joined="$(printf '%s; ' "${due[@]}")"
    aicm_notify "AI CLI Auto Manager" "${joined%; }"
  fi
  return 0
}

# Desktop notification. Never fails the caller. Disable the desktop part with AICM_NOTIFY=0.
# Every notification is also appended to logs/notifications.log (last 500 lines kept), so one that
# never showed on screen can still be read with `aicm status`.
aicm_notify() {
  local title="$1" body="$2" log="$AICM_HOME/logs/notifications.log" n bus
  echo "notify: $title - $body"
  if mkdir -p "$AICM_HOME/logs" 2>/dev/null; then
    printf '%s %s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$title" "${body//$'\n'/ }" >> "$log" 2>/dev/null || true
    n="$(wc -l < "$log" 2>/dev/null | tr -d ' ')"
    if [[ "$n" =~ ^[0-9]+$ ]] && ((n > 600)); then
      { tail -n 500 "$log" > "$log.$$.tmp" && mv -f "$log.$$.tmp" "$log"; } 2>/dev/null || rm -f "$log.$$.tmp"
    fi
  fi
  [[ "${AICM_NOTIFY:-1}" == 0 ]] && return 0
  if command -v osascript >/dev/null 2>&1; then
    local t b
    t="${title//\\/\\\\}"; t="${t//\"/\\\"}"
    b="${body//\\/\\\\}"; b="${b//\"/\\\"}"
    osascript -e "display notification \"$b\" with title \"$t\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    # cron jobs have no session bus address; the user's bus is at a fixed place under systemd.
    bus="${DBUS_SESSION_BUS_ADDRESS:-}"
    if [[ -z "$bus" && -S "/run/user/$(id -u)/bus" ]]; then bus="unix:path=/run/user/$(id -u)/bus"; fi
    if [[ -n "$bus" ]]; then DBUS_SESSION_BUS_ADDRESS="$bus" notify-send "$title" "$body" >/dev/null 2>&1 || true
    else notify-send "$title" "$body" >/dev/null 2>&1 || true; fi
  fi
  return 0
}

# yyyymmdd of the date N days ago (GNU date, BSD date, or perl).
aicm_date_days_ago() {
  local n="$1"
  date -d "-$n days" +%Y%m%d 2>/dev/null && return 0
  date -v-"$n"d +%Y%m%d 2>/dev/null && return 0
  perl -e 'my @t = localtime(time - $ARGV[0] * 86400); printf "%04d%02d%02d\n", $t[5] + 1900, $t[4] + 1, $t[3]' "$n"
}

# Days after which the CLI deletes these files itself (0 when it does not). The archive step has to
# run before that, and the cleanup runs weekly, so it archives a week earlier than the CLI deletes.
aicm_native_retention_days() {
  local v
  case "$1" in
    claude-transcripts)
      v="$(sed -n 's/.*"cleanupPeriodDays"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$HOME/.claude/settings.json" 2>/dev/null | head -n 1)"
      echo "${v:-30}" ;;
    gemini-tmp)
      v="$(sed -n 's/.*"maxAge"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*[hdw]\)".*/\1/p' "$HOME/.gemini/settings.json" 2>/dev/null | head -n 1)"
      case "$v" in
        *h) echo $(( (${v%h} + 23) / 24 )) ;;
        *w) echo $(( ${v%w} * 7 )) ;;
        *d) echo "${v%d}" ;;
        *) echo 30 ;;
      esac ;;
    qwen-tmp)
      v="$(sed -n 's/.*"cleanupPeriodDays"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$HOME/.qwen/settings.json" 2>/dev/null | head -n 1)"
      echo "${v:-30}" ;;
    *) echo 0 ;;
  esac
}

aicm_archive_days() { # rule_id rule_days
  local native days="$2"
  native="$(aicm_native_retention_days "$1")"
  if ((native > 0)); then
    ((native - 8 < days)) && days=$((native - 8))
    ((days < 1)) && days=1
  fi
  echo "$days"
}

# Codex threads from its state DB (read-only), one "id<TAB>updated_at<TAB>archived" line each.
# Uses sqlite3 (always on macOS) or python3 on Linux; fails when neither can read it, or when the
# threads table lacks the expected columns (an unknown layout is never guessed at).
aicm_codex_threads() {
  local root="$1" db cols arch=0
  [[ "${AICM_CODEX_DB_READER:-1}" == 0 ]] && return 1
  # The newest layout: the highest number after the last "_" of the file name (state_12 over state_5).
  db="$(find "$root" -maxdepth 1 -name 'state_*.sqlite' -type f 2>/dev/null \
    | awk '{ n = $0; sub(/.*_/, "", n); sub(/\.sqlite$/, "", n); if (n ~ /^[0-9]+$/) print n "\t" $0 }' \
    | sort -n | tail -n 1 | cut -f 2-)"
  [[ -n "$db" ]] || return 1
  if command -v sqlite3 >/dev/null 2>&1; then
    cols="$(sqlite3 -readonly "$db" "select group_concat(name, ',') from pragma_table_info('threads')" 2>/dev/null)" || return 1
    [[ ",$cols," == *,id,* && ",$cols," == *,updated_at,* ]] || return 1
    [[ ",$cols," == *,archived,* ]] && arch=archived
    sqlite3 -readonly -separator "$(printf '\t')" "$db" "select id, updated_at, $arch from threads" 2>/dev/null
    return
  fi
  # On macOS python3 may be an installer stub, so only Linux falls back to it.
  if [[ "$(aicm_os)" == linux ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$db" <<'PY' 2>/dev/null
import sqlite3, sys
con = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
cols = {r[1] for r in con.execute('pragma table_info(threads)')}
if not {'id', 'updated_at'} <= cols:
    sys.exit(3)
arch = 'archived' if 'archived' in cols else '0'
for r in con.execute('select id, updated_at, ' + arch + ' from threads'):
    print('\t'.join('' if v is None else str(v) for v in r))
PY
    return
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Installed copy: scheduled jobs run ~/.ai-cli-auto-manager/app, not the git clone, so moving or
# deleting the clone cannot stop them. The daily update refreshes the copy when the clone has a
# newer VERSION.
# ---------------------------------------------------------------------------

AICM_APP_DIR="$AICM_HOME/app"

# ---------------------------------------------------------------------------
# Ownership of AICM_HOME. The tool writes only these top-level entries: app (app.new, app.old while
# swapping), logs, state, archive and inventory.md, plus the .aicm-home marker. Users may add hooks,
# *.local.conf, repos.conf and update-policy.json. A folder that holds anything else, or a reserved
# entry with content the tool did not write (app/personal.txt), is never adopted, and nothing in it
# is replaced or removed. The marker alone does not whitelist content: every reserved entry is
# checked again before a copy swap, an uninstall or a purge removes it. AICM_HOME itself may be a
# link chosen on purpose; links in the reserved entries are refused.
# ---------------------------------------------------------------------------

AICM_HOME_MARKER_TEXT='AI CLI Auto Manager home (logs, state, archive, installed copy)'
AICM_HOME_STATE="" AICM_HOME_PROBLEM=""

# Entries of folder $1, one per line (names only, hidden ones included).
aicm_dir_entries() {
  local e
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [[ -e "$e" || -L "$e" ]] && printf '%s\n' "${e##*/}"
  done
  return 0
}

aicm_home_reserved_name() { case "$1" in app|app.new|app.old|logs|state|archive|inventory.md) return 0 ;; esac; return 1; }
aicm_home_user_name() { case "$1" in .aicm-home|hooks|repos.conf|update-policy.json|*.local.conf|.DS_Store) return 0 ;; esac; return 1; }

# A marker the tool wrote: a small regular file whose first line is the marker text.
aicm_marker_valid() { # home
  local m="$1/.aicm-home" line="" size
  [[ -f "$m" && ! -L "$m" ]] || return 1
  size="$(wc -c < "$m" 2>/dev/null | tr -d ' ')"
  [[ "$size" =~ ^[0-9]+$ ]] && ((size <= 1024)) || return 1
  IFS= read -r line < "$m" || [[ -n "$line" ]] || return 1
  [[ "${line%$'\r'}" == "$AICM_HOME_MARKER_TEXT" ]]
}

# A file name the tool ships in bin/, lib/, rules/ or windows/ (used only for copies built before the
# copy kept its own file list in .aicm-copy).
aicm_app_file_shape() { # exact legacy file names only
  case "$1" in
    bin/aicm|bin/aicm.ps1|bin/clean_ai_leftovers.ps1|bin/clean_ai_leftovers.sh|bin/inventory_ai_clis.ps1|bin/inventory_ai_clis.sh|bin/update_ai_clis.ps1|bin/update_ai_clis.sh) return 0 ;;
    lib/aicm-common.ps1|lib/aicm-common.sh|lib/aicm-file-guard.cs|lib/aicm-job.cs|lib/aicm-process-token.cs|lib/auto-maintenance.js|lib/codex-host.sh|lib/config-drift.js|lib/maintenance-cli.js|lib/maintenance-files.js|lib/maintenance-files.ps1|lib/maintenance-processes.js|lib/maintenance.js|lib/node-common.js|lib/npm-guard.js|lib/optimize.js|lib/processes.js|lib/supervise.js|lib/update-policy.js|lib/worktrees.js) return 0 ;;
    rules/ai-clis.conf|rules/clean-categories.conf|rules/clean-rules.conf|rules/maintenance.conf) return 0 ;;
    windows/install_scheduled_task.ps1|windows/run-hidden.vbs) return 0 ;;
    *) return 1 ;;
  esac
}

# An installed copy this tool built: a real folder with only the entries a copy has, and below bin, lib,
# rules and windows only regular files the copy was built with (listed in its .aicm-copy; a copy from
# an older version without that list: files its source checkout or this checkout also has, or files
# named like the tool's own). app and app.old also need SOURCE and VERSION; a half-built app.new
# ("partial") may still lack them.
aicm_app_copy_owned() { # dir [partial]
  local d="$1" name f src
  if [[ -L "$d" || ! -d "$d" ]]; then AICM_HOME_PROBLEM="$d is not a real folder"; return 1; fi
  while IFS= read -r name; do
    case "$name" in
      bin|lib|rules|windows)
        [[ -d "$d/$name" && ! -L "$d/$name" ]] || { AICM_HOME_PROBLEM="$d/$name is not a real folder"; return 1; } ;;
      VERSION|LICENSE|README.md|SOURCE|.aicm-copy)
        [[ -f "$d/$name" && ! -L "$d/$name" ]] || { AICM_HOME_PROBLEM="$d/$name is not a regular file"; return 1; } ;;
      .DS_Store) ;;
      *) AICM_HOME_PROBLEM="$d holds $name, which an installed copy does not have"; return 1 ;;
    esac
  done < <(aicm_dir_entries "$d")
  if [[ "${2:-}" != partial && ! ( -f "$d/SOURCE" && -f "$d/VERSION" ) ]]; then
    AICM_HOME_PROBLEM="$d has no SOURCE and VERSION files, so it is not an installed copy"
    return 1
  fi
  f="$(cd "$d" && find bin lib rules windows ! -type f ! -type d -print -quit 2>/dev/null)"
  if [[ -n "$f" ]]; then AICM_HOME_PROBLEM="$d/$f is a link or special file, which an installed copy does not have"; return 1; fi
  src=""
  if [[ ! -f "$d/.aicm-copy" ]]; then
    src="$(head -n 1 "$d/SOURCE" 2>/dev/null || true)"
    [[ "$src" == /* && -d "$src" ]] || src=""
    if [[ -n "$src" && "$(cd "$src" && pwd -P)" == "$(cd "$d" && pwd -P)" ]]; then src=""; fi
  fi
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ -f "$d/.aicm-copy" ]]; then
      grep -Fxq -- "$f" "$d/.aicm-copy" && continue
    elif { [[ -n "$src" && -f "$src/$f" ]]; } ||
         { [[ "$(cd "$AICM_ROOT" 2>/dev/null && pwd -P)" != "$(cd "$d" && pwd -P)" && -f "$AICM_ROOT/$f" ]]; } ||
         aicm_app_file_shape "$f"; then
      continue
    fi
    AICM_HOME_PROBLEM="$d/$f is not part of the installed copy"
    return 1
  done < <(cd "$d" && find bin lib rules windows -type f 2>/dev/null)
  return 0
}

# Names the tool gives files in logs/ (logs, transcripts, cron/launchd output and their temp files).
aicm_log_name_owned() {
  case "$1" in
    maintenance-[0-9]*.jsonl|maintenance-[0-9]*.txt|update-[0-9]*.log|clean-[0-9]*.log|inventory-[0-9]*.log|latest.log|notifications.log) return 0 ;;
    cron.update.log|cron.inventory.log|cron.clean.log|cron.maintenance.log|launchd.*.out.log|launchd.*.err.log) return 0 ;;
    *.log.[0-9]*.tmp) return 0 ;;
  esac
  return 1
}

# Names the tool gives files directly in state/.
aicm_state_file_owned() {
  local n="${1%.[0-9]*.tmp}"
  case "$1" in .weekly-due.[0-9]*|.schedule-time.[0-9]*) return 0 ;; esac
  case "$n" in
    last-update.json|last-clean.json|last-maintenance.json|inventory.json|schedule.json|npm-verdicts.json|npm-verdicts.tsv) return 0 ;;
    update-running.json|update-npm.json|update-npm.tsv|update-deferred.json|inventory-error.json) return 0 ;;
    inventory.tsv|inventory-shadow.txt|config-drift.json|processes.json|worktrees.json|*-attention.json) return 0 ;;
    attention-*.tsv|attention-*.json) return 0 ;;
  esac
  return 1
}

# Folders the tool keeps in state/ and the names it gives files there (manifests, history, lock).
aicm_state_dir_owned() { case "$1" in archive-index|history|sessions|maintenance.lock|maintenance.lock.stale-*) return 0 ;; esac; return 1; }
aicm_state_subfile_owned() { # dir file
  case "$1" in
    archive-index|history) [[ "$2" =~ ^\.?[A-Za-z0-9][A-Za-z0-9._-]{0,80}\.json(\.[0-9]+\.[0-9a-f]+\.tmp)?$ ]] ;;
    sessions) [[ "$2" =~ ^[a-f0-9-]{36}\.json$ ]] ;;
    maintenance.lock*) [[ "$2" == owner.json || "$2" =~ ^\.owner\.json\.[0-9]+\.[0-9a-f]+\.tmp$ ]] ;;
    *) return 1 ;;
  esac
}

# A dated archive folder (archive/<rule>/<yyyymmdd>) holds only real folders and regular files.
aicm_archive_day_owned() { # dir
  [[ -d "$1" && ! -L "$1" && "${1##*/}" =~ ^[0-9]{8}$ ]] || return 1
  [[ -z "$(find "$1" ! -type f ! -type d -print -quit 2>/dev/null)" ]]
}

# The first line of inventory.md as the inventory writes it.
aicm_inventory_owned() { # file
  local line=""
  [[ -f "$1" && ! -L "$1" ]] || return 1
  IFS= read -r line < "$1" || [[ -n "$line" ]] || return 1
  line="${line#$'\xef\xbb\xbf'}"
  [[ "$line" == "# AI CLI inventory"* ]]
}

# Succeeds when every entry of reserved child $1 of AICM_HOME is something the tool wrote.
aicm_home_child_owned() { # name
  local p="$AICM_HOME/$1" name sub
  case "$1" in
    app|app.old) aicm_app_copy_owned "$p" ;;
    app.new) aicm_app_copy_owned "$p" partial ;;
    inventory.md) aicm_inventory_owned "$p" || { AICM_HOME_PROBLEM="$p was not written by the inventory"; return 1; } ;;
    logs|state|archive)
      if [[ -L "$p" || ! -d "$p" ]]; then AICM_HOME_PROBLEM="$p is not a real folder"; return 1; fi
      while IFS= read -r name; do
        case "$1" in
          logs) [[ -f "$p/$name" && ! -L "$p/$name" ]] && aicm_log_name_owned "$name" ;;
          state)
            if [[ -d "$p/$name" && ! -L "$p/$name" ]] && aicm_state_dir_owned "$name"; then
              while IFS= read -r sub; do
                [[ -f "$p/$name/$sub" && ! -L "$p/$name/$sub" ]] && aicm_state_subfile_owned "$name" "$sub" || { AICM_HOME_PROBLEM="$p/$name/$sub was not written by this tool"; return 1; }
              done < <(aicm_dir_entries "$p/$name")
            else
              [[ -f "$p/$name" && ! -L "$p/$name" ]] && aicm_state_file_owned "$name"
            fi ;;
          archive)
            if [[ -d "$p/$name" && ! -L "$p/$name" && "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
              while IFS= read -r sub; do
                aicm_archive_day_owned "$p/$name/$sub" || { AICM_HOME_PROBLEM="$p/$name/$sub is not a dated archive folder"; return 1; }
              done < <(aicm_dir_entries "$p/$name")
            else
              false
            fi ;;
        esac || { AICM_HOME_PROBLEM="$p/$name was not written by this tool"; return 1; }
      done < <(aicm_dir_entries "$p") ;;
    *) return 1 ;;
  esac
}

# Sets AICM_HOME_STATE: missing | empty | owned (valid marker) | legacy (no marker, but only entries
# this tool writes or users add on purpose, each reserved one with content the tool wrote) | foreign
# (anything else; AICM_HOME_PROBLEM says why). Reads only.
aicm_home_status() {
  local h="$AICM_HOME" name any=false evidence=false real home
  AICM_HOME_PROBLEM=""
  # The home folder itself, or a folder above it, is never the manager's folder, whatever marker it holds.
  real="$(aicm_real_dir "${h%/}")"; home="$(aicm_real_dir "${HOME%/}")"
  if [[ -z "$real" || "$real" == / ]] || { [[ -n "$home" && "$home" != / ]] && [[ "$home/" == "$real/"* ]]; }; then
    AICM_HOME_STATE=foreign; AICM_HOME_PROBLEM="$h is your home folder or a folder above it"; return 0
  fi
  if [[ ! -e "$h" && ! -L "$h" ]]; then AICM_HOME_STATE=missing; return 0; fi
  if [[ ! -d "$h" ]]; then AICM_HOME_STATE=foreign; AICM_HOME_PROBLEM="$h is not a folder"; return 0; fi
  if aicm_marker_valid "$h"; then AICM_HOME_STATE=owned; return 0; fi
  if [[ -e "$h/.aicm-home" || -L "$h/.aicm-home" ]] && [[ -L "$h/.aicm-home" || ! -f "$h/.aicm-home" ]]; then
    AICM_HOME_STATE=foreign; AICM_HOME_PROBLEM="$h/.aicm-home is not a regular file"; return 0
  fi
  while IFS= read -r name; do
    any=true
    if aicm_home_reserved_name "$name"; then
      aicm_home_child_owned "$name" || { AICM_HOME_STATE=foreign; return 0; }
      [[ "$name" == app || "$name" == app.old ]] && evidence=true
    elif ! aicm_home_user_name "$name"; then
      AICM_HOME_STATE=foreign; AICM_HOME_PROBLEM="$h holds $name, which AI CLI Auto Manager did not create"; return 0
    fi
  done < <(aicm_dir_entries "$h")
  if [[ "$any" != true ]]; then AICM_HOME_STATE=empty; return 0; fi
  # Reserved names alone (a dated archive folder, a logs folder) prove nothing. An older install is
  # recognized by its installed copy; a folder with only user files (hooks, local rules) is safe to use.
  if [[ "$evidence" == true ]]; then AICM_HOME_STATE=legacy; return 0; fi
  while IFS= read -r name; do
    if aicm_home_reserved_name "$name"; then
      AICM_HOME_STATE=foreign
      AICM_HOME_PROBLEM="$h has no installed copy (app) that shows it is an AI CLI Auto Manager folder, but holds $name"
      return 0
    fi
  done < <(aicm_dir_entries "$h")
  AICM_HOME_STATE=legacy
  return 0
}

aicm_home_refusal() {
  echo "refusing to use AICM_HOME=$AICM_HOME: ${AICM_HOME_PROBLEM:-it is not an AI CLI Auto Manager folder}." >&2
  echo "Point AICM_HOME at an empty or new folder, or move the entries this tool did not create out of it." >&2
}

# Prints what is running when another operation is in progress: an archive, restore or cleanup holding
# the maintenance lock, or an update or cleanup run holding its lock. Fails (prints nothing) otherwise.
aicm_busy_operation() {
  local f pid kind
  f="$AICM_HOME/state/maintenance.lock/owner.json"
  if [[ -f "$f" && ! -L "$f" ]]; then
    pid="$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$f" 2>/dev/null | head -n 1)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "an archive, restore or cleanup holds the maintenance lock (pid $pid)"
      return 0
    fi
  fi
  for kind in update clean; do
    f="$(aicm_temp_dir)/ai-cli-auto-manager-$kind-$(id -u).lockdir/pid"
    pid="$(cat "$f" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      echo "an $kind run is in progress (pid $pid)"
      return 0
    fi
  done
  return 1
}

# Read-only check for commands that only write new logs (previews): fails for a foreign folder.
aicm_home_usable() {
  aicm_home_status
  [[ "$AICM_HOME_STATE" != foreign ]] && return 0
  aicm_home_refusal
  return 1
}

# Marks AICM_HOME as this tool's folder before a real run writes into it. A missing or empty folder
# and an unmarked folder of an older version that passes the structure check are marked; a foreign
# folder is refused (exit status 1) and left exactly as it was.
aicm_claim_home() {
  aicm_home_status
  case "$AICM_HOME_STATE" in
    owned) return 0 ;;
    missing|empty|legacy)
      mkdir -p "$AICM_HOME" 2>/dev/null || { AICM_HOME_PROBLEM="cannot create $AICM_HOME"; aicm_home_refusal; return 1; }
      if ! printf '%s\n' "$AICM_HOME_MARKER_TEXT" > "$AICM_HOME/.aicm-home.$$.tmp" 2>/dev/null ||
         ! mv -f "$AICM_HOME/.aicm-home.$$.tmp" "$AICM_HOME/.aicm-home" 2>/dev/null; then
        rm -f "$AICM_HOME/.aicm-home.$$.tmp" 2>/dev/null
        AICM_HOME_PROBLEM="cannot write $AICM_HOME/.aicm-home"; aicm_home_refusal; return 1
      fi
      [[ "$AICM_HOME_STATE" == legacy ]] && echo "note: $AICM_HOME holds only what this tool writes; marked it as the AI CLI Auto Manager home" >&2
      return 0 ;;
  esac
  aicm_home_refusal
  return 1
}

# Succeeds when copy $2 has every file of source $1 (bin, lib, rules, windows) with the same content,
# plus the files every copy needs.
aicm_app_copy_complete() { # source copy
  local src="$1" copy="$2" f
  for f in VERSION bin/aicm lib/aicm-common.sh; do [[ -s "$copy/$f" ]] || return 1; done
  [[ -n "$(ls "$copy/rules" 2>/dev/null)" ]] || return 1
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    cmp -s "$src/$f" "$copy/$f" || return 1
  done < <(cd "$src" && for d in bin lib rules windows; do [[ -d "$d" ]] && find "$d" -type f; done)
  return 0
}

# Copies bin, lib, rules and VERSION from $1 into the app folder; prints the app folder. The new copy
# is built next to the old one, every copy step is checked and the result compared with the source
# before the swap; on any failure the old copy stays (or is put back) and this returns 1.
# Every step checks its status itself: callers run this inside if/$( ), where errexit is off.
aicm_sync_app_copy() {
  local src="$1" app="$AICM_APP_DIR" d f
  if [[ "$(cd "$src" && pwd -P)" == "$( [[ -d "$app" ]] && cd "$app" && pwd -P)" ]]; then echo "$app"; return 0; fi
  aicm_claim_home || return 1
  # Nothing is moved or removed unless each copy folder is one this tool built.
  for d in "$app" "$app.new" "$app.old"; do
    [[ -e "$d" || -L "$d" ]] || continue
    f=""; [[ "$d" == "$app.new" ]] && f=partial
    if ! aicm_app_copy_owned "$d" $f; then
      echo "installed copy: refusing to replace or remove $d: $AICM_HOME_PROBLEM; move it out of the way and run again" >&2
      return 1
    fi
  done
  # A run that stopped between the two renames left only app.old behind: put it back first.
  if [[ ! -d "$app" && -d "$app.old" ]]; then mv "$app.old" "$app" || return 1; fi
  rm -rf -- "${app:?}.new" "${app:?}.old" || return 1
  mkdir -p "$app.new" || return 1
  for d in bin lib rules windows; do
    if [[ -d "$src/$d" ]]; then cp -R "$src/$d" "$app.new/$d" || { rm -rf -- "${app:?}.new"; return 1; }; fi
  done
  for f in VERSION LICENSE README.md; do
    if [[ -f "$src/$f" ]]; then cp "$src/$f" "$app.new/$f" || { rm -rf -- "${app:?}.new"; return 1; }; fi
  done
  printf '%s\n' "$src" > "$app.new/SOURCE" || { rm -rf -- "${app:?}.new"; return 1; }
  # The copy's own file list: what a later sync, uninstall or purge may replace or remove.
  (cd "$app.new" && find bin lib rules windows -type f 2>/dev/null | LC_ALL=C sort) > "$app.new/.aicm-copy" || { rm -rf -- "${app:?}.new"; return 1; }
  if ! aicm_app_copy_complete "$src" "$app.new"; then
    echo "installed copy: the new copy of $src is incomplete; keeping the old one" >&2
    rm -rf -- "${app:?}.new"
    return 1
  fi
  if [[ -d "$app" ]]; then mv "$app" "$app.old" || { rm -rf -- "${app:?}.new"; return 1; }; fi
  if ! mv "$app.new" "$app"; then
    if [[ -d "$app.old" && ! -d "$app" ]]; then mv "$app.old" "$app"; fi
    rm -rf -- "${app:?}.new"
    return 1
  fi
  rm -rf -- "${app:?}.old"
  echo "$app"
}

# Called at the end of the daily update when it runs from the installed copy. Copies only a newer
# version (checking out an old tag in the clone never downgrades the jobs), then re-registers the
# jobs from the new copy so changed script names or arguments take effect.
aicm_update_app_copy() {
  local app="$AICM_APP_DIR" src new cur
  [[ "$(cd "$AICM_ROOT" && pwd -P)" == "$( [[ -d "$app" ]] && cd "$app" && pwd -P)" ]] || return 0
  [[ -f "$app/SOURCE" ]] || return 0
  src="$(head -n 1 "$app/SOURCE")"
  cur="$(aicm_version)"
  if [[ ! -f "$src/VERSION" || ! -x "$src/bin/aicm" ]]; then
    echo "installed copy: source $src is gone; keeping version $cur"
    return 0
  fi
  new="$(head -n 1 "$src/VERSION" | tr -d '[:space:]')"
  [[ "$new" == "$cur" ]] && return 0
  if ! aicm_version_older "$cur" "$new"; then
    echo "installed copy: $src has version $new, not newer than $cur; keeping $cur"
    return 0
  fi
  if ! aicm_sync_app_copy "$src" >/dev/null; then
    echo "installed copy: could not refresh; keeping $cur, trying again next run"
    return 0
  fi
  echo "installed copy: updated $cur -> $new from $src"
  [[ -f "$AICM_HOME/state/schedule.json" ]] || return 0
  # AICM_ROOT cleared so the new copy finds its own files.
  local out rc=0
  out="$(AICM_ROOT="" /bin/bash "$app/bin/aicm" schedule refresh 2>&1)" || rc=$?
  if [[ -n "$out" ]]; then printf '%s\n' "$out" | sed 's/^/schedule refresh: /'; fi
  if ((rc != 0)); then echo "schedule refresh: failed (exit code $rc); run: aicm schedule install"; fi
  return 0
}

AICM_LAUNCHD_PREFIX="io.github.wilgon456.ai-cli-auto-manager"

# crontab, or the command in AICM_CRONTAB (tests use a fake that keeps its table in a file; the
# updater puts system folders first on PATH, so a fake found through PATH would not be enough).
aicm_crontab() { "${AICM_CRONTAB:-crontab}" "$@"; }

# One "key":"value" string field of a one-line JSON state file.
aicm_json_field() { # file key
  [[ -f "$1" ]] || return 0
  sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1
}

# The jobs recorded in schedule.json, one per line.
aicm_scheduled_jobs() {
  local file="$AICM_HOME/state/schedule.json"
  [[ -f "$file" ]] || return 0
  sed -n 's/.*"jobs":\[\([^]]*\)\].*/\1/p' "$file" | tr ',' '\n' | tr -d '" ' | grep -E '^(update|clean|inventory|maintenance)$' || true
}

aicm_job_exists() {
  local job="$1"
  if [[ "$(aicm_os)" == mac ]]; then
    [[ -f "$HOME/Library/LaunchAgents/$AICM_LAUNCHD_PREFIX.$job.plist" ]] || return 1
    launchctl list 2>/dev/null | grep -q "$AICM_LAUNCHD_PREFIX.$job" || return 1
  else
    aicm_crontab -l 2>/dev/null | grep -q "# aicm:$job\$" || return 1
  fi
}

# Fails only when it can tell that no cron daemon runs (WSL starts none by default). Without pgrep and
# systemctl it cannot tell and succeeds.
aicm_cron_running() {
  local known=false
  if command -v pgrep >/dev/null 2>&1; then
    known=true
    pgrep -x cron >/dev/null 2>&1 && return 0
    pgrep -x crond >/dev/null 2>&1 && return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    known=true
    systemctl is-active --quiet cron 2>/dev/null && return 0
    systemctl is-active --quiet crond 2>/dev/null && return 0
  fi
  [[ "$known" == false ]]
}

# Prints one line per scheduled job that was installed but is now missing.
# Also flags a job that is registered but has not completed for too long (its script is gone, it keeps
# crashing, ...), once the schedule has existed that long. Second argument "nostale": existence only.
aicm_schedule_problems() {
  local skip="${1:-}" nostale="${2:-}" file="$AICM_HOME/state/schedule.json" job state limit
  [[ -f "$file" ]] || return 0
  local job_path tool
  # node and npm found at install time must still be found with the PATH the jobs get.
  job_path="$(aicm_json_field "$file" path)"
  if [[ -n "$job_path" ]]; then
    for tool in node npm; do
      grep -q "\"$tool\":\"" "$file" || continue
      # shellcheck disable=SC2016 # $1 is expanded by the inner sh
      if ! env PATH="$job_path" sh -c 'command -v "$1"' _ "$tool" >/dev/null 2>&1; then
        echo "$tool was found when the schedule was installed but the scheduled jobs no longer find it; reinstall it or run: aicm schedule install"
      fi
    done
  fi
  if [[ "$(aicm_os)" == linux && -n "$(aicm_scheduled_jobs)" ]] && ! aicm_cron_running; then
    echo "cron is not running, so the scheduled jobs never start; start it (sudo service cron start) and have it start at boot (on WSL: [boot] command in /etc/wsl.conf)"
  fi
  for job in $(aicm_scheduled_jobs); do
    [[ "$job" == "$skip" ]] && continue
    if ! aicm_job_exists "$job"; then echo "scheduled job '$job' is missing; run: aicm schedule install"; continue; fi
    [[ "$nostale" == nostale ]] && continue
    case "$job" in update) state="last-update"; limit=3 ;; inventory) state="inventory"; limit=9 ;; maintenance) state="last-maintenance"; limit=1 ;; *) state="last-clean"; limit=9 ;; esac
    # schedule.json older than the limit and the job's state missing or older than the limit.
    if [[ -n "$(find "$file" -mmin +"$((limit * 1440))" 2>/dev/null)" ]] &&
       { [[ ! -f "$AICM_HOME/state/$state.json" ]] || [[ -n "$(find "$AICM_HOME/state/$state.json" -mmin +"$((limit * 1440))" 2>/dev/null)" ]]; }; then
      echo "scheduled job '$job' has not completed for over $limit days; see $AICM_HOME/logs"
    fi
  done
}

# ---------------------------------------------------------------------------
# Running CLIs and the AI CLI catalog
# ---------------------------------------------------------------------------

# Perl fallback for aicm_timeout (macOS has no timeout(1)). The command runs in its own process group,
# and on timeout the whole group gets TERM, then KILL: a hanging postinstall started by npm dies too,
# not only npm itself. Ctrl-C / TERM sent to the wrapper are passed on to the group.
# shellcheck disable=SC2016 # perl code, not shell
AICM_TIMEOUT_PERL='
my $secs = shift;
my $pid = fork;
defined $pid or die "fork: $!\n";
if (!$pid) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127; }
setpgrp($pid, $pid);
my $timed_out = 0;
sub stop_group { kill "TERM", -$pid, $pid; for (1 .. 20) { last unless kill 0, -$pid; select undef, undef, undef, 0.25 } kill "KILL", -$pid, $pid; }
$SIG{ALRM} = sub { $timed_out = 1; stop_group(); };
$SIG{INT} = $SIG{TERM} = sub { stop_group(); exit 130; };
alarm $secs;
waitpid $pid, 0;
my $status = $?;
alarm 0;
if ($timed_out) { kill "KILL", -$pid; exit 124; }
exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
'

# aicm_timeout SECONDS CMD ARGS...: exit 124 when the command runs too long. Whatever the command
# started is stopped with it (GNU timeout signals its process group; the perl fallback does the same).
# AICM_TIMEOUT_TOOL=perl forces the perl fallback (tests).
AICM_TIMEOUT_GNU=""
aicm_timeout() {
  local secs="$1"; shift
  if command -v node >/dev/null 2>&1 && [[ "${AICM_TIMEOUT_TOOL:-}" != perl && "${AICM_CONTAINED:-}" == 1 && "${AI_CLI_MANAGER_SESSION:-}" =~ ^[a-f0-9-]{36}$ ]]; then
    node "$AICM_ROOT/lib/supervise.js" --timeout "$secs" -- "$@"
  elif [[ "${AICM_TIMEOUT_TOOL:-}" != perl ]] && command -v timeout >/dev/null 2>&1; then
    # -k: KILL 10 seconds after TERM when the command ignores TERM (GNU coreutils only).
    if [[ -z "$AICM_TIMEOUT_GNU" ]]; then
      if timeout --version 2>/dev/null | grep -q GNU; then AICM_TIMEOUT_GNU=yes; else AICM_TIMEOUT_GNU=no; fi
    fi
    if [[ "$AICM_TIMEOUT_GNU" == yes ]]; then timeout -k 10 "$secs" "$@"; else timeout "$secs" "$@"; fi
  elif [[ "${AICM_TIMEOUT_TOOL:-}" != perl ]] && command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 10 "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e "$AICM_TIMEOUT_PERL" "$secs" "$@"
  else
    "$@"
  fi
}

aicm_semver() {
  grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?([-+][0-9A-Za-z.-]+)?' | head -n 1
}

# Succeeds when version $1 is older than $2. Semver order: the dotted numbers first (missing parts
# count as 0), then a prerelease (2.0.0-beta.3) is older than its release (2.0.0); two prereleases
# compare part by part, numbers numerically and below words. Build metadata (+x) is ignored.
aicm_version_older() {
  local a="${1%%+*}" b="${2%%+*}"
  a="${a#v}"; b="${b#v}"
  [[ -n "$a" && -n "$b" && "$a" != "$b" ]] || return 1
  [[ "$a" =~ ^[0-9]+(\.[0-9]+)*(-.+)?$ && "$b" =~ ^[0-9]+(\.[0-9]+)*(-.+)?$ ]] || return 1
  awk -v a="$a" -v b="$b" '
    function pre(v) { i = index(v, "-"); return i ? substr(v, i + 1) : "" }
    function num(v) { i = index(v, "-"); return i ? substr(v, 1, i - 1) : v }
    BEGIN {
      n = split(num(a), x, "."); m = split(num(b), y, "."); k = (n > m) ? n : m
      for (i = 1; i <= k; i++) { xi = x[i] + 0; yi = y[i] + 0; if (xi < yi) exit 0; if (xi > yi) exit 1 }
      ra = pre(a); rb = pre(b)
      if (ra == rb) exit 1
      if (ra == "") exit 1
      if (rb == "") exit 0
      n = split(ra, x, "."); m = split(rb, y, "."); k = (n > m) ? n : m
      for (i = 1; i <= k; i++) {
        if (i > n) exit 0
        if (i > m) exit 1
        dx = (x[i] ~ /^[0-9]+$/); dy = (y[i] ~ /^[0-9]+$/)
        if (dx && dy) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1; continue }
        if (dx) exit 0
        if (dy) exit 1
        if (x[i] < y[i]) exit 0
        if (x[i] > y[i]) exit 1
      }
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

# ---------------------------------------------------------------------------
# Per-CLI update policies ($AICM_HOME/update-policy.json)
#   Node.js is required only when the file exists. Validation happens before the updater creates a
#   log, lock or state file, so a broken policy never starts a run.
#   AICM_POLICY_PRESENT   true when the file exists (even with no rules)
#   AICM_POLICY_FINGERPRINT  deterministic policy + global age baseline ("none:<age>" without a file)
# ---------------------------------------------------------------------------
AICM_POLICY_PRESENT=false
AICM_POLICY_FINGERPRINT=""
AICM_POLICY_ID=(); AICM_POLICY_EXCLUDE=(); AICM_POLICY_PIN=(); AICM_POLICY_AGE=(); AICM_POLICY_EFF=()

aicm_policy_reset() {
  AICM_POLICY_ID=(); AICM_POLICY_EXCLUDE=(); AICM_POLICY_PIN=(); AICM_POLICY_AGE=(); AICM_POLICY_EFF=()
}

# Reads and validates the policy. Expects aicm_load_catalog to have run when the file exists.
# Returns 0 (no file or valid), 1 (invalid policy) or 2 (Node.js required but missing).
aicm_policy_load() { # global-age-days
  local age="${1:-3}" file="$AICM_HOME/update-policy.json" out rc=0 ids="" i kind a b c d e idx
  local saw_schema=false saw_fingerprint=false
  aicm_policy_reset
  AICM_POLICY_FINGERPRINT="none:${age}"
  if [[ ! -e "$file" && ! -L "$file" ]]; then AICM_POLICY_PRESENT=false; return 0; fi
  # A directory or a dangling symlink is a broken policy location, not an absent file: fail closed.
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    echo "update policy: $file exists but is not a readable file" >&2
    return 1
  fi
  AICM_POLICY_PRESENT=true
  if ! command -v node >/dev/null 2>&1; then
    echo "update policy: $file exists but Node.js is required to read it" >&2
    return 2
  fi
  for ((i = 0; i < ${#AICM_CLI_ID[@]}; i++)); do
    [[ -n "${AICM_CLI_ID[$i]}" ]] || continue
    ids+="${ids:+,}${AICM_CLI_ID[$i]}"
  done
  out="$(node "$AICM_ROOT/lib/update-policy.js" load --file "$file" --ids "$ids" --global-age "$age" 2>&1)" || rc=$?
  if ((rc != 0)); then
    echo "update policy: ${out:-invalid policy file}" >&2
    return 1
  fi
  while IFS=$'\t' read -r kind a b c d e; do
    case "$kind" in
      schema)
        [[ "$a" == 1 ]] || { echo "update policy: unexpected schema version '$a'" >&2; return 1; }
        saw_schema=true
        ;;
      fingerprint)
        [[ "$a" =~ ^[0-9a-f]{64}$ ]] || { echo "update policy: invalid fingerprint" >&2; return 1; }
        AICM_POLICY_FINGERPRINT="policy:$a"
        saw_fingerprint=true
        ;;
      rule)
        [[ "$a" =~ ^[a-z0-9][a-z0-9-]*$ && "$b" =~ ^[01]$ ]] || { echo "update policy: invalid rule output" >&2; return 1; }
        if idx="$(aicm_policy_index "$a")"; then :; else idx=${#AICM_POLICY_ID[@]}; fi
        AICM_POLICY_ID[idx]="$a"
        AICM_POLICY_EXCLUDE[idx]="$b"
        AICM_POLICY_PIN[idx]="$([[ "$c" == - ]] && printf '' || printf '%s' "$c")"
        AICM_POLICY_AGE[idx]="$([[ "$d" == - ]] && printf '' || printf '%s' "$d")"
        AICM_POLICY_EFF[idx]="$e"
        ;;
      "")
        ;;
      *)
        echo "update policy: unexpected output '$kind'" >&2
        return 1
        ;;
    esac
  done <<< "$out"
  # Empty or truncated output is not a valid policy even when the reader exits 0.
  if [[ "$saw_schema" != true || "$saw_fingerprint" != true ]]; then
    echo "update policy: incomplete output from the policy reader" >&2
    return 1
  fi
  return 0
}

aicm_policy_index() { # id -> index
  local id="$1" i
  [[ "$id" == gpt ]] && id=codex
  for ((i = 0; i < ${#AICM_POLICY_ID[@]}; i++)); do
    [[ "${AICM_POLICY_ID[$i]}" == "$id" ]] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

aicm_policy_excluded() {
  local i
  i="$(aicm_policy_index "$1")" || return 1
  [[ "${AICM_POLICY_EXCLUDE[$i]}" == 1 ]]
}

aicm_policy_pin() {
  local i
  i="$(aicm_policy_index "$1")" || return 0
  printf '%s' "${AICM_POLICY_PIN[$i]}"
}

# The explicit per-tool age, empty when the global baseline applies.
aicm_policy_explicit_age() {
  local i
  i="$(aicm_policy_index "$1")" || return 0
  printf '%s' "${AICM_POLICY_AGE[$i]}"
}

# The age the npm route must enforce for this tool.
aicm_policy_effective_age() { # id global
  local explicit
  explicit="$(aicm_policy_explicit_age "$1")"
  if [[ -n "$explicit" ]]; then printf '%s' "$explicit"; else printf '%s' "${2:-0}"; fi
}

# True when a policy rule (any rule) is configured; used to preserve npm backups for excluded tools.
aicm_policy_has_rules() { ((${#AICM_POLICY_ID[@]} > 0)); }

# A pin/positive age cannot be enforced by a non-npm install owner. Prints the hold reason or nothing.
aicm_policy_route_hold() { # id method
  local id="$1" method="$2" pin age
  pin="$(aicm_policy_pin "$id")"
  if [[ -n "$pin" && "$method" != npm ]]; then
    printf 'update policy pins %s to %s, which requires the npm install route; the active copy is managed by %s, so no update was attempted' "$id" "$pin" "${method:-an unknown route}"
    return 0
  fi
  age="$(aicm_policy_explicit_age "$id")"
  if [[ -n "$age" && "$age" -gt 0 && "$method" != npm ]]; then
    printf 'update policy sets minReleaseAgeDays=%s for %s, which cannot be enforced for %s installs; no update was attempted' "$age" "$id" "${method:-an unknown route}"
    return 0
  fi
  return 0
}

# Validates an exact pin against the registry. Prints a hold reason, or nothing when it may be installed.
# Returns 1 when the registry data could not be read (the caller treats that like other registry errors).
aicm_policy_validate_pin() { # package pin age [amp]
  local pkg="$1" pin="$2" age="$3" amp="${4:-}" f out rc=0 why
  f="$(aicm_npm_view_file "$pkg" name time dist-tags versions)" || { echo "could not read the release list of $pkg"; return 1; }
  out="$(node "$AICM_ROOT/lib/update-policy.js" pin-check --file "$f" --pin "$pin" --age "$age" ${amp:+--amp} 2>&1)" || rc=$?
  rm -f "$f"
  if ((rc != 0)); then
    printf '%s' "${out#error: }"
    return 0
  fi
  why="$(AICM_NPM_TIMEOUT=60 aicm_npm view "$pkg@$pin" deprecated 2>/dev/null)" || {
    echo "could not read the deprecation state of $pkg@$pin"
    return 1
  }
  if [[ -n "${why//[[:space:]]/}" ]]; then
    printf 'pinned version %s is deprecated (%s)' "$pin" "$why"
  fi
  return 0
}

AICM_NPM_CMD="${NPM:-$(command -v npm 2>/dev/null || true)}"
AICM_NPM_PREFIX_CACHE=""; AICM_NPM_ROOT_CACHE=""; AICM_NPM_CACHED=false

aicm_npm_cache() {
  [[ "$AICM_NPM_CACHED" == true ]] && return 0
  AICM_NPM_CACHED=true
  [[ -n "$AICM_NPM_CMD" ]] && command -v "$AICM_NPM_CMD" >/dev/null 2>&1 || return 0
  AICM_NPM_PREFIX_CACHE="$(aicm_timeout 30 "$AICM_NPM_CMD" prefix -g 2>/dev/null | head -n 1 || true)"
  AICM_NPM_ROOT_CACHE="$(aicm_timeout 30 "$AICM_NPM_CMD" root -g 2>/dev/null | head -n 1 || true)"
  # Git Bash on Windows: npm prints C:/... while command -v prints /c/... or /tmp/...; use one form.
  if command -v cygpath >/dev/null 2>&1; then
    [[ -n "$AICM_NPM_PREFIX_CACHE" ]] && AICM_NPM_PREFIX_CACHE="$(cygpath -u "$AICM_NPM_PREFIX_CACHE")"
    [[ -n "$AICM_NPM_ROOT_CACHE" ]] && AICM_NPM_ROOT_CACHE="$(cygpath -u "$AICM_NPM_ROOT_CACHE")"
  fi
  return 0
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
  local brew="${BREW:-brew}"
  if [[ "$AICM_BREW_PREFIX_CACHE" == unset ]]; then
    AICM_BREW_PREFIX_CACHE=""
    command -v "$brew" >/dev/null 2>&1 && AICM_BREW_PREFIX_CACHE="$("$brew" --prefix 2>/dev/null || true)"
  fi
  printf '%s' "$AICM_BREW_PREFIX_CACHE"
}

# Candidate npm packages for catalog index $1: canonical first, then known aliases.
# Amp: @ampcode/cli is current; @sourcegraph/amp remains installed on some machines.
aicm_cli_npm_names() {
  local i="$1" npm
  npm="${AICM_CLI_NPM[$i]}"
  [[ -n "$npm" ]] && printf '%s\n' "$npm"
  case "${AICM_CLI_ID[$i]}:$npm" in
    amp:@ampcode/cli|amp:@sourcegraph/amp)
      [[ "$npm" != "@ampcode/cli" ]] && printf '%s\n' "@ampcode/cli"
      [[ "$npm" != "@sourcegraph/amp" ]] && printf '%s\n' "@sourcegraph/amp"
      ;;
    opencode:@opencode/cli|opencode:opencode-ai)
      [[ "$npm" != "@opencode/cli" ]] && printf '%s\n' "@opencode/cli"
      [[ "$npm" != opencode-ai ]] && printf '%s\n' opencode-ai
      ;;
  esac
  # This is a list producer: a false final alias condition is not a failed listing.
  return 0
}

# Package whose install folder owns the resolved command, empty when none does.
aicm_cli_npm_owner() {
  local i="$1" real="$2" pkg pkg_real root npm_names
  [[ -n "$real" ]] || return 0
  aicm_npm_cache
  root="$AICM_NPM_ROOT_CACHE"
  [[ -n "$root" ]] || return 0
  npm_names="$(aicm_cli_npm_names "$i")" || true
  while IFS= read -r pkg; do
    [[ -n "$pkg" && -e "$root/$pkg" ]] || continue
    pkg_real="$(aicm_realpath "$root/$pkg")"
    [[ -n "$pkg_real" ]] || continue
    if [[ "$real" == "$pkg_real" || "$real" == "$pkg_real/"* ]]; then
      printf '%s' "$pkg"
      return 0
    fi
  done <<< "$npm_names"
}

# Package whose npm install owns a launcher placed directly in npm's prefix/bin. A real npm launcher
# is a symlink into the package (or a small script that references its node_modules folder). A
# standalone executable or wrapper in the same prefix is not npm-owned, even when npm has a hidden
# copy of the same CLI. The file is read, never executed; a real package reference still identifies an
# interrupted install whose package folder is currently missing.
aicm_npm_prefix_shim_owner() { # catalog-index path
  local i="$1" path="$2" pkg link size npm_names
  aicm_npm_cache
  [[ -n "$path" && -n "$AICM_NPM_PREFIX_CACHE" && "$path" == "$AICM_NPM_PREFIX_CACHE/bin/"* ]] || return 0
  npm_names="$(aicm_cli_npm_names "$i")" || true
  if [[ -L "$path" ]]; then
    link="$(readlink "$path" 2>/dev/null || true)"
    [[ -n "$link" ]] || return 0
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      case "$link" in
        *"node_modules/$pkg/"*) printf '%s' "$pkg"; return 0 ;;
      esac
      if [[ -n "$AICM_NPM_ROOT_CACHE" && "$link" == *"$AICM_NPM_ROOT_CACHE/$pkg"* ]]; then
        printf '%s' "$pkg"; return 0
      fi
    done <<< "$npm_names"
    return 0
  fi
  [[ -f "$path" ]] || return 0
  size="$(wc -c < "$path" 2>/dev/null | tr -d ' ' || true)"
  [[ "$size" =~ ^[0-9]+$ && "$size" -le 65536 ]] || return 0
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if grep -Fq -- "node_modules/$pkg/" "$path" 2>/dev/null; then printf '%s' "$pkg"; return 0; fi
    if [[ -n "$AICM_NPM_ROOT_CACHE" ]] && grep -Fq -- "$AICM_NPM_ROOT_CACHE/$pkg" "$path" 2>/dev/null; then
      printf '%s' "$pkg"; return 0
    fi
  done <<< "$npm_names"
}

# First installed candidate (canonical, then aliases).
aicm_cli_npm_installed() {
  local i="$1" pkg npm_names
  npm_names="$(aicm_cli_npm_names "$i")" || true
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if [[ -n "$(aicm_npm_pkg_version "$pkg")" ]]; then
      printf '%s' "$pkg"
      return 0
    fi
  done <<< "$npm_names"
}

# Sets CLI_INSTALLED CLI_PATH CLI_METHOD (npm|brew|standalone) CLI_NPMCOPY CLI_NPMPKG for catalog index $1.
# CLI_NPMPKG is the package inventory and the updater use for this copy (PATH owner when both exist).
aicm_cli_install() {
  local i="$1" cmd npm_version real npm_root_real owner installed_npm
  CLI_INSTALLED=false; CLI_PATH=""; CLI_METHOD=""; CLI_NPMCOPY=""; CLI_NPMPKG=""
  cmd="${AICM_CLI_CMD[$i]}"
  [[ -n "$cmd" ]] || return 0
  installed_npm="$(aicm_cli_npm_installed "$i")"
  CLI_NPMPKG="${installed_npm:-${AICM_CLI_NPM[$i]}}"
  npm_version="$(aicm_npm_pkg_version "$CLI_NPMPKG")"
  CLI_PATH="$(command -v "$cmd" 2>/dev/null || true)"
  if [[ -z "$CLI_PATH" ]]; then
    if [[ -n "$npm_version" ]]; then CLI_INSTALLED=true; CLI_METHOD=npm; CLI_PATH="(npm package, command not on PATH)"; fi
    return 0
  fi
  CLI_INSTALLED=true
  real="$(aicm_realpath "$CLI_PATH")"
  aicm_npm_cache
  owner="$(aicm_cli_npm_owner "$i" "$real")"
  [[ -z "$owner" ]] && owner="$(aicm_npm_prefix_shim_owner "$i" "$CLI_PATH")"
  [[ -n "$owner" ]] && CLI_NPMPKG="$owner"
  npm_version="$(aicm_npm_pkg_version "$CLI_NPMPKG")"
  npm_root_real=""
  [[ -n "$AICM_NPM_ROOT_CACHE" ]] && npm_root_real="$(aicm_realpath "$AICM_NPM_ROOT_CACHE")"
  # Proven ownership first: the resolved file in npm's node_modules, or Homebrew Cellar/Caskroom.
  # A launcher in npm's prefix/bin only counts when it is a symlink into the package or a small shim
  # that references its node_modules folder, so a standalone /usr/local/bin/agy is not npm (or brew)
  # just because prefixes overlap or a hidden npm copy exists.
  if [[ -n "$npm_root_real" && "$real" == "$npm_root_real/"* ]]; then
    CLI_METHOD=npm
  elif [[ "$real" == */Cellar/* || "$real" == */Caskroom/* ]]; then
    CLI_METHOD=brew
  elif [[ -n "$owner" ]]; then
    CLI_METHOD=npm
  else
    CLI_METHOD=standalone
  fi
  [[ "$CLI_METHOD" != npm && -n "$npm_version" ]] && CLI_NPMCOPY="$npm_version"
  return 0
}

# How to get rid of a second copy that hides behind (or in front of) the one on PATH.
aicm_shadow_fix() {
  aicm_npm_cache
  printf 'fix: keep one copy - uninstall the npm copy, or put %s/bin before %s in PATH so the daily-updated npm copy is the one that runs.' \
    "${AICM_NPM_PREFIX_CACHE:-<npm prefix>}" "$(dirname "$1")"
}

# True when the codex on PATH comes from the official installer, which `codex update` keeps current.
aicm_codex_standalone() {
  [[ "$(aicm_realpath "$1")" == */packages/standalone/* ]]
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
      if aicm_is_builtin "$id" && [[ -n "$CLI_NPMCOPY" && "$id" == kimi ]]; then
        echo "no: the update refreshes the npm copy, not the one on PATH"
      elif [[ -n "${AICM_CLI_SELF[$i]}" ]]; then echo yes
      elif [[ "$id" == codex ]] && aicm_codex_standalone "$CLI_PATH"; then echo yes
      elif [[ -n "${AICM_CLI_NOTE[$i]}" ]]; then echo "no: ${AICM_CLI_NOTE[$i]}"
      else echo "no: installed standalone without a self-update command"; fi ;;
    *) echo no ;;
  esac
}

# ---------------------------------------------------------------------------
# Release checks for npm installs (logic in lib/npm-guard.js, shared with Windows)
#   AICM_MIN_RELEASE_AGE_DAYS  only install versions at least this old (default 3, 0 = newest)
#   AICM_VERIFY_SIGNATURES     0 skips the staged `npm audit signatures` check (default on)
#   AICM_ALLOW                 comma list of pkg@version accepted despite red flags
# ---------------------------------------------------------------------------

aicm_min_release_age_days() {
  if [[ "${AICM_MIN_RELEASE_AGE_DAYS:-}" =~ ^[0-9]+$ ]]; then echo "$AICM_MIN_RELEASE_AGE_DAYS"; else echo 3; fi
}

aicm_npm() { aicm_timeout "${AICM_NPM_TIMEOUT:-900}" "${NPM:-$AICM_NPM_CMD}" "$@"; }

# Writes `npm view <args> --json` to a temp file and prints its path.
aicm_npm_view_file() {
  local f
  f="$(mktemp)"
  if ! AICM_NPM_TIMEOUT=90 aicm_npm view "$@" --json > "$f" 2>/dev/null; then rm -f "$f"; return 1; fi
  echo "$f"
}

# Root of a global package, the scope folder for @scope/name.
aicm_npm_pkg_parent() { # pkg -> parent folder of its install folder
  aicm_npm_cache
  [[ -n "$AICM_NPM_ROOT_CACHE" ]] || return 1
  if [[ "$1" == */* ]]; then printf '%s/%s' "$AICM_NPM_ROOT_CACHE" "${1%%/*}"; else printf '%s' "$AICM_NPM_ROOT_CACHE"; fi
}

# npm's backup of a package it was replacing ([@scope/].<name>-XXXXXXXX with a package.json), left
# behind when the install was interrupted. Prints its path; fails when there is none.
aicm_npm_backup() { # pkg
  local parent name d
  parent="$(aicm_npm_pkg_parent "$1")" || return 1
  name="${1##*/}"
  for d in "$parent/.$name-"????????; do
    [[ -d "$d" && ! -L "$d" && -f "$d/package.json" ]] || continue
    [[ "${d##*/}" =~ ^\.[^/]+-[A-Za-z0-9]{8}$ ]] || continue
    printf '%s\n' "$d"
    return 0
  done
  return 1
}

# npm leaves folders named node_modules/.<name>-XXXXXXXX behind when an install stops half way: its
# staging folder, or its backup of the copy it was replacing. Removes those older than a day, but only
# while <name> itself is installed (has a package.json): otherwise the leftover may be the only good
# copy of a CLI whose install was cut off. rm -rf removes links inside as links; it never follows them.
aicm_npm_leftovers() {
  aicm_npm_cache
  # A backup folder can be the only copy of a CLI whose policy excludes updates or pins a version.
  # While any policy rule is configured, skip the global housekeeping rather than guess which
  # leftovers are policy-protected.
  if [[ "${AICM_POLICY_PRESENT:-false}" == true ]] && ((${#AICM_POLICY_ID[@]} > 0)); then
    echo "pass: npm leftover cleanup skipped while update policy is configured"
    return 0
  fi
  local root="$AICM_NPM_ROOT_CACHE" d name owner
  [[ -n "$root" && -d "$root" && ! -L "$root" ]] || return 0
  while IFS= read -r -d '' d; do
    name="$(basename "$d")"
    [[ "$name" =~ ^\.[^.].*-[A-Za-z0-9]{8}$ ]] || continue
    owner="${name#.}"; owner="${owner%-*}"
    if [[ ! -f "$(dirname "$d")/$owner/package.json" ]]; then
      echo "kept npm leftover $d ($owner is not installed; this may be its only copy)"
      continue
    fi
    if rm -rf -- "${d:?}" 2>/dev/null; then echo "removed npm leftover $d"; else echo "kept npm leftover $d (in use)"; fi
  done < <(find "$root" -mindepth 1 -maxdepth 2 -type d -name '.*-*' -mmin +1440 -print0 2>/dev/null)
  return 0
}

# The version to install: the newest stable release at least N days old (empty when none is).
# Unpublished versions never count. With an installed version as $3 (the updater), deprecated
# releases newer than it are passed over; when every newer one is deprecated, $3 is printed.
# Notes go to stderr: callers read the version from stdout.
aicm_npm_target() { # pkg days [installed skip-deprecated]
  local pkg="$1" days="$2" installed="${3:-}" skipdep="${4:-}" f out v why checked=0
  if ((days <= 0)) && [[ -z "$skipdep" ]]; then
    AICM_NPM_TIMEOUT=60 aicm_npm view "$pkg" version 2>/dev/null | aicm_semver || true
    return 0
  fi
  ((days < 0)) && days=0
  f="$(aicm_npm_view_file "$pkg" name time dist-tags versions)" || return 1
  out="$(node "$AICM_ROOT/lib/npm-guard.js" candidates "$days" "$f")" || { rm -f "$f"; return 1; }
  rm -f "$f"
  if [[ -z "$skipdep" ]]; then printf '%s\n' "$out" | head -n 1; return 0; fi
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    if [[ -n "$installed" ]] && ! aicm_version_older "$installed" "$v"; then printf '%s\n' "$v"; return 0; fi
    ((checked >= 5)) && break
    checked=$((checked + 1))
    why="$(AICM_NPM_TIMEOUT=60 aicm_npm view "$pkg@$v" deprecated 2>/dev/null)" || return 1
    if [[ -z "${why//[[:space:]]/}" ]]; then printf '%s\n' "$v"; return 0; fi
    echo "skip: $pkg@$v is deprecated ($why)" >&2
  done <<< "$out"
  [[ -n "$installed" ]] && printf '%s\n' "$installed"
  return 0
}

# --before=<now minus the waiting period>: npm then resolves the dependencies, too, to versions published
# before that moment, so the waiting period covers them (their install scripts run in the real install).
# Prints nothing when there is no waiting period.
aicm_npm_before() { # days
  [[ "${1:-0}" =~ ^[0-9]+$ ]] && (($1 > 0)) || return 0
  node -e 'console.log("--before=" + new Date(Date.now() - Number(process.argv[1]) * 86400000).toISOString())' "$1"
}

# Signature verdicts per package@version, kept for the day, so the scheduled retries do not download
# and stage the same release again. Values: ok | unverifiable | bad: <summary>.
aicm_npm_verdict() { # spec
  local file="$AICM_HOME/state/npm-verdicts.tsv"
  [[ -f "$file" ]] || return 0
  D="$(date +%Y-%m-%d)" S="$1" awk -F '\t' '$1 == ENVIRON["D"] && $2 == ENVIRON["S"] { print $3; exit }' "$file"
}

aicm_npm_verdict_set() { # spec verdict
  local file="$AICM_HOME/state/npm-verdicts.tsv" today
  today="$(date +%Y-%m-%d)"
  mkdir -p "$AICM_HOME/state"
  {
    [[ -f "$file" ]] && D="$today" S="$1" awk -F '\t' '$1 == ENVIRON["D"] && $2 != ENVIRON["S"]' "$file"
    printf '%s\t%s\t%s\n' "$today" "$1" "${2//$'\t'/ }"
  } > "$file.$$.tmp" && mv -f "$file.$$.tmp" "$file"
}

# Notes for the caller's attention list (stable texts, so they are announced once a week at most).
AICM_NPM_NOTES=()
AICM_NOKEYS_NOTE="the npm registry publishes no signing keys (a private registry?), so release signatures cannot be checked; updates go on without that check. Set AICM_VERIFY_SIGNATURES=0 to skip it"
aicm_npm_note() {
  local n
  for n in ${AICM_NPM_NOTES[@]+"${AICM_NPM_NOTES[@]}"}; do [[ "$n" == "$1" ]] && return 0; done
  AICM_NPM_NOTES+=("$1")
}

# Fails when the candidate looks unlike the installed release or fails the registry signature check.
aicm_npm_check() { # pkg installed target [min-age-days]
  local pkg="$1" installed="$2" target="$3" days="${4:-}" old new flags stage summary rc verdict before
  [[ -n "$days" ]] || days="$(aicm_min_release_age_days)"
  if [[ -n "$installed" ]]; then
    old="$(aicm_npm_view_file "$pkg@$installed")" || { echo "could not read $pkg@$installed from the registry"; return 1; }
    new="$(aicm_npm_view_file "$pkg@$target")" || { rm -f "$old"; echo "could not read $pkg@$target from the registry"; return 1; }
    flags="$(node "$AICM_ROOT/lib/npm-guard.js" compare "$old" "$new")" || { rm -f "$old" "$new"; echo "npm-guard failed"; return 1; }
    rm -f "$old" "$new"
    if [[ -n "$flags" ]]; then
      printf '%s\n' "$flags" | sed "s|^|red flag: $pkg |"
      if [[ ",${AICM_ALLOW:-}," != *",$pkg@$target,"* ]]; then
        echo "blocked $pkg@$target. If this is expected, set AICM_ALLOW=$pkg@$target"
        return 1
      fi
    fi
  fi
  [[ "${AICM_VERIFY_SIGNATURES:-1}" == 0 ]] && return 0
  verdict="$(aicm_npm_verdict "$pkg@$target")"
  case "$verdict" in
    ok) echo "signatures ok (checked earlier today): $pkg@$target"; return 0 ;;
    unverifiable) echo "signatures not checkable (checked earlier today): $pkg@$target"; aicm_npm_note "$AICM_NOKEYS_NOTE"; return 0 ;;
    bad:*) echo "signature check failed for $pkg@$target (checked earlier today): ${verdict#bad: }"; return 1 ;;
  esac
  before="$(aicm_npm_before "$days")"
  stage="$(mktemp -d)"
  # --ignore-scripts: nothing from the candidate runs before it has passed the checks.
  if ! aicm_npm install "$pkg@$target" --prefix "$stage" --ignore-scripts --no-audit --no-fund --loglevel=error ${before:+"$before"} >/dev/null 2>&1; then
    rm -rf "$stage"; echo "staged install of $pkg@$target failed"; return 1
  fi
  rc=0
  summary="$(AICM_NPM_TIMEOUT=300 aicm_npm audit signatures --prefix "$stage" 2>&1)" || rc=$?
  rm -rf "$stage"
  summary="$(printf '%s\n' "$summary" | awk 'NF' | paste -sd '/' -)"
  if ((rc == 0)); then
    aicm_npm_verdict_set "$pkg@$target" ok
    echo "signatures ok: $summary"
    return 0
  fi
  # A registry without signing keys (Verdaccio and other private registries): nothing can be checked.
  if [[ "$summary" == *"installed from a supported registry"* ]]; then
    aicm_npm_verdict_set "$pkg@$target" unverifiable
    echo "warn: signatures not checkable for $pkg@$target: $summary"
    aicm_npm_note "$AICM_NOKEYS_NOTE"
    return 0
  fi
  # Remember a real signature problem for the day; other errors (network) are tried again next run.
  if printf '%s' "$summary" | grep -Eiq '(invalid|missing).*signature'; then aicm_npm_verdict_set "$pkg@$target" "bad: $summary"; fi
  echo "signature check failed for $pkg@$target: $summary"
  return 1
}

# ---------------------------------------------------------------------------
# Node.js modules (worktrees, config drift, processes), shared with Windows
# ---------------------------------------------------------------------------

# Runs lib/<module>.js and prints its output; the output without attention lines is left in
# AICM_NODE_OUTPUT and the "attention:" lines in AICM_NODE_ATTENTION.
AICM_NODE_ATTENTION=(); AICM_NODE_OUTPUT=""
aicm_node_module() { # module args...
  local module="$1" out rc=0 line
  shift
  AICM_NODE_ATTENTION=(); AICM_NODE_OUTPUT=""
  if ! command -v node >/dev/null 2>&1; then echo "$module: Node.js not found, skipped"; return 0; fi
  out="$(aicm_timeout 900 node "$AICM_ROOT/lib/$module.js" "$@" 2>&1)" || rc=$?
  [[ -n "$out" ]] && printf '%s\n' "$out"
  AICM_NODE_OUTPUT="$(printf '%s\n' "$out" | grep -v '^attention: ' || true)"
  if ((rc != 0)); then AICM_NODE_ATTENTION=("$module failed with exit code $rc"); return 0; fi
  while IFS= read -r line; do
    [[ "$line" == "attention: "* ]] && AICM_NODE_ATTENTION+=("${line#attention: }")
  done <<< "$out"
  return 0
}

# Place the whole manager invocation in a guarded session; direct CLI calls inherit its marker.
# Version/help/scheduler commands do not launch AI CLIs and need no boundary.
aicm_contain_script() {
  [[ "${AICM_CONTAINED:-}" == 1 && "${AI_CLI_MANAGER_SESSION:-}" =~ ^[a-f0-9-]{36}$ ]] && return 0
  command -v node >/dev/null 2>&1 || { echo "AI CLI process containment needs Node.js" >&2; exit 1; }
  exec node "$AICM_ROOT/lib/supervise.js" -- /bin/bash "$@"
}
