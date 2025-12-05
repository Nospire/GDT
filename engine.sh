#!/usr/bin/env bash
set -euo pipefail

# ========= ОБЩИЕ НАСТРОЙКИ =========

ACTION="${1:-}"
UI_LANG="${2:-en}"

BASE_URL="${GDT_BASE_URL:-https://fix.geekcom.org}"

CFG_DIR="${HOME}/.scripts/geekcom-deck-tools"
WG_CONF="${CFG_DIR}/client.conf"
MAX_CONFIGS=4

SESSION_ID=""
HAVE_SESSION=0
TUNNEL_UP=0
FINISH_SENT=0

CURRENT_SERVER_NAME=""

# Пароль sudo, который передаёт GUI (если есть)
SUDO_PASS="${GDT_SUDO_PASS:-}"

mkdir -p "$CFG_DIR"

# ========= УТИЛИТЫ ЛОКАЛИЗАЦИИ =========

say() {
  local ru_msg="$1"
  local en_msg="$2"
  if [[ "$UI_LANG" == "ru" ]]; then
    echo "$ru_msg"
  else
    echo "$en_msg"
  fi
}

log_info() {
  local ru_msg="$1"
  local en_msg="$2"
  say "[INFO] $ru_msg" "[INFO] $en_msg"
}

log_err() {
  local ru_msg="$1"
  local en_msg="$2"
  say "[ERR] $ru_msg" "[ERR] $en_msg" >&2
}

# ========= ТЕХНИЧЕСКИЕ УТИЛИТЫ =========

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_err "Команда '$1' не найдена. Установите её и повторите." \
            "Command '$1' not found. Install it and retry."
    exit 1
  fi
}

# Унифицированный sudo: если есть пароль от GUI — используем его,
# иначе работаем с уже активным sudo -n.
run_sudo() {
  if [[ -n "$SUDO_PASS" ]]; then
    printf '%s\n' "$SUDO_PASS" | sudo -S -p '' -- "$@"
  else
    sudo -n -- "$@"
  fi
}

flush_dns() {
  if command -v resolvectl >/dev/null 2>&1; then
    run_sudo resolvectl flush-caches || true
  elif command -v systemd-resolve >/dev/null 2>&1; then
    run_sudo systemd-resolve --flush-caches || true
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
    log_err "Нужен либо jq, либо python3 для разбора JSON." \
            "Either jq or python3 is required to parse JSON."
    exit 1
  fi
}

print_endpoint_from_config() {
  grep -E '^[[:space:]]*Endpoint[[:space:]]*=' || true
}

detect_server_name() {
  local endpoint_line="$1"
  local ep ep_host ep_port
  ep="${endpoint_line#*=}"
  ep="${ep//[[:space:]]/}"
  ep_host="${ep%%:*}"
  ep_port="${ep##*:}"

  case "$ep_host" in
    77.238.245.29) CURRENT_SERVER_NAME="wg-easy" ;;
    wg.fix.geekcom.org) CURRENT_SERVER_NAME="wg.fix" ;;
    xraypl.geekcom.org) CURRENT_SERVER_NAME="xraypl" ;;
    xraynl.geekcom.org) CURRENT_SERVER_NAME="xraynl" ;;
    xrayus.geekcom.org) CURRENT_SERVER_NAME="xrayus" ;;
    *) CURRENT_SERVER_NAME="unknown" ;;
  esac
}

# ========= ОЧИСТКА И ЗАВЕРШЕНИЕ СЕССИИ =========

cleanup() {
  # Если есть сессия и ещё не отправляли /finish — считаем, что операция
  # прервалась и сначала аккуратно её завершаем.
  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    finish_session "cancelled"
    return
  fi

  # Если сессия уже финализирована или её не было — просто чистим VPN.
  if (( TUNNEL_UP )); then
    log_info "Отключаем туннель (wg-quick down)..." \
             "Bringing tunnel down (wg-quick down)..."
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true
    TUNNEL_UP=0
  fi

  if [[ -f "$WG_CONF" ]]; then
    log_info "Удаляем временный конфиг VPN." \
             "Removing temporary VPN config."
    rm -f "$WG_CONF" || true
  fi
}

trap 'cleanup' EXIT INT TERM

finish_session() {
  local result="$1"  # success | cancelled

  # 1) Всегда сначала гасим туннель и чистим конфиг —
  #    чтобы /finish ушёл по обычному интернету, а не через VPN.
  if (( TUNNEL_UP )); then
    log_info "Отключаем туннель (wg-quick down) перед отправкой статуса..." \
             "Bringing tunnel down (wg-quick down) before sending status..."
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true
    TUNNEL_UP=0
  fi

  if [[ -f "$WG_CONF" ]]; then
    log_info "Удаляем временный конфиг VPN." \
             "Removing temporary VPN config."
    rm -f "$WG_CONF" || true
  fi

  # 2) Затем отправляем /finish по BASE_URL (уже без VPN-маршрута)
  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    log_info "Отправляем finish(result=${result}) для session_id=${SESSION_ID}..." \
             "Sending finish(result=${result}) for session_id=${SESSION_ID}..."
    if ! curl -fsS -X POST "${BASE_URL}/api/v1/vpn/finish" \
        -H 'content-type: application/json' \
        -d "{\"session_id\":\"${SESSION_ID}\",\"result\":\"${result}\"}" \
        >/dev/null 2>&1; then
      log_err "finish: сетевая ошибка при отправке результата в оркестратор." \
              "finish: network error while sending result to orchestrator."
    fi
    FINISH_SENT=1
  fi
}

# ========= ПРОВЕРКИ ОКРУЖЕНИЯ =========

if [[ -z "$ACTION" ]]; then
  if [[ "$UI_LANG" == "ru" ]]; then
    echo "[ERR] Не указано действие." >&2
    echo "Использование: $0 <openh264_fix|steamos_update|flatpak_update|antizapret> [ru|en]" >&2
  else
    echo "[ERR] No ACTION specified." >&2
    echo "Usage: $0 <openh264_fix|steamos_update|flatpak_update|antizapret> [ru|en]" >&2
  fi
  exit 1
fi

need_cmd curl
need_cmd wg-quick
need_cmd ping

# Проверка sudo:
#  - если GUI передал пароль (SUDO_PASS не пустой) — работаем через него;
#  - если пароля нет — требуем активный sudo -n.
if [[ -z "$SUDO_PASS" ]] && ! sudo -n true 2>/dev/null; then
  log_err "sudo не активен. Сначала нажмите кнопку sudo внизу и введите пароль." \
          "sudo is not active. Press the sudo button below and enter your password first."
  exit 1
fi

log_info "Движок Geekcom Deck Tools запущен." \
         "Geekcom Deck Tools engine started."
log_info "Действие: ${ACTION}" \
         "ACTION: ${ACTION}"
log_info "Базовый URL оркестратора: ${BASE_URL}" \
         "Orchestrator base URL: ${BASE_URL}"

# ========= ЗАПРОС КОНФИГА У ОРКЕСТРАТОРА =========

request_initial_config() {
  local reason="$1"

  log_info \
    "Запрашиваем конфигурацию VPN через /api/v1/vpn/request (reason=${reason})..." \
    "Requesting VPN config via /api/v1/vpn/request (reason=${reason})..." >&2

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
    log_err \
      "Не удалось получить session_id или config_text от сервиса." \
      "Failed to get session_id or config_text from the service." >&2
    echo "$res" >&2
    return 1
  fi

  HAVE_SESSION=1
  log_info \
    "Получен session_id=${SESSION_ID}" \
    "Got session_id=${SESSION_ID}" >&2

  # В stdout — только конфиг, без логов
  printf '%s\n' "$config_text"
  return 0
}

request_next_config() {
  log_info \
    "Запрашиваем следующую конфигурацию через /api/v1/vpn/report-broken..." \
    "Requesting next configuration via /api/v1/vpn/report-broken..." >&2

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
    log_info \
      "Обновлён session_id=${SESSION_ID}" \
      "Updated session_id=${SESSION_ID}" >&2
  fi

  local config_text
  config_text="$(printf '%s' "$res" | json_get config_text || true)"
  if [[ -z "$config_text" ]]; then
    log_err \
      "Сервис не вернул config_text. Возможно, лимит попыток исчерпан." \
      "Service did not return config_text. Max attempts may be exceeded." >&2
    echo "$res" >&2
    return 1
  fi

  printf '%s\n' "$config_text"
  return 0
}

# ========= ПОДЪЁМ VPN =========

ensure_vpn_up() {
  local reason="$1"
  local attempt=1
  local config_text=""
  local mode="initial"

  log_info "Запуск операции с VPN (reason=${reason})..." \
           "Starting VPN operation (reason=${reason})..."

  while :; do
    log_info "=== Попытка ${attempt} поднять VPN (reason=${reason}) ===" \
             "=== Attempt ${attempt} to bring VPN up (reason=${reason}) ==="

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

    log_info "Сохраняем конфиг в ${WG_CONF}..." \
             "Saving config to ${WG_CONF}..."
    printf '%s\n' "$config_text" > "$WG_CONF"

    log_info "Удаляем строки DNS= из конфига (SteamOS без resolvconf)..." \
             "Removing DNS= lines from config (SteamOS without resolvconf)..."
    sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$WG_CONF" || true

    chmod 600 "$WG_CONF" || true

    local endpoint_line
    endpoint_line="$(print_endpoint_from_config < "$WG_CONF" | head -n1 || true)"
    if [[ -n "$endpoint_line" ]]; then
      log_info "Endpoint конфигурации:" "Config endpoint:"
      echo "$endpoint_line"
      detect_server_name "$endpoint_line"
      log_info "Определён сервер: ${CURRENT_SERVER_NAME}, endpoint=${endpoint_line#*=}" \
               "Detected server: ${CURRENT_SERVER_NAME}, endpoint=${endpoint_line#*=}"
    else
      CURRENT_SERVER_NAME="unknown"
    fi

    # Чистим хвосты от прошлых запусков
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true

    log_info "Поднимаем туннель: wg-quick up ${WG_CONF}" \
             "Bringing tunnel up: wg-quick up ${WG_CONF}"
    if ! run_sudo wg-quick up "$WG_CONF"; then
      log_err "Не удалось поднять туннель на этой конфигурации." \
              "Failed to bring tunnel up with this configuration."
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      TUNNEL_UP=0
      rm -f "$WG_CONF" || true
      ((attempt++))
      continue
    fi

    TUNNEL_UP=1

    log_info "Небольшая пауза после подъёма туннеля..." \
             "Small pause after bringing tunnel up..."
    sleep 2

    log_info "Сброс DNS-кэша..." \
             "Flushing DNS cache..."
    flush_dns

    log_info "Проверяем доступность 8.8.8.8 через ping..." \
             "Checking reachability of 8.8.8.8 via ping..."
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
      log_info "Пинг 8.8.8.8 успешен. VPN выглядит рабочим." \
               "Ping to 8.8.8.8 successful. VPN looks OK."
      return 0
    else
      log_err "Пинг 8.8.8.8 не прошёл. Пробуем другую конфигурацию через /vpn/report-broken..." \
              "Ping to 8.8.8.8 failed. Trying another config via /vpn/report-broken..."
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      TUNNEL_UP=0
      rm -f "$WG_CONF" || true
      ((attempt++))
      # Следующая итерация возьмёт новый конфиг через report-broken
      continue
    fi
  done
}

# ========= УНИВЕРСАЛЬНАЯ ОБЁРТКА ДЛЯ ДЕЙСТВИЙ =========

run_with_vpn() {
  local reason="$1"
  shift

  CURRENT_SERVER_NAME=""

  if ! ensure_vpn_up "$reason"; then
    log_err "Не удалось получить рабочее VPN-подключение." \
            "Failed to obtain a working VPN connection."
    log_info "Финальный статус операции: client_aborted" \
             "Final operation status: client_aborted"
    return 1
  fi

  local status=0
  "$@" || status=$?

  if (( status == 0 )); then
    finish_session "success"
    log_info "Финальный статус операции: completed_with_server=${CURRENT_SERVER_NAME}" \
             "Final operation status: completed_with_server=${CURRENT_SERVER_NAME}"
  else
    finish_session "cancelled"
    log_info "Финальный статус операции: client_aborted" \
             "Final operation status: client_aborted"
  fi

  return "$status"
}

# ========= ДИСПЕТЧЕР ДЕЙСТВИЙ =========

case "$ACTION" in
  openh264_fix)
    # Чистый фикс кодека, без обязательного обновления системы
    run_with_vpn "fix_openh264" "$CFG_DIR/actions/openh264_fix.sh"
    ;;
  steamos_update)
    # Системное обновление: проходит как system_update для оркестратора
    run_with_vpn "system_update" "$CFG_DIR/actions/steamos_update.sh"
    ;;
  flatpak_update)
    # Обновление flatpak’ов тоже идёт как system_update
    run_with_vpn "system_update" "$CFG_DIR/actions/flatpak_update.sh"
    ;;
  antizapret)
    # Antizapret: работает локально, без VPN и без оркестратора
    log_info "Запуск Geekcom antizapret без VPN (локальный режим)..." \
             "Running Geekcom antizapret without VPN (local mode)..."
    status=0
    "$CFG_DIR/actions/antizapret.sh" || status=$?
    if (( status == 0 )); then
      log_info "Действие antizapret завершено успешно (VPN не использовался)." \
               "Action antizapret completed successfully (no VPN used)."
    else
      log_err "Действие antizapret завершилось с ошибкой (код ${status})." \
              "Action antizapret failed with error code ${status}."
    fi
    exit "$status"
    ;;
  *)
    log_err "Неизвестное действие: ${ACTION}" \
            "Unknown ACTION: ${ACTION}"
    exit 1
    ;;
esac

log_info "Действие ${ACTION} завершено." \
         "ACTION ${ACTION} finished."
