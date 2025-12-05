#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========

BASE_URL="${GDT_BASE_URL:-https://fix.geekcom.org}"

CFG_DIR="${HOME}/.scripts/geekcom-deck-tools"
WG_CONF="${CFG_DIR}/client.conf"

SESSION_ID=""
HAVE_SESSION=0
TUNNEL_UP=0
FINISH_SENT=0

GDT_SUDO_PASS="${GDT_SUDO_PASS:-}"

mkdir -p "$CFG_DIR"

# ========= UTILS =========

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERR] Command '$1' not found. Install it and retry." >&2
    exit 1
  fi
}

json_get() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.[$k] // empty'
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$key" << 'PY'
import sys, json
key = sys.argv[1]
data = sys.stdin.read()
try:
    obj = json.loads(data)
    val = obj.get(key, "")
    if val is None:
        val = ""
    if not isinstance(val, str):
        val = str(val)
    sys.stdout.write(val)
except Exception:
    pass
PY
  else
    echo "[ERR] Need jq or python3 to parse JSON." >&2
    exit 1
  fi
}

run_sudo() {
  printf '%s\n' "$GDT_SUDO_PASS" | sudo -S -p '' -- "$@"
}

flush_dns() {
  if command -v resolvectl >/dev/null 2>&1; then
    run_sudo resolvectl flush-caches || true
  elif command -v systemd-resolve >/dev/null 2>&1; then
    run_sudo systemd-resolve --flush-caches || true
  fi
}

# ========= SUDO HANDLING =========

read_sudo_password() {
  if [[ -n "$GDT_SUDO_PASS" ]]; then
    if printf '%s\n' "$GDT_SUDO_PASS" | sudo -S -k -p '' true >/dev/null 2>&1; then
      echo "[INFO] Using sudo password from environment."
      return 0
    else
      echo "[ERR] Provided sudo password is not valid." >&2
      exit 1
    fi
  fi

  printf "Enter sudo password (input will be hidden): " > /dev/tty
  stty -echo </dev/tty
  IFS= read -r GDT_SUDO_PASS </dev/tty || true
  stty echo </dev/tty
  printf "\n" > /dev/tty

  if [[ -z "$GDT_SUDO_PASS" ]]; then
    echo "[ERR] Empty sudo password." >&2
    exit 1
  fi

  if ! printf '%s\n' "$GDT_SUDO_PASS" | sudo -S -k -p '' true >/dev/null 2>&1; then
    echo "[ERR] Wrong sudo password." >&2
    exit 1
  fi

  export GDT_SUDO_PASS
}

# ========= FINISH + CLEANUP =========

finish_session() {
  local result="$1"  # success | cancelled

  if (( ! HAVE_SESSION )); then
    return 0
  fi
  if (( FINISH_SENT )); then
    return 0
  fi

  echo "[INFO] Sending finish(result=${result}) to orchestrator for current session..."
  if ! curl -sS -X POST "${BASE_URL}/api/v1/vpn/finish" \
        -H 'content-type: application/json' \
        -d "{\"session_id\":\"${SESSION_ID}\",\"result\":\"${result}\"}" \
        >/dev/null 2>&1; then
    echo "[ERR] finish: network error while reporting result to orchestrator." >&2
    # всё равно считаем, что попытались
  fi

  FINISH_SENT=1
}

cleanup() {
  if (( TUNNEL_UP )); then
    echo "[INFO] Bringing tunnel down (wg-quick down)..."
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true
    TUNNEL_UP=0
  fi

  if [[ -f "$WG_CONF" ]]; then
    echo "[INFO] Removing temporary VPN config."
    rm -f "$WG_CONF" || true
  fi

  # Если по какой-то причине не успели отправить finish — закрываем как cancelled
  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    echo "[INFO] Finishing session as cancelled (cleanup)."
    finish_session "cancelled"
  fi
}

trap 'cleanup' EXIT INT TERM

# ========= ORCHESTRАТОР: CONFIG =========

request_initial_config() {
  local reason="$1"

  echo "[INFO] Requesting initial VPN config (reason=${reason})..." >&2
  local res
  if ! res=$(
    curl -sS -X POST "${BASE_URL}/api/v1/vpn/request" \
      -H 'content-type: application/json' \
      -d "{\"reason\":\"${reason}\"}"
  ); then
    echo "[ERR] Network error while talking to orchestrator (/vpn/request)." >&2
    return 1
  fi

  SESSION_ID="$(printf '%s' "$res" | json_get session_id || true)"
  local config_text
  config_text="$(printf '%s' "$res" | json_get config_text || true)"

  if [[ -z "$SESSION_ID" || -z "$config_text" ]]; then
    echo "[ERR] Orchestrator did not return session_id or config_text." >&2
    echo "$res" >&2
    return 1
  fi

  HAVE_SESSION=1
  echo "[INFO] Got session_id from orchestrator." >&2

  printf '%s\n' "$config_text"
  return 0
}

request_next_config() {
  echo "[INFO] Requesting next VPN config (report-broken)..." >&2

  local res
  if ! res=$(
    curl -sS -X POST "${BASE_URL}/api/v1/vpn/report-broken" \
      -H 'content-type: application/json' \
      -d "{\"session_id\":\"${SESSION_ID}\"}"
  ); then
    echo "[ERR] Network error while talking to orchestrator (/vpn/report-broken)." >&2
    return 1
  fi

  local detail
  detail="$(printf '%s' "$res" | json_get detail || true)"

  case "$detail" in
    all_backends_exhausted_for_client_and_reason|no_backend_available_on_unused_servers|session_not_found)
      echo "[ERR] Orchestrator reported: ${detail}. No more configs available." >&2
      echo "$res" >&2
      return 1
      ;;
  esac

  local new_sid
  new_sid="$(printf '%s' "$res" | json_get new_session_id || true)"
  if [[ -n "$new_sid" ]]; then
    SESSION_ID="$new_sid"
    echo "[INFO] Switched to new session_id from orchestrator." >&2
  fi

  local config_text
  config_text="$(printf '%s' "$res" | json_get config_text || true)"
  if [[ -z "$config_text" ]]; then
    echo "[ERR] Orchestrator did not return config_text for next VPN config." >&2
    echo "$res" >&2
    return 1
  fi

  printf '%s\n' "$config_text"
  return 0
}

# ========= VPN BRING-UP =========

ensure_vpn_up() {
  local reason="$1"
  local attempt=1
  local config_text=""
  local mode="initial"

  while :; do
    echo "[INFO] === Attempt ${attempt} to bring VPN up (reason=${reason}) ==="

    if [[ "$mode" == "initial" ]]; then
      if ! config_text="$(request_initial_config "$reason")"; then
        return 1
      fi
      mode="next"
    else
      if ! config_text="$(request_next_config)"; then
        return 1
      fi
    fi

    echo "[INFO] Saving VPN config from orchestrator..."
    printf '%s\n' "$config_text" > "$WG_CONF"

    echo "[INFO] Stripping DNS= lines from config (SteamOS without resolvconf)..."
    sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$WG_CONF" || true

    chmod 600 "$WG_CONF" || true

    echo "[INFO] VPN config prepared."

    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true

    echo "[INFO] Bringing tunnel up via wg-quick..."
    if ! run_sudo wg-quick up "$WG_CONF"; then
      echo "[WARN] Failed to bring tunnel up with this config." >&2
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      TUNNEL_UP=0
      rm -f "$WG_CONF" || true
      attempt=$((attempt+1))
      continue
    fi

    TUNNEL_UP=1

    echo "[INFO] Small pause after tunnel up..."
    sleep 2

    echo "[INFO] Flushing DNS cache..."
    flush_dns

    echo "[INFO] Checking reachability of 8.8.8.8 via ping..."
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
      echo "[INFO] Ping to 8.8.8.8 OK. VPN looks fine."
      return 0
    else
      echo "[WARN] Ping to 8.8.8.8 failed. Asking orchestrator for another config..." >&2
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      TUNNEL_UP=0
      rm -f "$WG_CONF" || true
      attempt=$((attempt+1))
      continue
    fi
  done
}

# ========= BUSINESS LOGIC: STEAMOS UPDATE =========

run_steamos_update() {
  echo "[INFO] Checking for steamos-update..."
  if ! command -v steamos-update >/dev/null 2>&1; then
    echo "[ERR] steamos-update command not found. This action is only for SteamOS." >&2
    return 1
  fi

  echo "[INFO] Running 'steamos-update check'..."
  local check_output=""
  local check_rc=0

  check_output="$(run_sudo steamos-update check 2>&1)" || check_rc=$?
  echo "${check_output}"

  if (( check_rc != 0 )); then
    if echo "$check_output" | grep -qi "No update available"; then
      echo "[INFO] No SteamOS updates available. Nothing to do."
      return 0
    else
      echo "[ERR] 'steamos-update check' failed with code ${check_rc}." >&2
      return 1
    fi
  fi

  echo "[INFO] Running full 'steamos-update'..."
  local update_output=""
  local update_rc=0

  update_output="$(run_sudo steamos-update 2>&1)" || update_rc=$?
  echo "${update_output}"

  if (( update_rc != 0 )); then
    if echo "$update_output" | grep -qi "No update available"; then
      echo "[INFO] No SteamOS updates available during full update. Nothing to do."
      return 0
    fi
    echo "[ERR] 'steamos-update' failed with code ${update_rc}." >&2
    return 1
  fi

  echo "[INFO] SteamOS update command finished."
  return 0
}

run_with_vpn() {
  local reason="$1"

  if ! ensure_vpn_up "$reason"; then
    echo "[ERR] Cannot get working VPN connection." >&2
    return 1
  fi

  local status=0
  run_steamos_update || status=$?

  if (( status == 0 )); then
    finish_session "success"
  else
    finish_session "cancelled"
  fi

  return "$status"
}

# ========= MAIN =========

echo "[INFO] Geekcom Deck Tools no-GUI updater"
echo "[INFO] This will update SteamOS via VPN orchestrator."

need_cmd curl
need_cmd wg-quick
need_cmd ping
need_cmd sudo

read_sudo_password

if run_with_vpn "system_update"; then
  echo "[INFO] SteamOS update finished successfully."
  exit 0
else
  echo "[ERR] SteamOS update failed." >&2
  exit 1
fi
