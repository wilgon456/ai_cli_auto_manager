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
  local p="$1" from_temp="${2:-0}" home temp in_temp=1
  home="${HOME%/}"
  temp="$(aicm_temp_dir)"
  case "/$p/" in
    */../*|*/./*) return 1 ;;
  esac
  # No home folder (HOME unset or /) means no safe area at all.
  [[ -n "$home" ]] || return 1
  # The home folder itself, or anything above it, never.
  [[ "$home/" == "$p/"* ]] && return 1
  if [[ "$p" == "$temp" || "$p" == "$temp/"* ]] && aicm_temp_usable; then in_temp=0; fi
  [[ "$from_temp" == 1 ]] && return "$in_temp"
  ((in_temp == 0)) && return 0
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
    case "$kind" in age|age-files|cap|keep-latest|command|archive|codex) ;; *) echo "invalid rule kind '$kind' in $source: $line" >&2; return 1 ;; esac
    case "$default" in on|off) ;; *) echo "invalid default '$default' in $source: $line" >&2; return 1 ;; esac
    [[ -z "$days" || "$days" =~ ^[0-9]+$ ]] || { echo "invalid days in $source: $line" >&2; return 1; }
    [[ -z "$limit" || "$limit" =~ ^[0-9]+$ ]] || { echo "invalid limit in $source: $line" >&2; return 1; }
    if [[ "$kind" == age || "$kind" == age-files ]] && (( ${days:-0} < 1 )); then echo "$kind rule needs days >= 1 in $source: $line" >&2; return 1; fi
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

# Marks AICM_HOME as this tool's folder; `aicm uninstall --purge` removes only a marked folder (or
# the default one), so AICM_HOME=~/.config can never wipe ~/.config.
aicm_mark_home() {
  [[ -f "$AICM_HOME/.aicm-home" ]] && return 0
  mkdir -p "$AICM_HOME" 2>/dev/null && printf 'AI CLI Auto Manager home (logs, state, archive, installed copy)\n' > "$AICM_HOME/.aicm-home" 2>/dev/null
  return 0
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
  aicm_mark_home
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
  sed -n 's/.*"jobs":\[\([^]]*\)\].*/\1/p' "$file" | tr ',' '\n' | tr -d '" ' | grep -E '^(update|clean|inventory)$' || true
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
      if ! (PATH="$job_path"; command -v "$tool" >/dev/null 2>&1); then
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
    case "$job" in update) state="last-update"; limit=3 ;; inventory) state="inventory"; limit=9 ;; *) state="last-clean"; limit=9 ;; esac
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
  if [[ "${AICM_TIMEOUT_TOOL:-}" != perl ]] && command -v timeout >/dev/null 2>&1; then
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
  # npm only when it lives in npm's own global folder: pnpm, bun and volta also keep node_modules
  # folders, but `npm install -g` would only add a second copy that PATH does not run.
  if { [[ -n "$AICM_NPM_ROOT_CACHE" ]] && [[ "$real" == "$(aicm_realpath "$AICM_NPM_ROOT_CACHE")/"* ]]; } ||
     { [[ -n "$AICM_NPM_PREFIX_CACHE" ]] && [[ "$CLI_PATH" == "$AICM_NPM_PREFIX_CACHE/bin/"* ]]; }; then
    CLI_METHOD=npm
  elif [[ "$real" == */Cellar/* || "$real" == */Caskroom/* ]] || { [[ -n "$brew_prefix" ]] && [[ "$real" == "$brew_prefix/"* ]]; }; then
    CLI_METHOD=brew
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
  f="$(aicm_npm_view_file "$pkg" time dist-tags versions)" || return 1
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
