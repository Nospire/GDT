#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========

BASE_URL="${GDT_BASE_URL:-https://fix.geekcom.org}"

CFG_DIR="${HOME}/.scripts/geekcom-deck-tools"
WG_CONF="${CFG_DIR}/client.conf"
MAX_CONFIGS=4

SESSION_ID=""
HAVE_SESSION=0
TUNNEL_UP=0
FINISH_SENT=0

GDT_SUDO_PASS="${GDT_SUDO_PASS:-}"

mkdir -p "$CFG_DIR"

# ========= LOG / UTILS =========

log() {
  printf '[INFO] %s\n' "$*" >&2
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

err() {
  printf '[ERR] %s\n' "$*" >&2
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Command '$1' not found. Install it and retry."
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
    err "Need jq or python3 to parse JSON."
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

# ========= SUDO PASSWORD =========

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
    err "Empty sudo password."
    exit 1
  fi

  if ! printf '%s\n' "$GDT_SUDO_PASS" | sudo -S -k -p '' true >/dev/null 2>&1; then
    err "Wrong sudo password."
    exit 1
  fi

  export GDT_SUDO_PASS
}

# ========= ORCHESTRATOR CALLS =========

request_initial_config() {
  local reason="$1"

  log "Requesting initial VPN config (reason=${reason})..."

  local res
  if ! res=$(
    curl -fsS -X POST "${BASE_URL}/api/v1/vpn/request" \
      -H 'content-type: application/json' \
      -d "{\"reason\":\"${reason}\"}"
  ); then
    err "Failed to call /api/v1/vpn/request on orchestrator."
    return 1
  fi

  SESSION_ID="$(printf '%s' "$res" | json_get session_id || true)"
  local config_text
  config_text="$(printf '%s' "$res" | json_get config_text || true)"

  if [[ -z "$SESSION_ID" || -z "$config_text" ]]; then
    err "Failed to get session_id or config_text from orchestrator."
    printf '%s\n' "$res" >&2
    return 1
  fi

  HAVE_SESSION=1
  log "Got session_id from orchestrator."

  # В stdout отдаём чистый config_text
  printf '%s\n' "$config_text"
}

request_next_config() {
  log "Requesting next VPN config (report-broken)..."

  local res http_code body

  if ! res=$(
    curl -sS -w '\n%{http_code}' \
      -X POST "${BASE_URL}/api/v1/vpn/report-broken" \
      -H 'content-type: application/json' \
      -d "{\"session_id\":\"${SESSION_ID}\"}"
  ); then
    err "Failed to call /api/v1/vpn/report-broken on orchestrator."
    return 1
  fi

  http_code="$(printf '%s\n' "$res" | tail -n1)"
  body="$(printf '%s\n' "$res" | sed '$d')"

  if [[ "$http_code" != "200" ]]; then
    if [[ "$http_code" == "404" ]]; then
      err "Orchestrator reported: session_not_found. No more configs available."
    else
      err "Orchestrator returned HTTP ${http_code} for /vpn/report-broken."
    fi
    printf '%s\n' "$body" >&2
    return 1
  fi

  local new_sid
  new_sid="$(printf '%s' "$body" | json_get new_session_id || true)"
  if [[ -n "$new_sid" ]]; then
    SESSION_ID="$new_sid"
  fi

  local config_text
  config_text="$(printf '%s' "$body" | json_get config_text || true)"
  if [[ -z "$config_text" ]]; then
    err "Service did not return config_text in /vpn/report-broken response."
    printf '%s\n' "$body" >&2
    return 1
  fi

  printf '%s\n' "$config_text"
}

# ========= FINISH / CLEANUP =========

finish_session() {
  local result="$1"  # success | cancelled

  if (( ! HAVE_SESSION || FINISH_SENT )); then
    return 0
  fi

  # Сначала гасим туннель и чистим конфиг, чтобы /finish шёл не через VPN
  if (( TUNNEL_UP )); then
    log "Bringing tunnel down (wg-quick down) before sending finish..."
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true
    TUNNEL_UP=0
  fi

  if [[ -f "$WG_CONF" ]]; then
    log "Removing temporary VPN config."
    rm -f "$WG_CONF" || true
  fi

  log "Sending /vpn/finish (result=${result}) to orchestrator..."
  curl -fsS -X POST "${BASE_URL}/api/v1/vpn/finish" \
    -H 'content-type: application/json' \
    -d "{\"session_id\":\"${SESSION_ID}\",\"result\":\"${result}\"}" \
    >/dev/null 2>&1 || warn "Failed to send /vpn/finish to orchestrator."

  FINISH_SENT=1
}

cleanup() {
  # Если ещё есть поднятый туннель — гасим.
  if (( TUNNEL_UP )); then
    log "Bringing tunnel down (wg-quick down)..."
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true
    TUNNEL_UP=0
  fi

  if [[ -f "$WG_CONF" ]]; then
    log "Removing temporary VPN config."
    rm -f "$WG_CONF" || true
  fi

  # Если сессия была, но /finish не отправляли — шлём cancelled.
  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    log "Session not finalized, sending finish(result=cancelled)..."
    curl -fsS -X POST "${BASE_URL}/api/v1/vpn/finish" \
      -H 'content-type: application/json' \
      -d "{\"session_id\":\"${SESSION_ID}\",\"result\":\"cancelled\"}" \
      >/dev/null 2>&1 || true
    FINISH_SENT=1
  fi
}

trap 'cleanup' EXIT INT TERM

# ========= VPN BRING-UP =========

ensure_vpn_up() {
  local reason="$1"
  local attempt=1
  local mode="initial"
  local config_text=""

  log "=== Attempt ${attempt} to bring VPN up (reason=${reason}) ==="

  while (( attempt <= MAX_CONFIGS )); do
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

    log "Saving VPN config from orchestrator..."
    printf '%s\n' "$config_text" > "$WG_CONF"

    log "Stripping DNS= lines from config (SteamOS without resolvconf)..."
    sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$WG_CONF" || true

    chmod 600 "$WG_CONF" || true
    log "VPN config prepared."

    # Чистим хвосты от прошлых запусков
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true

    log "Bringing tunnel up via wg-quick..."
    if ! run_sudo wg-quick up "$WG_CONF"; then
      warn "Failed to bring tunnel up with this config."
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      rm -f "$WG_CONF" || true
      TUNNEL_UP=0
      ((attempt++))
      log "=== Attempt ${attempt} to bring VPN up (reason=${reason}) ==="
      continue
    fi

    TUNNEL_UP=1

    log "Small pause after tunnel up..."
    sleep 2

    log "Flushing DNS cache..."
    flush_dns

    log "Checking reachability of 8.8.8.8 via ping..."
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
      log "Ping to 8.8.8.8 OK. VPN looks fine."
      return 0
    else
      warn "Ping to 8.8.8.8 failed. Asking orchestrator for another config..."
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      run_sudo ip link del client >/dev/null 2>&1 || true
      rm -f "$WG_CONF" || true
      TUNNEL_UP=0
      ((attempt++))
      log "=== Attempt ${attempt} to bring VPN up (reason=${reason}) ==="
      # следующая итерация возьмёт конфиг через report-broken
    fi
  done

  err "Failed to obtain working VPN connection."
  return 1
}

# ========= BUSINESS LOGIC: STEAMOS UPDATE =========

run_steamos_update() {
  log "Checking for steamos-update..."
  if ! command -v steamos-update >/dev/null 2>&1; then
    err "steamos-update command not found. This script is for SteamOS only."
    return 1
  fi

  log "Running 'steamos-update check' (may exit non-zero)..."
  if ! run_sudo steamos-update check; then
    local code=$?
    warn "'steamos-update check' exited with code ${code} (no updates or non-critical error)."
  fi

  log "Running full 'steamos-update'..."
  if ! run_sudo steamos-update; then
    local code=$?
    err "'steamos-update' failed with code ${code}."
    return "$code"
  fi

  log "SteamOS update command finished."
}

run_with_vpn() {
  local reason="$1"
  shift

  if ! ensure_vpn_up "$reason"; then
    err "Cannot get working VPN connection."
    return 1
  fi

  local status=0
  "$@" || status=$?

  if (( status == 0 )); then
    finish_session "success"
  else
    finish_session "cancelled"
  fi

  return "$status"
}

# ========= MAIN =========

log "Geekcom Deck Tools no-GUI updater"
log "This will update SteamOS via VPN orchestrator."

need_cmd curl
need_cmd wg-quick
need_cmd ping
need_cmd sudo
need_cmd steamos-update

read_sudo_password

if run_with_vpn "system_update" run_steamos_update; then
  log "SteamOS update finished successfully."
  exit 0
else
  err "SteamOS update failed."
  exit 1
fi
