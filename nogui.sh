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

print_endpoint_from_config() {
  grep -E '^[[:space:]]*Endpoint[[:space:]]*=' || true
}

# ========= SUDO HANDLING =========

read_sudo_password() {
  if [[ -n "$GDT_SUDO_PASS" ]]; then
    return 0
  fi

  if [[ -t 0 ]]; then
    # running directly in tty
    printf "Enter sudo password (input will be hidden): " > /dev/tty
    stty -echo </dev/tty
    IFS= read -r GDT_SUDO_PASS </dev/tty || true
    stty echo </dev/tty
    printf "\n" > /dev/tty
  else
    # piped (curl | bash) — read from /dev/tty explicitly
    printf "Enter sudo password (input will be hidden): " > /dev/tty
    stty -echo </dev/tty
    IFS= read -r GDT_SUDO_PASS </dev/tty || true
    stty echo </dev/tty
    printf "\n" > /dev/tty
  fi

  if [[ -z "$GDT_SUDO_PASS" ]]; then
    echo "[ERR] Empty sudo password." >&2
    exit 1
  fi

  # Validate sudo password
  if ! printf '%s\n' "$GDT_SUDO_PASS" | sudo -S -k -p '' true >/dev/null 2>&1; then
    echo "[ERR] Wrong sudo password." >&2
    exit 1
  fi

  export GDT_SUDO_PASS
}

# ========= CLEANUP / TRAP =========

finish_session() {
  local result="$1"  # success | cancelled
  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    echo "[INFO] Sending /vpn/finish(result=${result}) for session_id=${SESSION_ID}..."
    curl -fsS -X POST "${BASE_URL}/api/v1/vpn/finish" \
      -H 'content-type: application/json' \
      -d "{\"session_id\":\"${SESSION_ID}\",\"result\":\"${result}\"}" \
      >/dev/null 2>&1 || true
    FINISH_SENT=1
  fi
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

  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    echo "[INFO] Finishing session as cancelled..."
    finish_session "cancelled"
  fi
}

trap 'cleanup' EXIT INT TERM

# ========= ORCHESTRATOR: REQUEST CONFIG =========

request_initial_config() {
  local reason="$1"

  echo "[INFO] Requesting VPN config via /vpn/request (reason=${reason})..."
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
    echo "[ERR] Failed to get session_id or config_text from service." >&2
    echo "$res" >&2
    return 1
  fi

  HAVE_SESSION=1
  echo "[INFO] Got session_id=${SESSION_ID}"

  printf '%s\n' "$config_text"
  return 0
}

request_next_config() {
  echo "[INFO] Requesting next VPN config via /vpn/report-broken..."

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
    echo "[INFO] Updated session_id=${SESSION_ID}"
  fi

  local config_text
  config_text="$(printf '%s' "$res" | json_get config_text || true)"
  if [[ -z "$config_text" ]]; then
    echo "[ERR] Service did not return config_text. Maybe attempts limit reached." >&2
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

  while (( attempt <= MAX_CONFIGS )); do
    echo "[INFO] === Attempt ${attempt}/${MAX_CONFIGS} to bring VPN up ==="

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

    echo "[INFO] Saving config to ${WG_CONF}..."
    printf '%s\n' "$config_text" > "$WG_CONF"

    echo "[INFO] Removing DNS= lines from config (SteamOS without resolvconf)..."
    sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$WG_CONF" || true

    chmod 600 "$WG_CONF" || true

    echo "[INFO] Config endpoint:"
    print_endpoint_from_config < "$WG_CONF" || true

    # Clean up leftovers from previous runs
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true

    echo "[INFO] Bringing tunnel up: wg-quick up ${WG_CONF}"
    if ! run_sudo wg-quick up "$WG_CONF"; then
      echo "[WARN] Failed to bring tunnel up with this config." >&2
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      TUNNEL_UP=0
      rm -f "$WG_CONF" || true
      ((attempt++))
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
      echo "[WARN] Ping to 8.8.8.8 failed. Trying next config..." >&2
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      TUNNEL_UP=0
      rm -f "$WG_CONF" || true
      ((attempt++))
      continue
    fi
  done

  echo "[ERR] Failed to obtain working VPN in ${MAX_CONFIGS} attempts." >&2
  return 1
}

# ========= BUSINESS LOGIC: STEAMOS UPDATE =========

run_steamos_update() {
  echo "[INFO] Running 'steamos-update check' (may exit non-zero)..."
  run_sudo steamos-update check || true

  echo "[INFO] Running 'steamos-update'..."
  run_sudo steamos-update
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
need_cmd steamos-update

read_sudo_password

if run_with_vpn "system_update"; then
  echo "[INFO] SteamOS update finished successfully."
  exit 0
else
  echo "[ERR] SteamOS update failed." >&2
  exit 1
fi
