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

# ========= SUDO PASSWORD =========

read_sudo_password() {
  if [[ -n "$GDT_SUDO_PASS" ]]; then
    return 0
  fi

  # Всегда читаем с /dev/tty, чтобы работало и в curl | bash
  printf "Enter sudo password (input will be hidden): " > /dev/tty
  stty -echo </dev/tty
  IFS= read -r GDT_SUDO_PASS </dev/tty || true
  stty echo </dev/tty
  printf "\n" > /dev/tty

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

# ========= SESSION FINISH & CLEANUP =========

finish_session() {
  local result="$1"  # success | cancelled

  # 1) Всегда сначала гасим туннель и чистим конфиг — /finish должен идти вне VPN
  if (( TUNNEL_UP )); then
    echo "[INFO] Bringing tunnel down (wg-quick down) before sending status..."
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true
    TUNNEL_UP=0
  fi

  if [[ -f "$WG_CONF" ]]; then
    echo "[INFO] Removing temporary VPN config."
    rm -f "$WG_CONF" || true
  fi

  # 2) Только после этого шлём /finish в оркестратор
  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    echo "[INFO] Sending /vpn/finish(result=${result})..."
    if ! curl -fsS -X POST "${BASE_URL}/api/v1/vpn/finish" \
        -H 'content-type: application/json' \
        -d "{\"session_id\":\"${SESSION_ID}\",\"result\":\"${result}\"}" \
        >/dev/null 2>&1; then
      echo "[ERR] finish: network error while sending result to orchestrator." >&2
    fi
    FINISH_SENT=1
  fi
}

cleanup() {
  # Если сессия есть, но finish ещё не отправлен — считаем, что это отмена
  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    finish_session "cancelled"
    return
  fi

  # Если сессии нет или она уже финализирована — просто чистим VPN
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
}

trap 'cleanup' EXIT INT TERM

# ========= ORCHESTRATOR: REQUEST CONFIG =========

request_initial_config() {
  local reason="$1"

  echo "[INFO] Requesting initial VPN config (reason=${reason})..."
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
    echo "[ERR] Failed to get session_id or config_text from orchestrator." >&2
    echo "$res" >&2
    return 1
  fi

  HAVE_SESSION=1
  echo "[INFO] Got session_id from orchestrator."

  # В stdout возвращаем только конфиг, без логов
  printf '%s\n' "$config_text"
  return 0
}

request_next_config() {
  echo "[INFO] Requesting next VPN config (report-broken)..."

  # Берём и тело, и HTTP-код одним вызовом
  local http_code
  local body
  body=$(
    curl -sS -w '%{http_code}' -X POST "${BASE_URL}/api/v1/vpn/report-broken" \
      -H 'content-type: application/json' \
      -d "{\"session_id\":\"${SESSION_ID}\"}"
  ) || {
    echo "[ERR] Failed to call /api/v1/vpn/report-broken on ${BASE_URL}." >&2
    return 1
  }

  http_code="${body: -3}"
  body="${body::-3}"

  if [[ "$http_code" != "200" ]]; then
    echo "[ERR] Orchestrator returned HTTP ${http_code} for /vpn/report-broken." >&2
    if [[ -n "$body" ]]; then
      # Печатаем JSON-ответ для диагностики
      echo "$body" >&2
      # Попробуем вытащить detail, если это JSON
      local detail
      detail="$(printf '%s' "$body" | json_get detail || true)"
      if [[ -n "$detail" ]]; then
        echo "[ERR] Orchestrator reported: ${detail}. No more configs available." >&2
      fi
    fi
    return 1
  fi

  local new_sid
  new_sid="$(printf '%s' "$body" | json_get new_session_id || true)"
  if [[ -n "$new_sid" ]]; then
    SESSION_ID="$new_sid"
    echo "[INFO] Updated session_id from orchestrator."
  fi

  local config_text
  config_text="$(printf '%s' "$body" | json_get config_text || true)"
  if [[ -z "$config_text" ]]; then
    echo "[ERR] Orchestrator did not return config_text. Maybe attempts limit reached." >&2
    echo "$body" >&2
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

    # Clean leftovers from previous runs
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true

    echo "[INFO] VPN config prepared."
    echo "[INFO] Bringing tunnel up via wg-quick..."
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
      echo "[WARN] Ping to 8.8.8.8 failed. Asking orchestrator for another config..." >&2
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      TUNNEL_UP=0
      rm -f "$WG_CONF" || true
      ((attempt++))
      # next iteration will use report-broken
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
  local rc=0
  if ! run_sudo steamos-update check; then
    rc=$?
    if (( rc == 7 )); then
      echo "[INFO] No SteamOS updates available. Nothing to do."
      return 0
    fi
    echo "[ERR] 'steamos-update check' failed with code ${rc}." >&2
    return "$rc"
  fi

  echo "[INFO] Running full 'steamos-update'..."
  if ! run_sudo steamos-update; then
    rc=$?
    echo "[ERR] 'steamos-update' failed with code ${rc}." >&2
    return "$rc"
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
    echo "[INFO] SteamOS update finished successfully."
  else
    finish_session "cancelled"
    echo "[ERR] SteamOS update failed." >&2
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
  exit 0
else
  exit 1
fi
