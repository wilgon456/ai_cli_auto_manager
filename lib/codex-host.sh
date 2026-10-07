# shellcheck shell=bash
# Recycle Codex app-servers that still have a replaced Homebrew Codex mapped. Sourced by
# bin/update_ai_clis.sh after lib/aicm-common.sh (it uses aicm_realpath).
#
# `brew upgrade --cask codex` removes /usr/local/Caskroom/codex/<old>/. A long-lived `codex app-server`
# keeps that binary open and spawns <old>/bin/codex-code-mode-host, which no longer exists, so its
# terminal tools stop working. The new host is installed beside the new binary; restarting the server
# is what makes them work again.
#
# Paseo supervises one of these servers. Others are reparented to launchd or init (ppid 1) and survive
# `paseo restart`, so those are stopped directly. The ChatGPT.app bundle carries its own host and is
# left alone.

codex_server_is_stale() {
  local current="$1" mapped="$2"
  [[ -n "$current" && -n "$mapped" ]] || return 1
  [[ "$mapped" == "$current" ]] && return 1
  [[ "$mapped" == *"/ChatGPT.app/"* ]] && return 1
  return 0
}

# lsof -Fn prints one "n<path>" field per line. Keep the codex executable and drop dyld and the host.
# After Homebrew unlinks a cask file, the name can end with " (deleted)".
codex_path_from_lsof_fn() {
  local line path
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == n* ]] || continue
    path="${line#n}"
    path="${path%" (deleted)"}"
    [[ "$path" == */codex ]] || continue
    printf '%s\n' "$path"
    return 0
  done
  return 1
}

codex_mapped_binary() {
  lsof -nP -a -p "$1" -d txt -Fn 2>/dev/null | codex_path_from_lsof_fn || true
}

# Fills CODEX_STALE_PIDS. Human-readable status goes to stdout.
codex_collect_stale_pids() {
  local current="$1" pid mapped command
  CODEX_STALE_PIDS=()
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    mapped="$(codex_mapped_binary "$pid")"
    if codex_server_is_stale "$current" "$mapped"; then
      echo "stale codex app-server pid=$pid mapped=$mapped"
      CODEX_STALE_PIDS+=("$pid")
    elif [[ -n "$mapped" ]]; then
      echo "current codex app-server pid=$pid"
    else
      command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      if [[ "$command" == *"/codex app-server"* || "$command" == *" codex app-server"* ]]; then
        echo "warn: could not read the executable mapped by codex app-server pid=$pid"
      fi
    fi
  done < <(ps -axo pid=,command= | awk 'index($0, "codex") && index($0, "app-server") { print $1 }')
}

recycle_stale_codex_app_servers() {
  local codex_cmd current host rc
  codex_cmd="$(command -v codex 2>/dev/null || true)"
  if [[ -z "$codex_cmd" ]]; then
    echo "pass: codex command not found"
    return 0
  fi
  current="$(aicm_realpath "$codex_cmd")"
  host="$(dirname "$current")/codex-code-mode-host"
  echo "codex: $current"
  if [[ ! -x "$host" ]]; then
    echo "pass: no code-mode host beside the current Codex binary ($host)"
    return 0
  fi

  codex_collect_stale_pids "$current"
  if ((${#CODEX_STALE_PIDS[@]} == 0)); then
    echo "pass: no stale codex app-server"
    return 0
  fi

  if command -v paseo >/dev/null 2>&1; then
    echo "restarting the Paseo daemon so its Codex app-server loads $current"
    rc=0
    paseo restart --timeout 120 || rc=$?
    ((rc == 0)) || echo "warn: paseo restart rc=$rc"
    codex_collect_stale_pids "$current"
  fi

  if ((${#CODEX_STALE_PIDS[@]} > 0)); then
    echo "stopping app-servers that still map a replaced Codex: ${CODEX_STALE_PIDS[*]}"
    kill -TERM "${CODEX_STALE_PIDS[@]}" 2>/dev/null || true
    sleep 1
    codex_collect_stale_pids "$current"
  fi

  if ((${#CODEX_STALE_PIDS[@]} > 0)); then
    echo "error: stale codex app-servers remain: ${CODEX_STALE_PIDS[*]}"
    return 1
  fi
  echo "pass: stale codex app-servers recycled"
}
