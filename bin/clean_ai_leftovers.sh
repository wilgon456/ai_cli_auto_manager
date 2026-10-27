#!/usr/bin/env bash
# Removes stale AI coding CLI leftovers (old transcripts, temp files, caches) on macOS and Linux.
#
# Rules come from rules/clean-rules.conf plus ~/.ai-cli-auto-manager/clean-rules.local.conf.
# Only files older than each rule's age are removed. Symlinks are never followed,
# protected files (memory, credentials, settings) are never removed.
set -Eeuo pipefail

ORIG_ARGS=("$@")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/aicm-common.sh
. "$SCRIPT_DIR/../lib/aicm-common.sh"

DRY_RUN=false
REPORT=false
JSON=false
EXPLAIN=false
SELECTED=""
CATEGORY=""
RULES_FILE="$AICM_ROOT/rules/clean-rules.conf"
LOCAL_RULES_FILE="$AICM_HOME/clean-rules.local.conf"
LOG_DIR="${AICM_LOG_DIR:-$AICM_HOME/logs}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--report] [--rules id,id] [--category list] [--json] [--explain]
       [--rules-file FILE] [--local-rules-file FILE]

  --dry-run    show what would be removed, change nothing
  --report     like --dry-run, also show each folder's total size
  --rules      run only these rule ids (runs them even if they are off)
  --category   sessions,cache,logs,temp,other or all (does not turn rules on)
  --json       one JSON document on stdout; messages go to stderr
  --explain    print each selected rule's reason, age and action; change nothing
EOF
}

while (($#)); do
  case "$1" in
    --dry-run|--check) DRY_RUN=true ;;
    --report) REPORT=true; DRY_RUN=true ;;
    --json) JSON=true ;;
    --explain) EXPLAIN=true ;;
    --rules) shift; SELECTED="${1:-}" ;;
    --rules=*) SELECTED="${1#--rules=}" ;;
    --category)
      shift
      [[ -n "${1:-}" ]] || { echo "--category needs a value" >&2; usage >&2; exit 2; }
      CATEGORY="$1"
      ;;
    --category=*)
      CATEGORY="${1#--category=}"
      [[ -n "$CATEGORY" ]] || { echo "--category needs a value" >&2; usage >&2; exit 2; }
      ;;
    --rules-file) shift; RULES_FILE="${1:-}" ;;
    --local-rules-file) shift; LOCAL_RULES_FILE="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ -n "$CATEGORY" ]]; then
  CATEGORY_NORM="$(aicm_normalize_categories "$CATEGORY")" || exit 2
else
  CATEGORY_NORM=""
fi
# A named subset limits the run. "all" and an omitted flag keep the full cleanup.
CAT_FILTER=false
[[ -n "$CATEGORY_NORM" && "$CATEGORY_NORM" != all ]] && CAT_FILTER=true
if [[ "$EXPLAIN" == true ]]; then DRY_RUN=true; fi

aicm_load_categories || exit 2
aicm_load_rules "$RULES_FILE" "$LOCAL_RULES_FILE" || exit 2

selected_has() {
  [[ -n "$SELECTED" ]] || return 1
  [[ ",${SELECTED// /}," == *",$1,"* ]]
}

# Category narrows --rules. Neither filter alone is the other. --rules turns on only named ids.
rule_included() { # id
  local id="$1" c
  if [[ -n "$SELECTED" ]] && ! selected_has "$id"; then return 1; fi
  if [[ "$CAT_FILTER" == true ]]; then
    c="$(aicm_rule_category "$id")"
    [[ ",$CATEGORY_NORM," == *",$c,"* ]] || return 1
  fi
  return 0
}

if [[ -n "$SELECTED" ]]; then
  IFS=',' read -r -a wanted <<< "${SELECTED// /}"
  for w in "${wanted[@]}"; do
    [[ -z "$w" ]] && continue
    if ! aicm_rule_index "$w" >/dev/null; then
      echo "unknown rule id: $w" >&2
      echo "known ids: ${AICM_RULE_ID[*]}" >&2
      exit 2
    fi
  done
fi

# Explain without --json is metadata only: no lock, log, state, marker or scan.
if [[ "$EXPLAIN" == true && "$JSON" != true ]]; then
  for ((i = 0; i < ${#AICM_RULE_ID[@]}; i++)); do
    id="${AICM_RULE_ID[$i]}"
    rule_included "$id" || continue
    en=false
    [[ "${AICM_RULE_ENABLED[$i]}" == 1 ]] && en=true
    if [[ -n "$SELECTED" ]] && selected_has "$id"; then en=true; fi
    kind="${AICM_RULE_KIND[$i]}"
    if [[ "$kind" == command ]]; then
      shown="${AICM_RULE_PATH[$i]}"
    else
      shown="$(aicm_display_path "$(aicm_expand_path "${AICM_RULE_PATH[$i]}")")"
    fi
    reason="$(aicm_rule_reason "$id" "$kind" "${AICM_RULE_DAYS[$i]}" "${AICM_RULE_NOTE[$i]}")"
    printf '%s\tcategory=%s\tenabled=%s\tage=%s\tlimit=%s\taction=%s\tprotection=%s\tpath=%s\treason=%s\n' \
      "$id" "$(aicm_rule_category "$id")" "$en" "${AICM_RULE_DAYS[$i]}" "${AICM_RULE_LIMIT[$i]}" \
      "$(aicm_rule_action "$kind" "${AICM_RULE_LIMIT[$i]}")" "$(aicm_protection_policy)" "$shown" "$reason"
  done
  exit 0
fi

MUTATING=true
[[ "$DRY_RUN" == true || "$REPORT" == true ]] && MUTATING=false

# A real cleanup claims (marks) the home before anything, the maintenance lock included, is written
# into it; a folder this tool did not create is refused untouched. A preview that writes a log only
# checks it. Explain/JSON previews and reports write nothing there.
home_refused() {
  if [[ "$JSON" == true ]]; then
    printf '%s\n' "{\"schemaVersion\":1,\"dryRun\":$DRY_RUN,\"status\":\"error\",\"categories\":[],\"rules\":[],\"summary\":{\"plannedBytes\":0,\"freedBytes\":0,\"archivedBytes\":0},\"errors\":[\"$(aicm_json_escape "AICM_HOME: $AICM_HOME_PROBLEM")\"]}"
  fi
  exit 1
}
if [[ "$MUTATING" == true ]]; then
  aicm_claim_home || home_refused
elif [[ "$JSON" != true && "$REPORT" != true ]]; then
  aicm_home_usable || home_refused
fi

# A real cleanup holds the maintenance lock when this copy can validate a lease.
# Previews never re-exec. An inherited env var is not a lease; leaseValid() is.
maintenance_lease_ready() {
  command -v node >/dev/null 2>&1 || return 1
  [[ -f "$AICM_ROOT/lib/maintenance.js" ]] || return 1
  node -e 'const fs=require("fs"); const p=process.argv[1]; const s=fs.readFileSync(p,"utf8"); const m=require(p); process.exit(s.indexOf("run-clean")>=0 && typeof m.leaseValid==="function"?0:1)' "$AICM_ROOT/lib/maintenance.js" >/dev/null 2>&1
}
if [[ "$MUTATING" == true ]] && maintenance_lease_ready; then
  if ! node -e 'process.exit(require(process.argv[1]).leaseValid()?0:1)' "$AICM_ROOT/lib/maintenance.js"; then
    exec node "$AICM_ROOT/lib/maintenance.js" run-clean -- /bin/bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
fi


# --json keeps stdout as one document. Human lines and the log go to stderr.
if [[ "$JSON" == true ]]; then
  exec 3>&1
  if [[ "$MUTATING" == true ]]; then
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/clean-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$LOG_FILE" >&2) 2>&1
  else
    exec >&2
  fi
fi

json_categories() {
  local cat_json="[]" c
  if [[ -n "$CATEGORY_NORM" ]]; then
    cat_json=""
    IFS=',' read -r -a cat_parts <<< "$CATEGORY_NORM"
    for c in "${cat_parts[@]}"; do cat_json+="${cat_json:+,}\"$c\""; done
    cat_json="[$cat_json]"
  fi
  printf '%s' "$cat_json"
}

# Early exit that still prints one JSON document when --json is set.
json_bail() { # status exit-code message
  local dry_json=false esc
  if [[ "$JSON" == true ]]; then
    [[ "$DRY_RUN" == true ]] && dry_json=true
    esc="$(aicm_json_escape "$3")"
    printf '%s\n' "{\"schemaVersion\":1,\"dryRun\":$dry_json,\"status\":\"$1\",\"categories\":$(json_categories),\"rules\":[],\"summary\":{\"plannedBytes\":0,\"freedBytes\":0,\"archivedBytes\":0},\"errors\":[\"$esc\"]}" >&3
  fi
  exit "$2"
}

LOCK_DIR="$(aicm_temp_dir)/ai-cli-auto-manager-clean-$(id -u).lockdir"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [[ -f "$LOCK_DIR/pid" ]] && kill -0 "$(cat "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then
    echo "[$(aicm_ts)] another cleanup run is already active"
    json_bail skipped 0 "another cleanup run is already active"
  fi
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
  mkdir "$LOCK_DIR" 2>/dev/null || { echo "[$(aicm_ts)] another cleanup run is already active"; json_bail skipped 0 "another cleanup run is already active"; }
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"
trap 'rm -f "$LOCK_DIR/pid" 2>/dev/null || true; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

if [[ "$JSON" != true && "$REPORT" != true ]]; then
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/clean-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
fi
if [[ "$REPORT" != true ]]; then
  echo "[$(aicm_ts)] AI leftover cleanup started (mode=$([[ "$DRY_RUN" == true ]] && echo dry-run || echo clean), version=$(aicm_version))"
fi

# Per-rule results, set by the rule functions.
# R_ERROR: a rule that could not do its job sets it (and returns 0); it becomes a problem.
R_FILES=0; R_BYTES=0; R_REMOVED=0; R_REMOVED_BYTES=0; R_IN_USE=0; R_STATUS=""
R_PURGE=0; R_PURGE_BYTES=0; R_PURGED=0; R_PURGED_BYTES=0; R_DETAIL=""; R_ERROR=""
# Budget rules only: logical bytes of every ordinary file below the root before the run, the budget,
# what is left (after a real run), what a preview projects, how far above the budget it stays, and
# whether the scan saw everything (complete), stopped early (partial) or could not read the root (unavailable).
R_TOTAL=0; R_BUDGET=0; R_REMAINING=0; R_PROJECTED=0; R_UNMET=0; R_SCAN=""
R_VARS="R_FILES R_BYTES R_REMOVED R_REMOVED_BYTES R_IN_USE R_PURGE R_PURGE_BYTES R_PURGED R_PURGED_BYTES R_DETAIL R_ERROR R_TOTAL R_BUDGET R_REMAINING R_PROJECTED R_UNMET R_SCAN"

reset_result() {
  R_FILES=0; R_BYTES=0; R_REMOVED=0; R_REMOVED_BYTES=0; R_IN_USE=0; R_STATUS=""
  R_PURGE=0; R_PURGE_BYTES=0; R_PURGED=0; R_PURGED_BYTES=0; R_DETAIL=""; R_ERROR=""
  R_TOTAL=0; R_BUDGET=0; R_REMAINING=0; R_PROJECTED=0; R_UNMET=0; R_SCAN=""
}

# Every age comes from the clock, so a clock far off (a dead CMOS battery, a restored VM snapshot, a
# wrong NTP answer) would make everything look old. Compared with when the last run wrote its state.
clock_problem() {
  local f="$AICM_HOME/state/last-clean.json" when now
  [[ "${AICM_CLOCK_CHECK:-1}" != 0 && -f "$f" ]] || return 0
  when="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)" || return 0
  [[ "$when" =~ ^[0-9]+$ ]] || return 0
  now="$(date +%s)"
  if ((now < when - 86400)); then
    echo "the system clock is earlier than the last cleanup run: nothing deleted until the clock is right"
  elif ((now > when + 400 * 86400)); then
    echo "the system clock is more than 400 days past the last cleanup run: nothing deleted (if the date is right, run once with AICM_CLOCK_CHECK=0)"
  fi
}

tree_bytes() {
  find "$1" -type f -print0 2>/dev/null | aicm_sizes_stdin | aicm_sum_lines
}

file_bytes() {
  printf '%s\0' "$1" | aicm_sizes_stdin | aicm_sum_lines
}

count_list() { tr -cd '\0' < "$1" | wc -c | tr -d ' '; }

# Deletes the NUL-separated file list in $1 in one pass (no process per file, so a 100k-file cache takes
# seconds), updating R_REMOVED / R_REMOVED_BYTES / R_IN_USE from what is still there afterwards.
remove_listed_files() {
  local list="$1" left f count bytes n_left b_left
  [[ -s "$list" ]] || return 0
  count="$(count_list "$list")"; bytes="$(aicm_sizes_stdin < "$list" | aicm_sum_lines)"
  xargs -0 rm -f -- < "$list" 2>/dev/null || true
  left="$(mktemp)"
  while IFS= read -r -d '' f; do if [[ -e "$f" || -L "$f" ]]; then printf '%s\0' "$f"; fi; done < "$list" > "$left"
  n_left="$(count_list "$left")"; b_left="$(aicm_sizes_stdin < "$left" | aicm_sum_lines)"
  rm -f "$left"
  R_REMOVED=$((R_REMOVED + count - n_left)); R_REMOVED_BYTES=$((R_REMOVED_BYTES + bytes - b_left)); R_IN_USE=$((R_IN_USE + n_left))
}

# Empty folders below $1, deepest first; "memory" folders and their insides stay.
prune_empty_dirs() {
  find "$1" -mindepth 1 -type d -empty ! -iname memory ! -ipath '*/memory/*' -delete 2>/dev/null || true
}

# SQLite keeps one database in up to four files: <name>.sqlite|.sqliteN|.db plus -wal, -shm and
# -journal. Removing an old base while its newer WAL holds committed pages, or while a connection still
# has it open, loses data; so date rules remove a family only as a whole. Every member present must be
# a regular file the rule would remove on its own (re-checked right before removal), and lsof must
# prove none of them open. A missing or failing lsof, an open member, a newer, protected or
# pattern-excluded member, or a sidecar that is a link or folder keeps every member. A lone sidecar
# (its base is gone) is a family of one and follows the same rules. Other files are still removed in
# one batch.
SQLITE_FAMILY_RE='^(.*\.([sS][qQ][lL][iI][tT][eE][0-9]*|[dD][bB]))(-wal|-shm|-journal)?$'

# Splits NUL list $1 into the files outside SQLite families ($2) and family members ($3).
split_sqlite_families() { # list plain-out family-out
  local f
  : > "$3"
  # Fast path: most caches hold no SQLite files at all (this test only ever over-matches). A process
  # substitution, so grep stopping early never turns into a pipefail "no match".
  if ! grep -Eq '\.([sS][qQ][lL][iI][tT][eE][0-9]*|[dD][bB])(-wal|-shm|-journal)?$' < <(tr '\0' '\n' < "$1"); then
    cp "$1" "$2"
    return 0
  fi
  while IFS= read -r -d '' f; do
    if [[ "$f" =~ $SQLITE_FAMILY_RE ]]; then printf '%s\0' "$f" >&3; else printf '%s\0' "$f"; fi
  done < "$1" > "$2" 3> "$3"
}

# Removes the SQLite families of the members in NUL list $1. $2 is the check that a member is one the
# rule would remove on its own (called as: $2 path args...).
remove_sqlite_families() { # list member-check [check args...]
  local list="$1" check="$2" f base seen=$'\n' m valid size
  shift 2
  while IFS= read -r -d '' f; do
    [[ "$f" =~ $SQLITE_FAMILY_RE ]] || continue
    base="${BASH_REMATCH[1]}"
    case "$seen" in *$'\n'"$base"$'\n'*) continue ;; esac
    seen+="$base"$'\n'
    local members=()
    valid=true
    for m in "$base" "$base-wal" "$base-shm" "$base-journal"; do
      [[ -e "$m" || -L "$m" ]] || continue
      members+=("$m")
      if [[ -L "$m" || ! -f "$m" ]]; then
        valid=false; R_DETAIL="unexpected SQLite sidecar ${m##*/}; the whole database was kept"
      elif ! "$check" "$m" "$@"; then
        valid=false; R_DETAIL="SQLite ${m##*/} is newer than the rule's age or not covered by it; the whole database was kept"
      fi
    done
    ((${#members[@]})) || continue
    if [[ "$valid" != true ]]; then R_IN_USE=$((R_IN_USE + ${#members[@]})); continue; fi
    if ! cap_group_idle "${members[@]}"; then
      R_IN_USE=$((R_IN_USE + ${#members[@]}))
      R_DETAIL="open-file check found use or could not prove the SQLite files idle; kept"
      continue
    fi
    for m in "${members[@]}"; do
      size="$(file_bytes "$m")"
      if rm -f -- "$m" 2>/dev/null && [[ ! -e "$m" ]]; then
        R_REMOVED=$((R_REMOVED + 1)); R_REMOVED_BYTES=$((R_REMOVED_BYTES + size))
      else
        R_IN_USE=$((R_IN_USE + 1))
      fi
    done
  done < "$list"
}

# Removes NUL list $1: SQLite families through remove_sqlite_families, everything else in one batch.
remove_rule_files() { # list member-check [check args...]
  local list="$1" plain fam
  shift
  plain="$(mktemp)"; fam="$(mktemp)"
  split_sqlite_families "$list" "$plain" "$fam"
  remove_listed_files "$plain"
  [[ -s "$fam" ]] && remove_sqlite_families "$fam" "$@"
  rm -f "$plain" "$fam"
}

# A member the age rule would remove: its unit (the entry directly in <root> that holds it) matches the
# pattern, is not a link and has nothing changed within the age, and the member itself is not protected.
# shellcheck disable=SC2329 # called by name through remove_rule_files
age_member_ok() { # path root pattern mins
  local rel="${1#"$2"/}" unit
  unit="$2/${rel%%/*}"
  [[ -e "$unit" && ! -L "$unit" ]] || return 1
  # shellcheck disable=SC2053
  [[ "${unit##*/}" == $3 ]] || return 1
  [[ -z "$(find "$unit" -mmin -"$4" -print -quit 2>/dev/null)" ]] || return 1
  [[ -n "$(find "$1" -prune -type f "${AICM_PROTECT_ARGS[@]}" -print 2>/dev/null)" ]]
}

# A member the age-files rule would remove: a regular file matching the pattern, older than the age,
# not protected.
# shellcheck disable=SC2329 # called by name through remove_rule_files
age_files_member_ok() { # path pattern mins
  [[ -n "$(find "$1" -prune -type f -name "$2" -mmin +"$3" "${AICM_PROTECT_ARGS[@]}" -print 2>/dev/null)" ]]
}

# Each entry directly in <root> that matches <pattern> (a session folder, a temp folder, a file) is one
# unit: it goes only when nothing inside it changed for <days>. Deleting old files one by one would break
# folders still in use (an open session whose first file is old, a plugin checkout). Units are checked
# and deleted one at a time, so a session resumed while the cleanup runs is seen before anything goes.
run_age_rule() {
  local root="$1" pattern="$2" days="$3" dry="$4" mins unit list
  mins=$((days * 1440))
  list="$(mktemp)"
  for unit in "$root"/* "$root"/.[!.]* "$root"/..?*; do
    [[ -e "$unit" && ! -L "$unit" ]] || continue
    # shellcheck disable=SC2053
    [[ "$(basename "$unit")" == $pattern ]] || continue
    # Anything changed within <days> (a file, a folder, the unit itself) keeps the whole unit.
    [[ -z "$(find "$unit" -mmin -"$mins" -print -quit 2>/dev/null)" ]] || continue
    find "$unit" -type f "${AICM_PROTECT_ARGS[@]}" -print0 2>/dev/null > "$list" || true
    R_FILES=$((R_FILES + $(count_list "$list"))); R_BYTES=$((R_BYTES + $(aicm_sizes_stdin < "$list" | aicm_sum_lines)))
    [[ "$dry" == true ]] && continue
    remove_rule_files "$list" age_member_ok "$root" "$pattern" "$mins"
    if [[ -d "$unit" ]]; then prune_empty_dirs "$unit"; rmdir "$unit" 2>/dev/null || true; fi
  done
  rm -f "$list"
}

# Single old files anywhere below <root>: for caches whose entries stand alone (content-addressed npm and
# pip caches), where a folder is never "in use" as a whole. SQLite families still go only as a whole.
run_age_files_rule() {
  local root="$1" pattern="$2" days="$3" dry="$4" list
  list="$(mktemp)"
  find "$root" -type f -name "$pattern" -mmin +"$((days * 1440))" "${AICM_PROTECT_ARGS[@]}" -print0 2>/dev/null > "$list" || true
  R_FILES="$(count_list "$list")"
  R_BYTES="$(aicm_sizes_stdin < "$list" | aicm_sum_lines)"
  if [[ "$dry" != true ]]; then
    remove_rule_files "$list" age_files_member_ok "$pattern" "$((days * 1440))"
    prune_empty_dirs "$root"
  fi
  rm -f "$list"
}

# POSIX permits unlinking an open SQLite DB, including its WAL. Missing/failed checks keep the group.
cap_group_idle() {
  local out err rc=0 idle=1
  command -v lsof >/dev/null 2>&1 || return 1
  out="$(mktemp)" || return 1
  err="$(mktemp)" || { rm -f "$out"; return 1; }
  aicm_timeout 15 lsof -t -- "$@" > "$out" 2> "$err" || rc=$?
  [[ "$rc" == 1 && ! -s "$out" && ! -s "$err" ]] && idle=0
  rm -f "$out" "$err"
  return "$idle"
}

# Whole-directory cleanup uses the same protections as individual files. Any protected,
# linked or open member keeps the tree before rm can remove its first file.
cleanup_tree_idle() {
  local root="$1" list all safe f
  [[ -z "$(find "$root" -type l -o -iname memory 2>/dev/null)" ]] || return 1
  list="$(mktemp)" || return 1
  find "$root" -type f -print0 > "$list" 2>/dev/null || { rm -f "$list"; return 1; }
  all="$(count_list "$list")"
  safe="$(find "$root" -type f "${AICM_PROTECT_ARGS[@]}" -print0 2>/dev/null | tr -cd '\0' | wc -c | tr -d ' ')"
  [[ "$all" == "$safe" ]] || { rm -f "$list"; return 1; }
  local files=()
  while IFS= read -r -d '' f; do files+=("$f"); done < "$list"
  rm -f "$list"
  ((${#files[@]} == 0)) || cap_group_idle "${files[@]}"
}

run_cap_rule() {
  local root="$1" pattern="$2" days="$3" limit_mb="$4" dry="$5" list f size too_old too_big side
  list="$(mktemp)"
  find "$root" -maxdepth 1 -type f -name "$pattern" "${AICM_PROTECT_ARGS[@]}" -print0 2>/dev/null > "$list" || true
  while IFS= read -r -d '' f; do
    size="$(file_bytes "$f")"
    too_old=false; too_big=false
    if ((days > 0)) && [[ -n "$(find "$f" -mmin +"$((days * 1440))" 2>/dev/null)" ]]; then too_old=true; fi
    if ((limit_mb > 0)) && ((size > limit_mb * 1048576)); then too_big=true; fi
    [[ "$too_old" == true || "$too_big" == true ]] || continue
    local group=("$f")
    local valid=true
    for side in "$f-wal" "$f-shm" "$f-journal"; do
      if [[ -e "$side" || -L "$side" ]]; then
        if [[ -f "$side" && ! -L "$side" ]]; then group+=("$side"); else valid=false; fi
      fi
    done
    if [[ "$valid" != true ]]; then
      R_IN_USE=$((R_IN_USE + 1)); R_DETAIL="unexpected SQLite sidecar; kept"
      continue
    fi
    if ! cap_group_idle "${group[@]}"; then
      R_IN_USE=$((R_IN_USE + ${#group[@]}))
      R_DETAIL="open-file check found use or could not prove the files idle; kept"
      continue
    fi
    for side in "${group[@]}"; do R_FILES=$((R_FILES + 1)); R_BYTES=$((R_BYTES + $(file_bytes "$side"))); done
    [[ "$dry" == true ]] && continue
    for side in "${group[@]}"; do
      size="$(file_bytes "$side")"
      if rm -f -- "$side" 2>/dev/null && [[ ! -e "$side" ]]; then
        R_REMOVED=$((R_REMOVED + 1)); R_REMOVED_BYTES=$((R_REMOVED_BYTES + size))
      else
        R_IN_USE=$((R_IN_USE + 1))
      fi
    done
  done < "$list"
  rm -f "$list"
}

# Budget scans stay inside the rule's root and are bounded; a scan that hits a bound is partial.
budget_bound() { if [[ "$1" =~ ^[1-9][0-9]{0,8}$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
BUDGET_MAX_FILES="$(budget_bound "${AICM_BUDGET_MAX_FILES:-}" 200000)"
BUDGET_MAX_DEPTH="$(budget_bound "${AICM_BUDGET_MAX_DEPTH:-}" 32)"
BUDGET_SCAN_SECONDS="$(budget_bound "${AICM_BUDGET_SCAN_SECONDS:-}" 300)"
# "mtime size links dev:inode path" of a path itself; a link is never followed.
# BUDGET_SIZE prints only the size, one line per file whatever its name holds.
if stat -c %s / >/dev/null 2>&1; then BUDGET_STAT=(stat -c '%Y %s %h %d:%i %n'); BUDGET_SIZE=(stat -c '%s')
else BUDGET_STAT=(stat -f '%m %z %l %d:%i %N'); BUDGET_SIZE=(stat -f '%z'); fi

# Logical bytes of every ordinary file below $1 into $2 (count, then bytes, one per line). Prints the
# scan status: complete, partial (a read error, the time, depth or file-count bound) or unavailable.
budget_scan() { # root out [expected-identity]
  local root="$1" out="$2" want="${3:-}" list err sizes depth rc=0 src=0 drc=0 status=complete count
  printf '0\n0\n' > "$out"
  # The root itself must still be the folder that was checked: not a link, same identity.
  if [[ -L "$root" || ! -d "$root" || ! -r "$root" || ! -x "$root" ]]; then echo unavailable; return 0; fi
  if [[ -n "$want" && "$(budget_root_identity "$root")" != "$want" ]]; then echo unavailable; return 0; fi
  list="$(mktemp)"; err="$(mktemp)"; sizes="$(mktemp)"; depth="$(mktemp)"
  aicm_timeout "$BUDGET_SCAN_SECONDS" find "$root" -maxdepth "$BUDGET_MAX_DEPTH" -type f -print0 > "$list" 2> "$err" || rc=$?
  # An unreadable folder is never counted as empty: any find error makes the scan partial.
  [[ "$rc" == 0 && ! -s "$err" ]] || status=partial
  : > "$err"
  aicm_timeout "$BUDGET_SCAN_SECONDS" find "$root" -mindepth "$((BUDGET_MAX_DEPTH + 1))" -maxdepth "$((BUDGET_MAX_DEPTH + 1))" -print -quit > "$depth" 2> "$err" || drc=$?
  [[ "$drc" == 0 && ! -s "$err" && ! -s "$depth" ]] || status=partial
  count="$(count_list "$list")"
  ((count <= BUDGET_MAX_FILES)) || status=partial
  # A file whose size cannot be read is not a zero-byte file: one size per file, no stat error.
  : > "$err"
  if [[ -s "$list" ]]; then
    xargs -0 "${BUDGET_SIZE[@]}" < "$list" > "$sizes" 2> "$err" || src=$?
  fi
  [[ "$src" == 0 && ! -s "$err" && "$(wc -l < "$sizes" | tr -d ' ')" == "$count" ]] || status=partial
  printf '%s\n%s\n' "$count" "$(aicm_sum_lines < "$sizes")" > "$out"
  rm -f "$list" "$err" "$sizes" "$depth"
  echo "$status"
}

# dev:inode and real path of a rule root; deletions stop when either changes (a root swapped for a
# link or moved after the scan).
budget_root_identity() {
  local id real
  [[ -d "$1" && ! -L "$1" ]] || return 1
  id="$("${BUDGET_STAT[@]}" "$1" 2>/dev/null)" || return 1
  real="$(cd -P -- "$1" 2>/dev/null && pwd -P)" || return 1
  id="${id#* * * }"; printf '%s %s' "${id%% *}" "$real"
}

# No link between the root and the file (a folder swapped for a link after the scan).
budget_path_unlinked() { # root path
  local p
  p="$(dirname "$2")"
  while [[ "$p" == "$1"/* ]]; do [[ -L "$p" ]] && return 1; p="$(dirname "$p")"; done
  [[ "$p" == "$1" ]]
}

# Idle check of the files in $@ (a chunk): one lsof call for the chunk, then one per file only when
# the chunk is not proven idle. Prints the idle files, one per line. No lsof, a failing lsof or an open
# file keeps that file.
budget_idle_files() {
  local f
  if cap_group_idle "$@"; then printf '%s\n' "$@"; return 0; fi
  for f in "$@"; do if cap_group_idle "$f"; then printf '%s\n' "$f"; fi; done
}

# Keeps an independent-file cache (npm, pip) at or below <limit> MiB of logical bytes. Every ordinary
# file counts toward the total, also protected, recent, linked, SQLite and open ones; only files that
# match <pattern>, are older than <days>, have a single link, are not SQLite database files or sidecars,
# not protected and not open are candidates, oldest modification time first (not least recently
# used: access times are not tracked). Deletion stops once the total is at or below the budget. A scan
# that is not complete deletes nothing. Each file is checked again right before removal (same type,
# identity, size and time, no link on the way), which narrows but does not close the race with a
# program that opens it in between.
run_budget_rule() { # root pattern days limit-MiB dry
  local root="$1" pattern="$2" days="$3" limit_mb="$4" dry="$5" mins scanout sorted chunkfile line total remaining nl=$'\n'
  local mtime size links ident path rest now idle f raw stats err candidate_rc=0
  local rootid
  mins=$((days * 1440)); R_BUDGET=$((limit_mb * 1048576))
  rootid="$(budget_root_identity "$root" || true)"
  scanout="$(mktemp)"
  if [[ -z "$rootid" ]]; then R_SCAN=unavailable; else R_SCAN="$(budget_scan "$root" "$scanout" "$rootid")"; fi
  total="$(sed -n 2p "$scanout")"; rm -f "$scanout"
  R_TOTAL="${total:-0}"; R_REMAINING="$R_TOTAL"; R_PROJECTED="$R_TOTAL"
  if [[ "$R_SCAN" != complete ]]; then
    R_DETAIL="budget scan $R_SCAN (unreadable entries or a scan bound): nothing deleted by the budget"
    R_UNMET=0; ((R_TOTAL > R_BUDGET)) && R_UNMET=$((R_TOTAL - R_BUDGET))
    return 0
  fi
  if ((R_TOTAL <= R_BUDGET)); then return 0; fi
  if ! command -v lsof >/dev/null 2>&1; then
    R_UNMET=$((R_TOTAL - R_BUDGET))
    R_DETAIL="lsof not found, files in use cannot be ruled out: nothing deleted by the budget"
    return 0
  fi
  sorted="$(mktemp)"; chunkfile="$(mktemp)"
  # SQLite names are left out wholesale (also lone -wal/-shm/-journal files); they never go by budget.
  raw="$(mktemp)"; stats="$(mktemp)"; err="$(mktemp)"
  aicm_timeout "$BUDGET_SCAN_SECONDS" find "$root" -maxdepth "$BUDGET_MAX_DEPTH" -type f -name "$pattern" ! -name "*$nl*" -mmin +"$mins" \
    ! -iname '*.sqlite' ! -iname '*.sqlite[0-9]*' ! -iname '*.db' ! -iname '*-wal' ! -iname '*-shm' ! -iname '*-journal' \
    "${AICM_PROTECT_ARGS[@]}" -print0 > "$raw" 2> "$err" || candidate_rc=$?
  if [[ "$candidate_rc" == 0 && ! -s "$err" && -s "$raw" ]]; then
    aicm_timeout "$BUDGET_SCAN_SECONDS" xargs -0 "${BUDGET_STAT[@]}" < "$raw" > "$stats" 2> "$err" || candidate_rc=$?
  fi
  if [[ "$candidate_rc" != 0 || -s "$err" ]]; then
    R_SCAN=partial; R_DETAIL="budget candidate scan incomplete: nothing deleted by the budget"
    R_UNMET=$((R_TOTAL - R_BUDGET))
    rm -f "$raw" "$stats" "$err" "$sorted" "$chunkfile"
    return 0
  fi
  awk '$3 == 1 && $2 > 0' "$stats" | LC_ALL=C sort -t ' ' -k1,1n -k5 > "$sorted" || candidate_rc=$?
  rm -f "$raw" "$stats" "$err"
  if [[ "$candidate_rc" != 0 ]]; then
    R_SCAN=partial; R_DETAIL="budget candidate sort incomplete: nothing deleted by the budget"
    R_UNMET=$((R_TOTAL - R_BUDGET)); rm -f "$sorted" "$chunkfile"; return 0
  fi
  remaining="$R_TOTAL"
  # Chunks of 50 candidates, oldest first, until the budget is met.
  while ((remaining > R_BUDGET)) && [[ -s "$sorted" ]]; do
    head -n 50 "$sorted" > "$chunkfile"
    tail -n +51 "$sorted" > "$sorted.rest"; mv -f "$sorted.rest" "$sorted"
    local paths=()
    while IFS= read -r line; do paths+=("${line#* * * * }"); done < "$chunkfile"
    idle=$'\n'"$(budget_idle_files "${paths[@]}")"$'\n'
    while IFS= read -r line; do
      ((remaining > R_BUDGET)) || break
      mtime="${line%% *}"; rest="${line#* }"; size="${rest%% *}"; rest="${rest#* }"
      links="${rest%% *}"; rest="${rest#* }"; ident="${rest%% *}"; path="${rest#* }"
      if [[ "$idle" != *$'\n'"$path"$'\n'* ]]; then R_IN_USE=$((R_IN_USE + 1)); continue; fi
      R_FILES=$((R_FILES + 1)); R_BYTES=$((R_BYTES + size))
      if [[ "$dry" == true ]]; then remaining=$((remaining - size)); continue; fi
      now="$("${BUDGET_STAT[@]}" "$path" 2>/dev/null || true)"
      if [[ "$(budget_root_identity "$root" || true)" != "$rootid" ]]; then
        R_IN_USE=$((R_IN_USE + 1)); R_DETAIL="the rule folder changed during the run (moved or replaced by a link): nothing more deleted"
        R_SCAN=partial; : > "$sorted"; break
      fi
      if [[ -f "$path" && ! -L "$path" && "$now" == "$mtime $size $links $ident $path" ]] && budget_path_unlinked "$root" "$path" &&
         rm -f -- "$path" 2>/dev/null && [[ ! -e "$path" && ! -L "$path" ]]; then
        R_REMOVED=$((R_REMOVED + 1)); R_REMOVED_BYTES=$((R_REMOVED_BYTES + size)); remaining=$((remaining - size))
      else
        R_IN_USE=$((R_IN_USE + 1))
      fi
    done < "$chunkfile"
  done
  rm -f "$sorted" "$chunkfile"
  R_PROJECTED="$remaining"
  if [[ "$dry" != true ]]; then
    prune_empty_dirs "$root"
    # What is really left, counted again (other programs may have written meanwhile).
    scanout="$(mktemp)"
    if [[ "$R_SCAN" == complete && "$(budget_scan "$root" "$scanout" "$rootid")" == complete ]]; then R_REMAINING="$(sed -n 2p "$scanout")"
    else R_REMAINING="$remaining"; R_SCAN=partial; fi
    rm -f "$scanout"
    f="$R_REMAINING"
  else
    f="$R_PROJECTED"
  fi
  ((f > R_BUDGET)) && R_UNMET=$((f - R_BUDGET))
  if ((R_UNMET > 0)) && [[ -z "$R_DETAIL" ]]; then
    R_DETAIL="budget not reachable: $(aicm_format_size "$R_UNMET") above it is recent, protected, linked, SQLite or in use"
  fi
  return 0
}

run_keep_latest_rule() {
  local root="$1" pattern="$2" keep="$3" dry="$4" d name lines victims bytes
  lines=""
  for d in "$root"/*; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    name="$(basename "$d")"
    # shellcheck disable=SC2053
    [[ "$name" == $pattern ]] || continue
    if [[ "$name" =~ ^(.+)-([0-9]+)$ ]]; then
      lines+="${BASH_REMATCH[1]}"$'\t'"${BASH_REMATCH[2]}"$'\t'"$name"$'\n'
    fi
  done
  [[ -n "$lines" ]] || return 0
  victims="$(printf '%s' "$lines" | sort -t $'\t' -k1,1 -k2,2nr | awk -F '\t' -v keep="$keep" '{ n[$1]++; if (n[$1] > keep) print $3 }')"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    bytes="$(tree_bytes "$root/$name")"
    R_FILES=$((R_FILES + 1)); R_BYTES=$((R_BYTES + bytes))
    [[ "$dry" == true ]] && continue
    if ! cleanup_tree_idle "$root/$name"; then R_IN_USE=$((R_IN_USE + 1)); continue; fi
    if rm -rf -- "${root:?}/$name" 2>/dev/null; then
      R_REMOVED=$((R_REMOVED + 1)); R_REMOVED_BYTES=$((R_REMOVED_BYTES + bytes))
    else
      R_IN_USE=$((R_IN_USE + 1))
    fi
  done <<< "$victims"
}

# Archive date folders (archive/<rule>/yyyymmdd) older than <days> are removed.
purge_archive() { # archive_dir days dry
  local adir="$1" days="$2" dry="$3" cutoff d name bytes
  aicm_archive_dest_ok "$adir" || return 0
  [[ -d "$adir" && ! -L "$adir" ]] || return 0
  cutoff="$(aicm_date_days_ago "$days")"
  for d in "$adir"/*; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    aicm_archive_dest_ok "$d" || continue
    name="$(basename "$d")"
    [[ "$name" =~ ^[0-9]{8}$ ]] || continue
    ((10#$name < 10#$cutoff)) || continue
    bytes="$(tree_bytes "$d")"
    R_PURGE=$((R_PURGE + 1)); R_PURGE_BYTES=$((R_PURGE_BYTES + bytes))
    [[ "$dry" == true ]] && continue
    if ! cleanup_tree_idle "$d"; then R_IN_USE=$((R_IN_USE + 1)); continue; fi
    if rm -rf -- "${d:?}" 2>/dev/null; then
      R_PURGED=$((R_PURGED + 1)); R_PURGED_BYTES=$((R_PURGED_BYTES + bytes))
    else
      R_IN_USE=$((R_IN_USE + 1))
    fi
  done
}

# Session files older than the archive age move to ~/.ai-cli-auto-manager/archive/<rule>/<today>/,
# keeping their relative path; archive folders older than <limit> days are deleted.
# Old archive folders are purged even when the rule is off (purge_dry), so remnants never stay behind.
run_archive_rule() { # root id pattern days limit dry purge_dry
  local root="$1" id="$2" pattern="$3" days="$4" limit="$5" dry="$6" purge_dry="$7" adays native list f rel target size dest
  adays="$(aicm_archive_days "$id" "$days")"
  native="$(aicm_native_retention_days "$id")"
  [[ "$adays" != "$days" ]] && R_DETAIL="archive after ${adays}d (the CLI deletes after ${native}d)"
  list="$(mktemp)"
  find "$root" -type f -name "$pattern" -mmin +"$((adays * 1440))" "${AICM_PROTECT_ARGS[@]}" -print0 2>/dev/null > "$list" || true
  R_FILES="$(tr -cd '\0' < "$list" | wc -c | tr -d ' ')"
  R_BYTES="$(aicm_sizes_stdin < "$list" | aicm_sum_lines)"
  if [[ "$dry" != true && "$R_FILES" != 0 ]]; then
    dest="$AICM_HOME/archive/$id/$(date +%Y%m%d)"
    if ! aicm_archive_dest_ok "$dest"; then
      R_ERROR="archive destination escapes $(aicm_display_path "$AICM_HOME/archive")"
      rm -f "$list"
      return 0
    fi
    while IFS= read -r -d '' f; do
      rel="${f#"$root"/}"
      target="$dest/$rel"
      if ! aicm_archive_dest_ok "$(dirname "$target")"; then
        R_IN_USE=$((R_IN_USE + 1))
        continue
      fi
      mkdir -p "$(dirname "$target")"
      if ! aicm_archive_dest_ok "$(dirname "$target")"; then
        R_IN_USE=$((R_IN_USE + 1))
        continue
      fi
      [[ -e "$target" ]] && target="$target.$$"
      size="$(file_bytes "$f")"
      if ! command -v node >/dev/null 2>&1; then
        R_ERROR="Node.js is required to archive files; left in place"
        continue
      fi
      if [[ ! -f "$AICM_ROOT/lib/maintenance.js" ]]; then
        R_ERROR="lib/maintenance.js is missing from this copy; files were not moved"
        continue
      fi
      put_out="$(mktemp)"; put_err="$(mktemp)"
      if node "$AICM_ROOT/lib/maintenance.js" archive-put --rule "$id" --root "$root" --source "$f" --dest "$target" --json >"$put_out" 2>"$put_err" \
        && grep -q '"ok":true' "$put_out"; then
        R_REMOVED=$((R_REMOVED + 1)); R_REMOVED_BYTES=$((R_REMOVED_BYTES + size))
      else
        R_IN_USE=$((R_IN_USE + 1))
        if [[ -z "$R_ERROR" ]]; then
          R_ERROR="$(head -n 1 "$put_err" 2>/dev/null || true)"
          [[ -n "$R_ERROR" ]] || R_ERROR="archive-put did not move $(basename "$f")"
        fi
      fi
      rm -f "$put_out" "$put_err"
    done < "$list"
    prune_empty_dirs "$root"
  fi
  rm -f "$list"
  if ! command -v node >/dev/null 2>&1 || [[ ! -f "$AICM_ROOT/lib/maintenance.js" ]]; then
    if [[ "$dry" != true ]]; then
      [[ -n "$R_ERROR" ]] || R_ERROR="Node.js and lib/maintenance.js are required to purge generic archives; old archive folders were left in place"
      return 0
    fi
  fi
  purge_archive "$AICM_HOME/archive/$id" "$limit" "$purge_dry"
}

codex_id() { [[ "$1" =~ ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) ]] && printf '%s' "${BASH_REMATCH[1]}"; }

# Codex keeps every session in its own database as well as in rollout files, so files are never
# deleted directly: `codex archive` after <days>, `codex delete --force` once a session has been
# unused for <days> + <limit>. Threads whose file is already gone count as archived and are deleted
# on the same schedule (needs sqlite3 or python3 to read the database; skipped otherwise).
run_codex_rule() { # root days limit dry
  local root="$1" days="$2" limit="$3" dry="$4" codex arch del threads present d f cid now cut id updated _archived size orphans=()
  if ! codex="$(command -v codex 2>/dev/null)"; then
    # Sessions without the codex command: Codex was used here, but this run cannot find it.
    if [[ -d "$root/sessions" ]]; then R_ERROR="codex command not found, Codex sessions were not cleaned"; return 0; fi
    R_DETAIL="codex command not found: nothing touched"; return 0
  fi
  arch="$(mktemp)"; del="$(mktemp)"; threads="$(mktemp)"; present="$(mktemp)"
  [[ -d "$root/sessions" ]] && find "$root/sessions" -type f -name 'rollout-*' -mmin +"$((days * 1440))" -print0 2>/dev/null > "$arch"
  [[ -d "$root/archived_sessions" ]] && find "$root/archived_sessions" -type f -name 'rollout-*' -mmin +"$(((days + limit) * 1440))" -print0 2>/dev/null > "$del"
  # limit 0: no archive stage, sessions unused for <days> are deleted right away.
  if ((limit == 0)); then cat "$arch" >> "$del"; : > "$arch"; fi
  if aicm_codex_threads "$root" > "$threads"; then
    # A thread is orphaned only when no rollout file with its id exists under sessions or archived_sessions;
    # the stored path is not trusted (a moved home folder, WSL, encodings).
    for d in "$root/sessions" "$root/archived_sessions"; do
      if [[ -d "$d" ]]; then find "$d" -type f -name 'rollout-*' 2>/dev/null; fi
    done | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' > "$present" || true
    now="$(date +%s)"; cut=$((now - (days + limit) * 86400))
    while IFS=$'\t' read -r id updated _archived; do
      [[ -n "$id" ]] || continue
      # Only unix seconds or milliseconds; anything else (a date text) is unknown and left alone.
      [[ "$updated" =~ ^[0-9]+(\.[0-9]+)?$ ]] || continue
      updated="${updated%%.*}"; ((updated > 100000000000)) && updated=$((updated / 1000))
      ((updated > 0 && updated < cut)) || continue
      grep -qxF "$id" "$present" || orphans+=("$id")
    done < "$threads"
  else
    R_DETAIL="Codex database not read (sqlite3/python3 not found, or an unknown layout): sessions whose file is already gone are left alone"
  fi
  R_FILES="$(tr -cd '\0' < "$arch" | wc -c | tr -d ' ')"
  R_BYTES="$(aicm_sizes_stdin < "$arch" | aicm_sum_lines)"
  R_PURGE=$(( $(tr -cd '\0' < "$del" | wc -c | tr -d ' ') + ${#orphans[@]} ))
  R_PURGE_BYTES="$(aicm_sizes_stdin < "$del" | aicm_sum_lines)"
  ((${#orphans[@]})) && R_DETAIL="${#orphans[@]} of the deletions are sessions whose file is already gone"
  if [[ "$dry" != true ]]; then
    while IFS= read -r -d '' f; do
      cid="$(codex_id "$(basename "$f")")" || continue
      size="$(file_bytes "$f")"
      if aicm_timeout 120 "$codex" archive "$cid" </dev/null >/dev/null 2>&1; then
        R_REMOVED=$((R_REMOVED + 1)); R_REMOVED_BYTES=$((R_REMOVED_BYTES + size))
      else
        R_IN_USE=$((R_IN_USE + 1))
      fi
    done < "$arch"
    while IFS= read -r -d '' f; do
      cid="$(codex_id "$(basename "$f")")" || continue
      size="$(file_bytes "$f")"
      if aicm_timeout 120 "$codex" delete --force "$cid" </dev/null >/dev/null 2>&1; then
        R_PURGED=$((R_PURGED + 1)); R_PURGED_BYTES=$((R_PURGED_BYTES + size))
      elif [[ -s "$threads" ]] && ! grep -q "^$cid"$'\t' "$threads" && rm -f -- "$f"; then
        # A file Codex does not know (older layout) cannot be orphaned; remove it directly.
        R_PURGED=$((R_PURGED + 1)); R_PURGED_BYTES=$((R_PURGED_BYTES + size))
      else
        R_IN_USE=$((R_IN_USE + 1))
      fi
    done < "$del"
    if ((${#orphans[@]})); then
      local failed=()
      for cid in "${orphans[@]}"; do
        if aicm_timeout 120 "$codex" delete --force "$cid" </dev/null >/dev/null 2>&1; then R_PURGED=$((R_PURGED + 1)); else failed+=("$cid"); fi
      done
      if ((${#failed[@]})); then
        # Deleting a session also deletes the sub-agent sessions it spawned, so a later delete of one of
        # those fails although it is already gone. Count what the database no longer has as done.
        aicm_codex_threads "$root" > "$threads" || : > "$threads"
        for cid in "${failed[@]}"; do
          if [[ -s "$threads" ]] && ! grep -q "^$cid"$'\t' "$threads"; then R_PURGED=$((R_PURGED + 1)); else R_IN_USE=$((R_IN_USE + 1)); fi
        done
      fi
    fi
  fi
  rm -f "$arch" "$del" "$threads" "$present"
}

# Runs rule $1 on folder $2. Kept out of the $( ) below: bash 3.2 misreads case patterns there.
run_rule() { # index root dry
  local i="$1" root="$2" dry="$3"
  case "${AICM_RULE_KIND[$i]}" in
    age) run_age_rule "$root" "${AICM_RULE_PATTERN[$i]}" "${AICM_RULE_DAYS[$i]}" "$dry" ;;
    age-files) run_age_files_rule "$root" "${AICM_RULE_PATTERN[$i]}" "${AICM_RULE_DAYS[$i]}" "$dry" ;;
    cap) run_cap_rule "$root" "${AICM_RULE_PATTERN[$i]}" "${AICM_RULE_DAYS[$i]}" "${AICM_RULE_LIMIT[$i]}" "$dry" ;;
    budget) run_budget_rule "$root" "${AICM_RULE_PATTERN[$i]}" "${AICM_RULE_DAYS[$i]}" "${AICM_RULE_LIMIT[$i]}" "$dry" ;;
    keep-latest) run_keep_latest_rule "$root" "${AICM_RULE_PATTERN[$i]}" "${AICM_RULE_LIMIT[$i]}" "$dry" ;;
    archive) run_archive_rule "$root" "${AICM_RULE_ID[$i]}" "${AICM_RULE_PATTERN[$i]}" "${AICM_RULE_DAYS[$i]}" "${AICM_RULE_LIMIT[$i]}" "$dry" "$DRY_RUN" ;;
    codex) run_codex_rule "$root" "${AICM_RULE_DAYS[$i]}" "${AICM_RULE_LIMIT[$i]}" "$dry" ;;
  esac
}

# Extra JSON members of a budget rule (none for other kinds). A rule that was not scanned (off with no
# folder, refused, a link) reports scanStatus "unavailable".
budget_json() {
  [[ "$kind" == budget ]] || return 0
  printf ',"totalBytes":%s,"budgetBytes":%s,"remainingBytes":%s,"projectedRemainingBytes":%s,"budgetUnmetBytes":%s,"scanStatus":"%s"' \
    "${R_TOTAL:-0}" "$((${AICM_RULE_LIMIT[$i]:-0} * 1048576))" "${R_REMAINING:-0}" "${R_PROJECTED:-0}" "${R_UNMET:-0}" "${R_SCAN:-unavailable}"
}

run_command_rule() {
  local cmd="$1" args="$2" dry="$3" out rc
  if ! command -v "$cmd" >/dev/null 2>&1; then R_STATUS="not installed"; return 0; fi
  if [[ "$dry" == true ]]; then R_STATUS="would run: $cmd $args"; return 0; fi
  # shellcheck disable=SC2086
  out="$("$cmd" $args 2>&1)" && rc=0 || rc=$?
  if ((rc != 0)); then R_STATUS="error: $cmd $args exited with $rc"; return 1; fi
  R_STATUS="ran: $(printf '%s\n' "$out" | awk 'NF { l = $0 } END { print l }')"
}

clock="$(clock_problem)"
if [[ -n "$clock" ]]; then
  echo "problem: $clock"
  # No state is written, so the guard keeps comparing with the last good run.
  if [[ "$DRY_RUN" != true ]]; then aicm_attention clean "cleanup: $clock"; json_bail error 1 "$clock"; fi
fi

errors=()
ran_archive_rule=false
planned_bytes=0; freed_bytes=0; off_bytes=0; archive_bytes=0; archived_bytes=0
rule_json=""
hist_rows=""
json_rules=""
echo
for ((i = 0; i < ${#AICM_RULE_ID[@]}; i++)); do
  id="${AICM_RULE_ID[$i]}"; kind="${AICM_RULE_KIND[$i]}"; raw_path="${AICM_RULE_PATH[$i]}"
  rule_included "$id" || continue
  [[ "$kind" == archive ]] && ran_archive_rule=true
  enabled="${AICM_RULE_ENABLED[$i]}"
  # --rules turns on only the named ids. --category never turns a rule on.
  if [[ -n "$SELECTED" ]] && selected_has "$id"; then enabled=1; fi
  reset_result
  total=""
  shown="$raw_path"
  dry="$DRY_RUN"; [[ "$enabled" == 1 ]] || dry=true

  if [[ "$kind" == command ]]; then
    if [[ "$enabled" != 1 ]]; then R_STATUS=off
    elif ! run_command_rule "$raw_path" "${AICM_RULE_PATTERN[$i]}" "$DRY_RUN"; then errors+=("$id: $R_STATUS"); fi
  else
    root="$(aicm_expand_path "$raw_path")"
    shown="$(aicm_display_path "$root")"
    from_temp=0; [[ "$raw_path" == *"{temp}"* ]] && from_temp=1
    if ! aicm_path_allowed "$root" "$from_temp"; then
      R_STATUS="refused: outside home and temp"; errors+=("$id: path outside home and temp")
    elif [[ -L "$root" ]]; then
      R_STATUS="skipped: path is a link"
    elif [[ ! -d "$root" ]]; then
      R_STATUS="not present"
    else
      [[ "$REPORT" == true ]] && total="$(tree_bytes "$root")"
      # Each rule runs in a subshell, so an unexpected failure in one rule (a full disk, a value it could
      # not read) is reported and the other rules still run. The results come back as variable lines.
      set +e
      rule_out="$(set -e; exec 4>&1 1>&2; run_rule "$i" "$root" "$dry"; for v in $R_VARS; do printf '%s=%q\n' "$v" "${!v}"; done >&4)"
      rc=$?
      set -e
      if ((rc == 0)); then eval "$rule_out"; else R_ERROR="stopped unexpectedly (exit $rc), see the log"; fi
      if [[ -n "$R_ERROR" ]]; then R_STATUS="error: $R_ERROR"; errors+=("$id: $R_ERROR")
      elif [[ "$enabled" != 1 ]]; then R_STATUS=off
      elif [[ "$kind" == codex && "${AICM_RULE_LIMIT[$i]}" == 0 ]]; then
        # limit 0 deletes directly; show it as a deletion, not an archive.
        if [[ "$DRY_RUN" == true ]]; then R_STATUS="would remove"; else R_STATUS=removed; fi
      elif [[ "$kind" == archive || "$kind" == codex ]]; then
        if [[ "$DRY_RUN" == true ]]; then R_STATUS="would archive"; else R_STATUS=archived; fi
      elif [[ "$DRY_RUN" == true ]]; then R_STATUS="would remove"
      else R_STATUS=removed; fi
    fi
  fi

  # Archiving moves files; only deletions free space.
  is_archive=false; [[ "$kind" == archive || "$kind" == codex ]] && is_archive=true
  if [[ "$enabled" != 1 ]]; then
    # An off archive rule still purges expired date folders. Plan those bytes the same way a live rule does.
    if [[ "$is_archive" == true ]]; then
      planned_bytes=$((planned_bytes + R_PURGE_BYTES)); freed_bytes=$((freed_bytes + R_PURGED_BYTES))
    else
      off_bytes=$((off_bytes + R_BYTES))
    fi
  elif [[ "$is_archive" == true ]]; then
    planned_bytes=$((planned_bytes + R_PURGE_BYTES)); freed_bytes=$((freed_bytes + R_PURGED_BYTES))
    archive_bytes=$((archive_bytes + R_BYTES)); archived_bytes=$((archived_bytes + R_REMOVED_BYTES))
  else
    planned_bytes=$((planned_bytes + R_BYTES)); freed_bytes=$((freed_bytes + R_REMOVED_BYTES))
  fi

  unit=files; [[ "$kind" == keep-latest ]] && unit="dirs "
  short=age; [[ "$kind" == cap ]] && short=cap; [[ "$kind" == budget ]] && short=bdgt; [[ "$kind" == keep-latest ]] && short=keep; [[ "$kind" == command ]] && short=cmd
  [[ "$is_archive" == true ]] && short=arch
  direct=false; [[ "$kind" == codex && "${AICM_RULE_LIMIT[$i]}" == 0 ]] && direct=true
  [[ "$direct" == true ]] && short=del
  size_col=""
  if [[ "$direct" == true && "$R_STATUS" == removed ]]; then
    size_col="$(printf '%6s %s %10s' "$R_PURGED" "$unit" "$(aicm_format_size "$R_PURGED_BYTES")")"
  elif [[ "$direct" == true ]]; then
    size_col="$(printf '%6s %s %10s' "$R_PURGE" "$unit" "$(aicm_format_size "$R_PURGE_BYTES")")"
  elif [[ "$kind" != command ]]; then
    if [[ "$R_STATUS" == removed || "$R_STATUS" == archived ]]; then
      size_col="$(printf '%6s %s %10s' "$R_REMOVED" "$unit" "$(aicm_format_size "$R_REMOVED_BYTES")")"
    else
      size_col="$(printf '%6s %s %10s' "$R_FILES" "$unit" "$(aicm_format_size "$R_BYTES")")"
    fi
  fi
  total_col=""; [[ -n "$total" ]] && total_col="$(printf '  of %10s' "$(aicm_format_size "$total")")"
  busy=""; ((R_IN_USE > 0)) && busy=" ($R_IN_USE in use or failed, kept)"
  purge_text=""
  if [[ "$is_archive" == true && "$direct" != true && "$R_STATUS" != "not present" && "$R_STATUS" != refused* ]]; then
    if [[ "$R_STATUS" == archived ]]; then purge_text="; deleted from archive: $R_PURGED ($(aicm_format_size "$R_PURGED_BYTES"))"
    else purge_text="; would delete from archive: $R_PURGE ($(aicm_format_size "$R_PURGE_BYTES"))"; fi
  fi
  printf '%-22s %-4s %-22s%s  %s%s%s  %s\n' "$id" "$short" "$size_col" "$total_col" "$R_STATUS" "$purge_text" "$busy" "$shown"
  if [[ "$kind" == budget && -n "$R_SCAN" ]]; then
    if [[ "$DRY_RUN" == true || "$enabled" != 1 ]]; then after="projected $(aicm_format_size "$R_PROJECTED")"; else after="now $(aicm_format_size "$R_REMAINING")"; fi
    printf '%-22s %s\n' "" "budget $(aicm_format_size "$R_BUDGET"): total $(aicm_format_size "$R_TOTAL"), $after (scan $R_SCAN, logical bytes)"
  fi
  [[ -n "$R_DETAIL" ]] && printf '%-22s %s\n' "" "$R_DETAIL"

  rule_json+="${rule_json:+,}{\"id\":\"$(aicm_json_escape "$id")\",\"status\":\"$(aicm_json_escape "$R_STATUS")\",\"removed\":$R_REMOVED,\"removedBytes\":$R_REMOVED_BYTES,\"purged\":$R_PURGED,\"purgedBytes\":$R_PURGED_BYTES,\"inUse\":$R_IN_USE}"
  hact=kept
  case "$R_STATUS" in
    archived) hact=archived ;;
    removed) hact=deleted ;;
    off) hact=skipped ;;
    error*) hact=error ;;
  esac
  hist_rows+="${hist_rows:+,}{\"rule\":\"$(aicm_json_escape "$id")\",\"action\":\"$hact\",\"status\":\"$hact\",\"path\":\"$(aicm_json_escape "$shown")\",\"bytes\":${R_REMOVED_BYTES:-0}}"
  if [[ "$JSON" == true ]]; then
    if [[ "$direct" == true ]]; then cand="$R_PURGE"; cand_bytes="$R_PURGE_BYTES"; else cand="$R_FILES"; cand_bytes="$R_BYTES"; fi
    en_json=false; [[ "$enabled" == 1 ]] && en_json=true
    reason="$(aicm_rule_reason "$id" "$kind" "${AICM_RULE_DAYS[$i]}" "${AICM_RULE_NOTE[$i]}")"
    json_rules+="${json_rules:+,}{\"id\":\"$(aicm_json_escape "$id")\",\"category\":\"$(aicm_rule_category "$id")\",\"path\":\"$(aicm_json_escape "$shown")\",\"action\":\"$(aicm_rule_action "$kind" "${AICM_RULE_LIMIT[$i]}")\",\"reason\":\"$(aicm_json_escape "$reason")\",\"days\":${AICM_RULE_DAYS[$i]:-0},\"limit\":${AICM_RULE_LIMIT[$i]:-0},\"protection\":\"$(aicm_json_escape "$(aicm_protection_policy)")\",\"status\":\"$(aicm_json_escape "$R_STATUS")\",\"enabled\":$en_json,\"candidates\":${cand:-0},\"candidateBytes\":${cand_bytes:-0},\"purgeCandidates\":${R_PURGE:-0},\"purgeCandidateBytes\":${R_PURGE_BYTES:-0},\"removed\":${R_REMOVED:-0},\"removedBytes\":${R_REMOVED_BYTES:-0},\"purged\":${R_PURGED:-0},\"purgedBytes\":${R_PURGED_BYTES:-0},\"inUse\":${R_IN_USE:-0}$(budget_json)}"
  fi
done

echo
if [[ "$DRY_RUN" == true ]]; then
  echo "reclaimable now: $(aicm_format_size "$planned_bytes")   to archive: $(aicm_format_size "$archive_bytes")"
else
  echo "freed: $(aicm_format_size "$freed_bytes")   archived: $(aicm_format_size "$archived_bytes") (in $(aicm_display_path "$AICM_HOME/archive") and ~/.codex/archived_sessions)"
fi
if ((off_bytes > 0)); then
  echo "also reclaimable by rules that are off: $(aicm_format_size "$off_bytes") (turn on in $(aicm_display_path "$LOCAL_RULES_FILE"))"
fi

# Index records of archives the retention purge removed (or restored long ago) are dropped under the
# same maintenance lease, so the index does not grow without bound. Only after a real run that included
# an archive rule. Housekeeping: a failure is reported, not counted as a cleanup error.
if [[ "$DRY_RUN" != true && "$ran_archive_rule" == true && -d "$AICM_HOME/state/archive-index" && -f "$AICM_ROOT/lib/maintenance.js" ]] &&
   command -v node >/dev/null 2>&1; then
  if gc_out="$(aicm_timeout 300 node "$AICM_ROOT/lib/maintenance.js" archive-gc 2>&1)"; then echo "$gc_out"
  else echo "warning: archive index cleanup failed: $(printf '%s' "$gc_out" | tr '\n' ' ' | head -c 300)"; fi
fi

exit_code=0
((${#errors[@]})) && exit_code=1

if [[ "$DRY_RUN" != true ]]; then
  err_json=""
  if ((${#errors[@]})); then
    for e in "${errors[@]}"; do err_json+="${err_json:+,}\"$(aicm_json_escape "$e")\""; done
  fi
  ok=true; ((exit_code == 0)) || ok=false
  scope_rules="${SELECTED// /}"
  aicm_state_write last-clean "{\"finishedAt\":\"$(aicm_ts)\",\"version\":\"$(aicm_version)\",\"ok\":$ok,\"freedBytes\":$freed_bytes,\"archivedBytes\":$archived_bytes,\"scopeCategories\":\"$(aicm_json_escape "$CATEGORY_NORM")\",\"scopeRules\":\"$(aicm_json_escape "$scope_rules")\",\"errors\":[$err_json],\"rules\":[$rule_json]}"
  hist="$(mktemp)"
  printf '%s\n' "{\"summary\":{\"files\":0,\"bytes\":${freed_bytes:-0},\"removed\":0,\"archived\":${archived_bytes:-0},\"restored\":0,\"purged\":0,\"errors\":${#errors[@]},\"conflicts\":0},\"results\":[${hist_rows}]}" > "$hist"
  aicm_record_history clean "$hist"
  rm -f "$hist"
  if [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] && ((LOG_RETENTION_DAYS > 0)); then
    find "$LOG_DIR" -type f -name 'clean-*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
  fi
fi

problems=()
if ((${#errors[@]})); then problems+=("${errors[@]}"); fi
# Worktrees are part of a full cleanup only. A category, a rule list, a report or an
# explain/json preview must not start that scan or apply it.
run_worktrees=true
[[ "${AICM_WORKTREES:-1}" == 0 || "$REPORT" == true || "$EXPLAIN" == true || -n "$SELECTED" || "$CAT_FILTER" == true ]] && run_worktrees=false
[[ "$JSON" == true && "$DRY_RUN" == true ]] && run_worktrees=false
if [[ "$run_worktrees" == true ]]; then
  echo
  echo "== worktrees and branches =="
  if [[ "$DRY_RUN" == true ]]; then aicm_node_module worktrees; else aicm_node_module worktrees --apply; fi
  if ((${#AICM_NODE_ATTENTION[@]})); then problems+=("${AICM_NODE_ATTENTION[@]}"); fi
fi
while IFS= read -r p; do [[ -n "$p" ]] && problems+=("$p"); done < <(aicm_schedule_problems clean)
if ((${#problems[@]})); then
  for p in "${problems[@]}"; do echo "problem: $p"; done
fi
if [[ "$DRY_RUN" != true ]]; then
  notes=()
  if ((${#problems[@]})); then for p in "${problems[@]}"; do notes+=("cleanup: $p"); done; fi
  aicm_attention clean ${notes[@]+"${notes[@]}"}
fi

if [[ "$REPORT" != true ]]; then
  echo "[$(aicm_ts)] AI leftover cleanup finished (exit=$exit_code)"
fi
if [[ "$JSON" == true ]]; then
  dry_json=false; [[ "$DRY_RUN" == true ]] && dry_json=true
  cat_json="[]"
  if [[ -n "$CATEGORY_NORM" ]]; then
    cat_json=""
    IFS=',' read -r -a cat_parts <<< "$CATEGORY_NORM"
    for c in "${cat_parts[@]}"; do cat_json+="${cat_json:+,}\"$c\""; done
    cat_json="[$cat_json]"
  fi
  err_out=""
  if ((${#errors[@]})); then
    for e in "${errors[@]}"; do err_out+="${err_out:+,}\"$(aicm_json_escape "$e")\""; done
  fi
  printf '%s\n' "{\"schemaVersion\":1,\"dryRun\":$dry_json,\"categories\":$cat_json,\"rules\":[${json_rules}],\"summary\":{\"plannedBytes\":${planned_bytes:-0},\"freedBytes\":${freed_bytes:-0},\"archivedBytes\":${archived_bytes:-0}},\"errors\":[$err_out]}" >&3
fi
exit "$exit_code"
