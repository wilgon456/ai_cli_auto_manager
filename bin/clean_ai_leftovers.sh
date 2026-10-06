#!/usr/bin/env bash
# Removes stale AI coding CLI leftovers (old transcripts, temp files, caches) on macOS and Linux.
#
# Rules come from rules/clean-rules.conf plus ~/.ai-cli-auto-manager/clean-rules.local.conf.
# Only files older than each rule's age are removed. Symlinks are never followed,
# protected files (memory, credentials, settings) are never removed.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/aicm-common.sh
. "$SCRIPT_DIR/../lib/aicm-common.sh"

DRY_RUN=false
REPORT=false
SELECTED=""
RULES_FILE="$AICM_ROOT/rules/clean-rules.conf"
LOCAL_RULES_FILE="$AICM_HOME/clean-rules.local.conf"
LOG_DIR="${AICM_LOG_DIR:-$AICM_HOME/logs}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--report] [--rules id,id] [--rules-file FILE] [--local-rules-file FILE]

  --dry-run   show what would be removed, change nothing
  --report    like --dry-run, also show each folder's total size
  --rules     run only these rule ids (runs them even if they are off)
EOF
}

while (($#)); do
  case "$1" in
    --dry-run|--check) DRY_RUN=true ;;
    --report) REPORT=true; DRY_RUN=true ;;
    --rules) shift; SELECTED="${1:-}" ;;
    --rules=*) SELECTED="${1#--rules=}" ;;
    --rules-file) shift; RULES_FILE="${1:-}" ;;
    --local-rules-file) shift; LOCAL_RULES_FILE="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

aicm_load_rules "$RULES_FILE" "$LOCAL_RULES_FILE" || exit 2

selected_has() {
  [[ -n "$SELECTED" ]] || return 1
  [[ ",${SELECTED// /}," == *",$1,"* ]]
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

LOCK_DIR="$(aicm_temp_dir)/ai-cli-auto-manager-clean.lockdir"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  if [[ -f "$LOCK_DIR/pid" ]] && kill -0 "$(cat "$LOCK_DIR/pid" 2>/dev/null)" 2>/dev/null; then
    echo "[$(aicm_ts)] another cleanup run is already active"
    exit 0
  fi
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
  mkdir "$LOCK_DIR" 2>/dev/null || { echo "[$(aicm_ts)] another cleanup run is already active"; exit 0; }
fi
printf '%s\n' "$$" > "$LOCK_DIR/pid"
trap 'rm -f "$LOCK_DIR/pid" 2>/dev/null || true; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

if [[ "$REPORT" != true ]]; then
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/clean-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "[$(aicm_ts)] AI leftover cleanup started (mode=$([[ "$DRY_RUN" == true ]] && echo dry-run || echo clean), version=$(aicm_version))"
fi

# Per-rule results, set by the rule functions.
R_FILES=0; R_BYTES=0; R_REMOVED=0; R_REMOVED_BYTES=0; R_IN_USE=0; R_STATUS=""
R_PURGE=0; R_PURGE_BYTES=0; R_PURGED=0; R_PURGED_BYTES=0; R_DETAIL=""

reset_result() {
  R_FILES=0; R_BYTES=0; R_REMOVED=0; R_REMOVED_BYTES=0; R_IN_USE=0; R_STATUS=""
  R_PURGE=0; R_PURGE_BYTES=0; R_PURGED=0; R_PURGED_BYTES=0; R_DETAIL=""
}

tree_bytes() {
  find "$1" -type f -print0 2>/dev/null | aicm_sizes_stdin | aicm_sum_lines
}

file_bytes() {
  printf '%s\0' "$1" | aicm_sizes_stdin | aicm_sum_lines
}

# Deletes the NUL-separated file list in $1, updating R_REMOVED / R_REMOVED_BYTES / R_IN_USE.
remove_listed_files() {
  local list="$1" f size
  while IFS= read -r -d '' f; do
    size="$(file_bytes "$f")"
    if rm -f -- "$f" 2>/dev/null && [[ ! -e "$f" ]]; then
      R_REMOVED=$((R_REMOVED + 1)); R_REMOVED_BYTES=$((R_REMOVED_BYTES + size))
    else
      R_IN_USE=$((R_IN_USE + 1))
    fi
  done < "$list"
}

run_age_rule() {
  local root="$1" pattern="$2" days="$3" dry="$4" list
  list="$(mktemp)"
  find "$root" -type f -name "$pattern" -mmin +"$((days * 1440))" "${AICM_PROTECT_ARGS[@]}" -print0 2>/dev/null > "$list" || true
  R_FILES="$(tr -cd '\0' < "$list" | wc -c | tr -d ' ')"
  R_BYTES="$(aicm_sizes_stdin < "$list" | aicm_sum_lines)"
  if [[ "$dry" != true ]]; then
    remove_listed_files "$list"
    find "$root" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  fi
  rm -f "$list"
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
    for side in "$f-wal" "$f-shm" "$f-journal"; do [[ -f "$side" && ! -L "$side" ]] && group+=("$side"); done
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
    # rm -rf removes symlinks inside the tree as links; it never follows them.
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
  [[ -d "$adir" ]] || return 0
  cutoff="$(aicm_date_days_ago "$days")"
  for d in "$adir"/*; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    name="$(basename "$d")"
    [[ "$name" =~ ^[0-9]{8}$ ]] || continue
    ((10#$name < 10#$cutoff)) || continue
    bytes="$(tree_bytes "$d")"
    R_PURGE=$((R_PURGE + 1)); R_PURGE_BYTES=$((R_PURGE_BYTES + bytes))
    [[ "$dry" == true ]] && continue
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
    while IFS= read -r -d '' f; do
      rel="${f#"$root"/}"
      target="$dest/$rel"
      mkdir -p "$(dirname "$target")"
      [[ -e "$target" ]] && target="$target.$$"
      size="$(file_bytes "$f")"
      if mv -- "$f" "$target" 2>/dev/null; then
        R_REMOVED=$((R_REMOVED + 1)); R_REMOVED_BYTES=$((R_REMOVED_BYTES + size))
      else
        R_IN_USE=$((R_IN_USE + 1))
      fi
    done < "$list"
    find "$root" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  fi
  rm -f "$list"
  purge_archive "$AICM_HOME/archive/$id" "$limit" "$purge_dry"
}

codex_id() { [[ "$1" =~ ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}) ]] && printf '%s' "${BASH_REMATCH[1]}"; }

# Codex keeps every session in its own database as well as in rollout files, so files are never
# deleted directly: `codex archive` after <days>, `codex delete --force` once a session has been
# unused for <days> + <limit>. Threads whose file is already gone count as archived and are deleted
# on the same schedule (needs sqlite3 or python3 to read the database; skipped otherwise).
run_codex_rule() { # root days limit dry
  local root="$1" days="$2" limit="$3" dry="$4" codex arch del threads f cid now cut id rollout updated _archived size orphans=()
  if ! codex="$(command -v codex 2>/dev/null)"; then R_DETAIL="codex command not found: nothing touched"; return 0; fi
  arch="$(mktemp)"; del="$(mktemp)"; threads="$(mktemp)"
  [[ -d "$root/sessions" ]] && find "$root/sessions" -type f -name 'rollout-*' -mmin +"$((days * 1440))" -print0 2>/dev/null > "$arch"
  [[ -d "$root/archived_sessions" ]] && find "$root/archived_sessions" -type f -name 'rollout-*' -mmin +"$(((days + limit) * 1440))" -print0 2>/dev/null > "$del"
  # limit 0: no archive stage, sessions unused for <days> are deleted right away.
  if ((limit == 0)); then cat "$arch" >> "$del"; : > "$arch"; fi
  if aicm_codex_threads "$root" > "$threads"; then
    now="$(date +%s)"; cut=$((now - (days + limit) * 86400))
    while IFS=$'\t' read -r id rollout updated _archived; do
      [[ -n "$id" && -n "$rollout" && -n "$updated" ]] || continue
      updated="${updated%%.*}"; ((updated > 100000000000)) && updated=$((updated / 1000))
      [[ ! -e "$rollout" ]] && ((updated < cut)) && orphans+=("$id")
    done < "$threads"
  else
    R_DETAIL="Codex database not read (sqlite3/python3 not found): sessions whose file is already gone are left alone"
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
  rm -f "$arch" "$del" "$threads"
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

errors=()
planned_bytes=0; freed_bytes=0; off_bytes=0; archive_bytes=0; archived_bytes=0
rule_json=""
echo
for ((i = 0; i < ${#AICM_RULE_ID[@]}; i++)); do
  id="${AICM_RULE_ID[$i]}"; kind="${AICM_RULE_KIND[$i]}"; raw_path="${AICM_RULE_PATH[$i]}"
  if [[ -n "$SELECTED" ]] && ! selected_has "$id"; then continue; fi
  enabled="${AICM_RULE_ENABLED[$i]}"
  selected_has "$id" && enabled=1
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
    if ! aicm_path_allowed "$root"; then
      R_STATUS="refused: outside home and temp"; errors+=("$id: path outside home and temp")
    elif [[ -L "$root" ]]; then
      R_STATUS="skipped: path is a link"
    elif [[ ! -d "$root" ]]; then
      R_STATUS="not present"
    else
      [[ "$REPORT" == true ]] && total="$(tree_bytes "$root")"
      case "$kind" in
        age) run_age_rule "$root" "${AICM_RULE_PATTERN[$i]}" "${AICM_RULE_DAYS[$i]}" "$dry" ;;
        cap) run_cap_rule "$root" "${AICM_RULE_PATTERN[$i]}" "${AICM_RULE_DAYS[$i]}" "${AICM_RULE_LIMIT[$i]}" "$dry" ;;
        keep-latest) run_keep_latest_rule "$root" "${AICM_RULE_PATTERN[$i]}" "${AICM_RULE_LIMIT[$i]}" "$dry" ;;
        archive) run_archive_rule "$root" "$id" "${AICM_RULE_PATTERN[$i]}" "${AICM_RULE_DAYS[$i]}" "${AICM_RULE_LIMIT[$i]}" "$dry" "$DRY_RUN" ;;
        codex) run_codex_rule "$root" "${AICM_RULE_DAYS[$i]}" "${AICM_RULE_LIMIT[$i]}" "$dry" ;;
      esac
      if [[ "$enabled" != 1 ]]; then R_STATUS=off
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
    if [[ "$is_archive" == true ]]; then freed_bytes=$((freed_bytes + R_PURGED_BYTES)); else off_bytes=$((off_bytes + R_BYTES)); fi
  elif [[ "$is_archive" == true ]]; then
    planned_bytes=$((planned_bytes + R_PURGE_BYTES)); freed_bytes=$((freed_bytes + R_PURGED_BYTES))
    archive_bytes=$((archive_bytes + R_BYTES)); archived_bytes=$((archived_bytes + R_REMOVED_BYTES))
  else
    planned_bytes=$((planned_bytes + R_BYTES)); freed_bytes=$((freed_bytes + R_REMOVED_BYTES))
  fi

  unit=files; [[ "$kind" == keep-latest ]] && unit="dirs "
  short=age; [[ "$kind" == cap ]] && short=cap; [[ "$kind" == keep-latest ]] && short=keep; [[ "$kind" == command ]] && short=cmd
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
  [[ -n "$R_DETAIL" ]] && printf '%-22s %s\n' "" "$R_DETAIL"

  rule_json+="${rule_json:+,}{\"id\":\"$(aicm_json_escape "$id")\",\"status\":\"$(aicm_json_escape "$R_STATUS")\",\"removed\":$R_REMOVED,\"removedBytes\":$R_REMOVED_BYTES,\"purged\":$R_PURGED,\"purgedBytes\":$R_PURGED_BYTES,\"inUse\":$R_IN_USE}"
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

exit_code=0
((${#errors[@]})) && exit_code=1

if [[ "$DRY_RUN" != true ]]; then
  err_json=""
  if ((${#errors[@]})); then
    for e in "${errors[@]}"; do err_json+="${err_json:+,}\"$(aicm_json_escape "$e")\""; done
  fi
  ok=true; ((exit_code == 0)) || ok=false
  aicm_state_write last-clean "{\"finishedAt\":\"$(aicm_ts)\",\"version\":\"$(aicm_version)\",\"ok\":$ok,\"freedBytes\":$freed_bytes,\"archivedBytes\":$archived_bytes,\"errors\":[$err_json],\"rules\":[$rule_json]}"
  if [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] && ((LOG_RETENTION_DAYS > 0)); then
    find "$LOG_DIR" -type f -name 'clean-*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
  fi
fi

problems=()
if ((${#errors[@]})); then problems+=("${errors[@]}"); fi
# Worktrees and branches agents left behind (lib/worktrees.js). Skipped when single rules are run.
if [[ "${AICM_WORKTREES:-1}" != 0 && "$REPORT" != true && -z "$SELECTED" ]]; then
  echo
  echo "== worktrees and branches =="
  if [[ "$DRY_RUN" == true ]]; then aicm_node_module worktrees; else aicm_node_module worktrees --apply; fi
  if ((${#AICM_NODE_ATTENTION[@]})); then problems+=("${AICM_NODE_ATTENTION[@]}"); fi
fi
while IFS= read -r p; do [[ -n "$p" ]] && problems+=("$p"); done < <(aicm_schedule_problems clean)
if ((${#problems[@]})); then
  for p in "${problems[@]}"; do echo "problem: $p"; done
  if [[ "$DRY_RUN" != true ]]; then
    joined="$(printf '%s; ' "${problems[@]}")"
    aicm_notify "AI CLI Auto Manager" "cleanup needs attention: ${joined%; }"
  fi
fi

if [[ "$REPORT" != true ]]; then
  echo "[$(aicm_ts)] AI leftover cleanup finished (exit=$exit_code)"
fi
exit "$exit_code"
