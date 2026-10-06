#!/usr/bin/env bash
# Lists the AI coding CLIs installed on this macOS/Linux machine (weekly job of AI CLI Auto Manager).
#
# Looks for every CLI in rules/ai-clis.conf (plus ~/.ai-cli-auto-manager/ai-clis.local.conf) and reports
# its version, the latest published version, how it was installed, whether the daily update keeps it
# current, and stale npm copies hidden behind another copy on PATH. Writes
# ~/.ai-cli-auto-manager/inventory.md and state/inventory.json, and raises a desktop notification
# when a CLI appeared or disappeared since the last run.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/aicm-common.sh
. "$SCRIPT_DIR/../lib/aicm-common.sh"

OFFLINE=false
CATALOG_FILE="$AICM_ROOT/rules/ai-clis.conf"
LOCAL_CATALOG_FILE="$AICM_HOME/ai-clis.local.conf"
LOG_DIR="${AICM_LOG_DIR:-$AICM_HOME/logs}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

while (($#)); do
  case "$1" in
    --offline) OFFLINE=true ;;
    --catalog-file) shift; CATALOG_FILE="${1:-}" ;;
    --local-catalog-file) shift; LOCAL_CATALOG_FILE="${1:-}" ;;
    -h|--help) echo "Usage: $(basename "$0") [--offline] [--catalog-file FILE] [--local-catalog-file FILE]"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$LOG_DIR" "$AICM_HOME/state"
LOG_FILE="$LOG_DIR/inventory-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[$(aicm_ts)] AI CLI inventory started (version=$(aicm_version), offline=$OFFLINE)"
if ! aicm_load_catalog "$CATALOG_FILE" "$LOCAL_CATALOG_FILE"; then
  aicm_notify "AI CLI Auto Manager" "inventory failed: catalog error"
  exit 1
fi

rows_tsv=""
rows_json=""
count=0
printf '\n%-20s %-11s %-14s %-14s %-9s %s\n' CLI via version latest state "daily update"
for ((i = 0; i < ${#AICM_CLI_ID[@]}; i++)); do
  aicm_cli_install "$i"
  [[ "$CLI_INSTALLED" == true ]] || continue
  count=$((count + 1))
  id="${AICM_CLI_ID[$i]}"; name="${AICM_CLI_NAME[$i]}"; npm_pkg="${AICM_CLI_NPM[$i]}"
  version=""
  if [[ -x "$CLI_PATH" ]]; then
    version="$(aicm_timeout 15 "$CLI_PATH" --version 2>&1 | aicm_semver || true)"
  fi
  if [[ -z "$version" && "$CLI_METHOD" == npm ]]; then version="$(aicm_npm_pkg_version "$npm_pkg")"; fi
  latest=""
  if [[ "$OFFLINE" != true && -n "$npm_pkg" && -n "$AICM_NPM_CMD" ]]; then
    latest="$(aicm_timeout 30 "$AICM_NPM_CMD" view "$npm_pkg" version 2>/dev/null | aicm_semver || true)"
  fi
  if [[ -z "$version" ]]; then state=unknown
  elif [[ -z "$latest" ]]; then state=installed
  elif aicm_version_older "$version" "$latest"; then state=behind
  else state=current; fi
  coverage="$(aicm_cli_coverage "$i")"
  printf '%-20s %-11s %-14s %-14s %-9s %s\n' "$name" "$CLI_METHOD" "$version" "$latest" "$state" "$coverage"
  [[ -n "$CLI_NPMCOPY" ]] && printf '%-20s npm copy %s is also installed, but PATH runs %s\n' "" "$CLI_NPMCOPY" "$CLI_PATH"
  rows_tsv+="$id"$'\t'"$name"$'\t'"$version"$'\n'
  rows_json+="${rows_json:+,}{\"id\":\"$(aicm_json_escape "$id")\",\"name\":\"$(aicm_json_escape "$name")\",\"command\":\"$(aicm_json_escape "${AICM_CLI_CMD[$i]}")\",\"method\":\"$CLI_METHOD\",\"version\":\"$(aicm_json_escape "$version")\",\"latest\":\"$(aicm_json_escape "$latest")\",\"state\":\"$state\",\"autoUpdate\":\"$(aicm_json_escape "$coverage")\",\"npmCopy\":\"$(aicm_json_escape "$CLI_NPMCOPY")\",\"path\":\"$(aicm_json_escape "$CLI_PATH")\"}"
  md_rows+="| $name | $CLI_METHOD | $version | $latest | $state | $coverage | $CLI_PATH${CLI_NPMCOPY:+ (stale npm copy $CLI_NPMCOPY also installed)} |"$'\n'
done

# Global npm packages that are not in the catalog.
known=" "
for ((i = 0; i < ${#AICM_CLI_ID[@]}; i++)); do [[ -n "${AICM_CLI_NPM[$i]}" ]] && known+="${AICM_CLI_NPM[$i]} "; done
other_npm=""
while read -r pkg ver; do
  [[ -z "$pkg" || "$known" == *" $pkg "* || " npm corepack pnpm yarn " == *" $pkg "* ]] && continue
  other_npm+="${other_npm:+, }$pkg $ver"
done < <(aicm_npm_globals)

echo
echo "$count AI CLIs installed (catalog has ${#AICM_CLI_ID[@]})"
[[ -n "$other_npm" ]] && echo "other global npm packages: $other_npm"

# Compare with the previous inventory.
changes=()
prev="$AICM_HOME/state/inventory.tsv"
if [[ -f "$prev" ]]; then
  while IFS=$'\t' read -r id name version; do
    [[ -n "$id" ]] || continue
    old="$(awk -F '\t' -v id="$id" '$1 == id { print $3; found = 1 } END { if (!found) print "\001" }' "$prev")"
    if [[ "$old" == $'\001' ]]; then changes+=("new: $name $version")
    elif [[ "$old" != "$version" ]]; then changes+=("updated: $name $old -> $version"); fi
  done <<< "$rows_tsv"
  while IFS=$'\t' read -r id name _; do
    [[ -n "$id" ]] || continue
    printf '%s' "$rows_tsv" | awk -F '\t' -v id="$id" '$1 == id { f = 1 } END { exit !f }' || changes+=("removed: $name")
  done < "$prev"
fi
if ((${#changes[@]})); then
  echo
  echo "changes since the last inventory:"
  for c in "${changes[@]}"; do echo "  $c"; done
fi

printf '%s' "$rows_tsv" > "$prev"
changes_json=""
if ((${#changes[@]})); then
  for c in "${changes[@]}"; do changes_json+="${changes_json:+,}\"$(aicm_json_escape "$c")\""; done
fi
aicm_state_write inventory "{\"finishedAt\":\"$(aicm_ts)\",\"version\":\"$(aicm_version)\",\"ok\":true,\"host\":\"$(aicm_json_escape "$(hostname 2>/dev/null || echo unknown)")\",\"clis\":[${rows_json}],\"otherNpm\":\"$(aicm_json_escape "$other_npm")\",\"changes\":[${changes_json}]}"

md="$AICM_HOME/inventory.md"
{
  echo "# AI CLI inventory - $(hostname 2>/dev/null || echo this machine)"
  echo
  echo "Updated $(date '+%Y-%m-%d %H:%M') by AI CLI Auto Manager $(aicm_version)."
  echo
  echo "| CLI | via | version | latest | state | daily update | path |"
  echo "| --- | --- | --- | --- | --- | --- | --- |"
  printf '%s' "${md_rows:-}"
  [[ -n "$other_npm" ]] && printf '\nOther global npm packages: %s\n' "$other_npm"
  if ((${#changes[@]})); then
    printf '\nChanges since the last inventory:\n'
    for c in "${changes[@]}"; do echo "- $c"; done
  fi
} > "$md"
echo
echo "report: $md"

attention=()
if ((${#changes[@]})); then
  for c in "${changes[@]}"; do [[ "$c" == updated:* ]] || attention+=("$c"); done
fi
while IFS= read -r p; do [[ -n "$p" ]] && { echo "problem: $p"; attention+=("$p"); }; done < <(aicm_schedule_problems inventory)
if ((${#attention[@]})); then
  joined="$(printf '%s; ' "${attention[@]}")"
  aicm_notify "AI CLI Auto Manager" "${joined%; }"
fi

if [[ "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]] && ((LOG_RETENTION_DAYS > 0)); then
  find "$LOG_DIR" -type f -name 'inventory-*.log' -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
fi
echo "[$(aicm_ts)] AI CLI inventory finished"
