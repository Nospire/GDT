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

# ========= LOGGING =========

log_info() {
  printf '[INFO] %s\n' "$*" >&2
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_err() {
  printf '[ERR] %s\n' "$*" >&2
}

# ========= UTILS =========

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
    return 0
  fi

  if [[ -t 0 ]]; then
    printf "Enter sudo password (input will be hidden): " > /dev/tty
    stty -echo </dev/tty
    IFS= read -r GDT_SUDO_PASS </dev/tty || true
    stty echo </dev/tty
    printf "\n" > /dev/tty
  else
    printf "Enter sudo password (input will be hidden): " > /dev/tty
    stty -echo </dev/tty
    IFS= read -r GDT_SUDO_PASS </dev/tty || true
    stty echo </dev/tty
    printf "\n" > /dev/tty
  fi

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

# ========= FINISH / CLEANUP =========

finish_session() {
  local result="$1"  # success | cancelled

  # 1) Всегда сначала гасим туннель и чистим config,
  #    чтобы /finish ушёл по обычному интернету.
  if (( TUNNEL_UP )); then
    log_info "Bringing tunnel down (wg-quick down) before sending status..."
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true
    TUNNEL_UP=0
  fi

  if [[ -f "$WG_CONF" ]]; then
    log_info "Removing temporary VPN config."
    rm -f "$WG_CONF" || true
  fi

  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    log_info "Sending /vpn/finish (result=${result}) for session_id=${SESSION_ID}..."
    curl -fsS -X POST "${BASE_URL}/api/v1/vpn/finish" \
      -H 'content-type: application/json' \
      -d "{\"session_id\":\"${SESSION_ID}\",\"result\":\"${result}\"}" \
      >/dev/null 2>&1 || log_warn "finish: network error while sending result."
    FINISH_SENT=1
  fi
}

cleanup() {
  # Если есть сессия и мы ещё не звали /finish — делаем это,
  # там уже всё погасится и почистится.
  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    finish_session "cancelled"
    return
  fi

  # Иначе просто гасим VPN и удаляем конфиг.
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
}

trap 'cleanup' EXIT INT TERM

# ========= ORCHESTRATOR =========

request_initial_config() {
  local reason="$1"

  log_info "Requesting initial VPN config (reason=${reason})..."

  local res
  res=$(
    curl -fsS -X POST "${BASE_URL}/api/v1/vpn/request" \
      -H 'content-type: application/json' \
      -d "{\"reason\":\"${reason}\"}"
  )

  SESSION_ID="$(printf '%s' "$res" | json_get session_id || true)"
  local config_text
  config_text="$(printf '%s' "$res" | json_get config_text || true)"

  if [[ -z "$SESSION_ID" || -z "$config_text" ]]; then
    log_err "Failed to get session_id or config_text from orchestrator."
    echo "$res" >&2
    return 1
  fi

  HAVE_SESSION=1
  log_info "Got session_id from orchestrator."

  printf '%s\n' "$config_text"
  return 0
}

request_next_config() {
  log_info "Requesting next VPN config (report-broken)..."

  local res
  res=$(
    curl -fsS -X POST "${BASE_URL}/api/v1/vpn/report-broken" \
      -H 'content-type: application/json' \
      -d "{\"session_id\":\"${SESSION_ID}\"}"
  )

  local new_sid
  new_sid="$(printf '%s' "$res" | json_get new_session_id || true)"
  if [[ -n "$new_sid" ]]; then
    SESSION_ID="$new_sid"
    log_info "Updated session_id from orchestrator."
  fi

  local config_text
  config_text="$(printf '%s' "$res" | json_get config_text || true)"
  if [[ -z "$config_text" ]]; then
    log_err "Orchestrator did not return config_text. Maybe attempts limit reached."
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
  local have_initial=0
  local config_text=""

  log_info "Starting VPN operation (reason=${reason})..."

  while :; do
    log_info "=== Attempt ${attempt} to bring VPN up (reason=${reason}) ==="

    if (( have_initial == 0 )); then
      if ! config_text="$(request_initial_config "$reason")"; then
        return 1
      fi
      have_initial=1
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

    # Чистим хвосты от прошлых попыток
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true

    log_info "Bringing tunnel up via wg-quick..."
    if ! run_sudo wg-quick up "$WG_CONF"; then
      log_warn "Failed to bring tunnel up with this config."
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      run_sudo ip link del client >/dev/null 2>&1 || true
      rm -f "$WG_CONF" || true
      ((attempt++))
      continue
    fi

    TUNNEL_UP=1

    log_info "Small pause after tunnel up..."
    sleep 5

    log_info "Flushing DNS cache..."
    flush_dns

    log_info "Checking reachability of 8.8.8.8 via ping..."
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
      log_info "Ping to 8.8.8.8 OK. VPN looks fine."
      return 0
    fi

    log_warn "Ping to 8.8.8.8 failed on this config."

    # Гасим туннель и чистим конфиг ПЕРЕД запросом нового конфига
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true
    TUNNEL_UP=0
    rm -f "$WG_CONF" || true

    ((attempt++))
    # Следующая итерация возьмёт новый конфиг через report-broken по обычному интернету
  done
}

# ========= BUSINESS LOGIC =========

run_steamos_update() {
  local code

  log_info "Checking for steamos-update..."
  if ! command -v steamos-update >/dev/null 2>&1; then
    log_err "steamos-update command not found. This action is only for SteamOS."
    return 1
  fi

  log_info "Running 'steamos-update check' (may exit non-zero)..."
  if ! run_sudo steamos-update check; then
    code=$?
    if [[ "$code" -eq 0 || "$code" -eq 7 ]]; then
      log_warn "'steamos-update check' exited with code ${code} (no updates or non-critical condition)."
    else
      log_err "'steamos-update check' failed with code ${code}."
      return 1
    fi
  fi

  log_info "Running full 'steamos-update'..."
  if ! run_sudo steamos-update; then
    code=$?
    if [[ "$code" -eq 0 || "$code" -eq 7 ]]; then
      log_info "'steamos-update' reports no updates (code ${code})."
      return 0
    else
      log_err "'steamos-update' failed with code ${code}."
      return 1
    fi
  fi

  log_info "SteamOS update finished successfully."
  return 0
}

run_with_vpn() {
  local reason="$1"

  if ! ensure_vpn_up "$reason"; then
    log_err "Cannot get working VPN connection."
    finish_session "cancelled"
    return 1
  fi

  local status=0
  run_steamos_update || status=$?

  if (( status == 0 )); then
    finish_session "success"
    return 0
  else
    finish_session "cancelled"
    return "$status"
  fi
}

# ========= MAIN =========

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
