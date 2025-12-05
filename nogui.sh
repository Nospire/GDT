#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${GDT_BASE_URL:-https://fix.geekcom.org}"

CFG_DIR="${HOME}/.scripts/geekcom-deck-tools"
WG_CONF="${CFG_DIR}/client.conf"

SESSION_ID=""
HAVE_SESSION=0
TUNNEL_UP=0
FINISH_SENT=0

GDT_SUDO_PASS="${GDT_SUDO_PASS:-}"

mkdir -p "$CFG_DIR"

log_info() {
  printf '[INFO] %s\n' "$*" >&2
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_err() {
  printf '[ERR] %s\n' "$*" >&2
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_err "Command '$1' not found. Install it and retry."
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
    log_err "Need jq or python3 to parse JSON."
    exit 1
  fi
}

run_sudo() {
  if [[ -z "$GDT_SUDO_PASS" ]]; then
    log_err "Internal error: sudo password is empty in run_sudo."
    exit 1
  fi
  printf '%s\n' "$GDT_SUDO_PASS" | sudo -S -p '' -- "$@"
}

flush_dns() {
  if command -v resolvectl >/dev/null 2>&1; then
    run_sudo resolvectl flush-caches || true
  elif command -v systemd-resolve >/dev/null 2>&1; then
    run_sudo systemd-resolve --flush-caches || true
  fi
}

read_sudo_password() {
  if [[ -n "$GDT_SUDO_PASS" ]]; then
    return 0
  fi

  printf "Enter sudo password (input will be hidden): " > /dev/tty
  stty -echo </dev/tty
  IFS= read -r GDT_SUDO_PASS </dev/tty || true
  stty echo </dev/tty
  printf "\n" > /dev/tty

  if [[ -z "$GDT_SUDO_PASS" ]]; then
    log_err "Empty sudo password."
    exit 1
  fi

  if ! printf '%s\n' "$GDT_SUDO_PASS" | sudo -S -k -p '' true >/dev/null 2>&1; then
    log_err "Wrong sudo password."
    exit 1
  fi

  export GDT_SUDO_PASS
}

finish_session() {
  local result="$1"
  if (( HAVE_SESSION )) && (( ! FINISH_SENT )) && [[ -n "$SESSION_ID" ]]; then
    log_info "Sending /vpn/finish (result=${result})..."
    curl -fsS -X POST "${BASE_URL}/api/v1/vpn/finish" \
      -H 'content-type: application/json' \
      -d "{\"session_id\":\"${SESSION_ID}\",\"result\":\"${result}\"}" \
      >/dev/null 2>&1 || true
    FINISH_SENT=1
  fi
}

cleanup() {
  if (( TUNNEL_UP )); then
    log_info "Bringing tunnel down (wg-quick down)..."
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true
    TUNNEL_UP=0
  fi

  if [[ -f "$WG_CONF" ]]; then
    log_info "Removing temporary VPN config."
    rm -f "$WG_CONF" || true
  fi

  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    log_info "Finishing session as cancelled..."
    finish_session "cancelled"
  fi
}

trap 'cleanup' EXIT INT TERM

request_initial_config() {
  local reason="$1"

  log_info "Requesting initial VPN config (reason=${reason})..."

  local resp http body
  resp=$(
    curl -sS -w '\n%{http_code}' \
      -X POST "${BASE_URL}/api/v1/vpn/request" \
      -H 'content-type: application/json' \
      -d "{\"reason\":\"${reason}\"}"
  ) || {
    log_err "Failed to call /api/v1/vpn/request."
    return 1
  }

  http=$(printf '%s\n' "$resp" | tail -n1)
  body=$(printf '%s\n' "$resp" | sed '$d')

  if [[ "$http" != "200" ]]; then
    log_err "Orchestrator returned HTTP ${http} for /vpn/request."
    printf '%s\n' "$body" >&2
    return 1
  fi

  SESSION_ID="$(printf '%s' "$body" | json_get session_id || true)"
  if [[ -z "$SESSION_ID" ]]; then
    log_err "Missing session_id in /vpn/request response."
    printf '%s\n' "$body" >&2
    return 1
  fi

  HAVE_SESSION=1
  log_info "Got session_id from orchestrator."

  local config_text
  config_text="$(printf '%s' "$body" | json_get config_text || true)"
  if [[ -z "$config_text" ]]; then
    log_err "Missing config_text in /vpn/request response."
    printf '%s\n' "$body" >&2
    return 1
  fi

  printf '%s\n' "$config_text"
  return 0
}

request_next_config() {
  if [[ -z "$SESSION_ID" ]]; then
    log_err "Cannot call /vpn/report-broken: SESSION_ID is empty."
    return 1
  fi

  log_info "Requesting next VPN config (report-broken)..."

  local resp http body
  resp=$(
    curl -sS -w '\n%{http_code}' \
      -X POST "${BASE_URL}/api/v1/vpn/report-broken" \
      -H 'content-type: application/json' \
      -d "{\"session_id\":\"${SESSION_ID}\"}"
  ) || {
    log_err "Failed to call /api/v1/vpn/report-broken."
    return 1
  }

  http=$(printf '%s\n' "$resp" | tail -n1)
  body=$(printf '%s\n' "$resp" | sed '$d')

  if [[ "$http" != "200" ]]; then
    if [[ "$http" == "404" ]]; then
      log_err "Orchestrator reported: session_not_found. No more configs available."
    elif [[ "$http" == "503" ]]; then
      log_err "Orchestrator reported: all backends exhausted for this client/reason."
    else
      log_err "Orchestrator returned HTTP ${http} for /vpn/report-broken."
    fi
    printf '%s\n' "$body" >&2
    return 1
  fi

  local new_sid
  new_sid="$(printf '%s' "$body" | json_get new_session_id || true)"
  if [[ -n "$new_sid" ]]; then
    SESSION_ID="$new_sid"
    log_info "Updated session_id from orchestrator."
  fi

  local config_text
  config_text="$(printf '%s' "$body" | json_get config_text || true)"
  if [[ -z "$config_text" ]]; then
    log_err "Missing config_text in /vpn/report-broken response."
    printf '%s\n' "$body" >&2
    return 1
  fi

  printf '%s\n' "$config_text"
  return 0
}

ensure_vpn_up() {
  local reason="$1"
  local attempt=1
  local config_text=""
  local mode="initial"

  while :; do
    log_info "=== Attempt ${attempt} to bring VPN up (reason=${reason}) ==="

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

    log_info "Saving VPN config from orchestrator..."
    printf '%s\n' "$config_text" > "$WG_CONF"

    log_info "Stripping DNS= lines from config (SteamOS without resolvconf)..."
    sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$WG_CONF" || true

    chmod 600 "$WG_CONF" || true
    log_info "VPN config prepared."

    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true

    log_info "Bringing tunnel up via wg-quick..."
    if ! run_sudo wg-quick up "$WG_CONF"; then
      log_warn "Failed to bring tunnel up with this config."
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      TUNNEL_UP=0
      rm -f "$WG_CONF" || true
      attempt=$((attempt + 1))
      continue
    fi

    TUNNEL_UP=1

    log_info "Small pause after tunnel up..."
    sleep 2

    log_info "Flushing DNS cache..."
    flush_dns

    log_info "Checking reachability of 8.8.8.8 via ping..."
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
      log_info "Ping to 8.8.8.8 OK. VPN looks fine."
      return 0
    else
      log_warn "Ping to 8.8.8.8 failed. Asking orchestrator for another config..."
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      TUNNEL_UP=0
      rm -f "$WG_CONF" || true
      attempt=$((attempt + 1))
      continue
    fi
  done
}

run_steamos_update() {
  log_info "Checking for steamos-update..."
  if ! command -v steamos-update >/dev/null 2>&1; then
    log_err "steamos-update command not found. This action is only for SteamOS."
    return 1
  fi

  log_info "Running 'steamos-update check'..."
  if ! run_sudo steamos-update check 2>&1; then
    local rc=$?
    if (( rc != 7 )); then
      log_err "'steamos-update check' failed with code ${rc}."
      return 1
    fi
    log_info "No SteamOS updates available. Nothing to do."
    return 0
  fi

  log_info "Running full 'steamos-update'..."
  if ! run_sudo steamos-update 2>&1; then
    local rc=$?
    if (( rc == 7 )); then
      log_info "No SteamOS updates available. Nothing to do."
      return 0
    fi
    log_err "'steamos-update' failed with code ${rc}."
    return 1
  fi

  log_info "SteamOS update command finished."
  return 0
}

run_with_vpn() {
  local reason="$1"

  if ! ensure_vpn_up "$reason"; then
    log_err "Cannot get working VPN connection."
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

log_info "Geekcom Deck Tools no-GUI updater"
log_info "This will update SteamOS via VPN orchestrator."

need_cmd curl
need_cmd wg-quick
need_cmd ping
need_cmd sudo

read_sudo_password

if run_with_vpn "system_update"; then
  log_info "SteamOS update finished successfully."
  exit 0
else
  log_err "SteamOS update failed."
  exit 1
fi
