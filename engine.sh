#!/usr/bin/env bash
set -euo pipefail

# ========= ОБЩИЕ НАСТРОЙКИ =========

ACTION="${1:-}"
UI_LANG="${2:-en}"

BASE_URL="${GDT_BASE_URL:-https://fix.geekcom.org}"

CFG_DIR="${HOME}/.scripts/geekcom-deck-tools"
WG_CONF="${CFG_DIR}/client.conf"

SESSION_ID=""
HAVE_SESSION=0
TUNNEL_UP=0
FINISH_SENT=0

# Глобальные статусы/поля для работы с оркестратором
API_HTTP_CODE=""
API_BODY=""

LAST_API_STATUS=""
LAST_CONFIG_TEXT=""

ATTEMPT=0
CURRENT_SERVER=""
CURRENT_ENDPOINT=""
OP_STATUS=""

# Пароль sudo, который передаёт GUI или nogui.sh (если есть)
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

# Унифицированный sudo: если есть пароль от GUI/nogui — используем его,
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

detect_server_from_config() {
  CURRENT_ENDPOINT=""
  CURRENT_SERVER="unknown"

  local line ep host

  if [[ -f "$WG_CONF" ]]; then
    line="$(grep -m1 -E '^[[:space:]]*Endpoint[[:space:]]*=' "$WG_CONF" || true)"
  else
    line="$(printf '%s\n' "$LAST_CONFIG_TEXT" | grep -m1 -E '^[[:space:]]*Endpoint[[:space:]]*=' || true)"
  fi

  if [[ -z "$line" ]]; then
    return 0
  fi

  ep="${line#*=}"
  ep="${ep#"${ep%%[![:space:]]*}"}"
  ep="${ep%% *}"

  CURRENT_ENDPOINT="$ep"
  host="${ep%%:*}"

  case "$host" in
    wg.fix.geekcom.org)
      CURRENT_SERVER="wg.fix"
      ;;
    xraypl.geekcom.org)
      CURRENT_SERVER="xraypl"
      ;;
    xraynl.geekcom.org)
      CURRENT_SERVER="xraynl"
      ;;
    xrayus.geekcom.org)
      CURRENT_SERVER="xrayus"
      ;;
    77.238.245.29)
      CURRENT_SERVER="wg-easy"
      ;;
    *)
      CURRENT_SERVER="unknown"
      ;;
  esac
}

# ========= HTTP-ОБЁРТКА ДЛЯ API =========

do_api_post() {
  local path="$1"
  local data="$2"

  API_HTTP_CODE=""
  API_BODY=""

  local tmp
  tmp="$(mktemp 2>/dev/null || printf '%s\n' "/tmp/gdt_api_$$")"
  local http_code

  if ! http_code="$(
    curl -sS -o "$tmp" -w '%{http_code}' \
      -X POST "${BASE_URL}${path}" \
      -H 'content-type: application/json' \
      -d "$data" 2>/dev/null
  )"; then
    API_HTTP_CODE="000"
    API_BODY=""
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi

  API_HTTP_CODE="$http_code"
  API_BODY="$(cat "$tmp" 2>/dev/null || printf '')"
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# ========= ОЧИСТКА (trap) =========

cleanup() {
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

  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    log_info "Отправляем завершение сессии (result=cancelled)..." \
             "Sending session finish (result=cancelled)..."
    curl -sS -X POST "${BASE_URL}/api/v1/vpn/finish" \
      -H 'content-type: application/json' \
      -d "{\"session_id\":\"${SESSION_ID}\",\"result\":\"cancelled\"}" \
      >/dev/null 2>&1 || true
  fi
}

trap 'cleanup' EXIT INT TERM

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
#  - если есть пароль (SUDO_PASS не пустой) — работаем через него;
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

# ========= РАБОТА С ОРКЕСТРАТОРОМ =========

request_initial_config() {
  local reason="$1"

  log_info \
    "Запрашиваем конфигурацию VPN через /api/v1/vpn/request (reason=${reason})..." \
    "Requesting VPN config via /api/v1/vpn/request (reason=${reason})..."

  LAST_API_STATUS=""
  LAST_CONFIG_TEXT=""

  do_api_post "/api/v1/vpn/request" "{\"reason\":\"${reason}\"}"

  case "$API_HTTP_CODE" in
    200)
      SESSION_ID="$(printf '%s' "$API_BODY" | json_get session_id || true)"
      LAST_CONFIG_TEXT="$(printf '%s' "$API_BODY" | json_get config_text || true)"

      if [[ -z "$SESSION_ID" || -z "$LAST_CONFIG_TEXT" ]]; then
        log_err "Ответ оркестратора не содержит session_id или config_text." \
                "Orchestrator response does not contain session_id or config_text."
        LAST_API_STATUS="BACKEND_ERROR_UNKNOWN"
        return 0
      fi

      HAVE_SESSION=1
      log_info "Получен session_id=${SESSION_ID}" \
               "Got session_id=${SESSION_ID}"
      LAST_API_STATUS="OK"
      return 0
      ;;
    404)
      LAST_API_STATUS="SESSION_NOT_FOUND"
      return 0
      ;;
    503)
      local detail
      detail="$(printf '%s' "$API_BODY" | json_get detail || true)"
      case "$detail" in
        all_backends_exhausted_for_client_and_reason)
          LAST_API_STATUS="EXHAUSTED"
          ;;
        no_backend_available_on_unused_servers)
          LAST_API_STATUS="NO_BACKENDS_AVAILABLE"
          ;;
        *)
          LAST_API_STATUS="BACKEND_ERROR_UNKNOWN"
          ;;
      esac
      return 0
      ;;
    000)
      LAST_API_STATUS="NETWORK_ERROR"
      return 0
      ;;
    *)
      LAST_API_STATUS="BACKEND_ERROR_UNKNOWN"
      return 0
      ;;
  esac
}

request_next_config() {
  log_info \
    "Запрашиваем следующую конфигурацию через /api/v1/vpn/report-broken..." \
    "Requesting next VPN config via /api/v1/vpn/report-broken..."

  LAST_API_STATUS=""
  LAST_CONFIG_TEXT=""

  do_api_post "/api/v1/vpn/report-broken" "{\"session_id\":\"${SESSION_ID}\"}"

  case "$API_HTTP_CODE" in
    200)
      local new_sid
      new_sid="$(printf '%s' "$API_BODY" | json_get new_session_id || true)"
      if [[ -n "$new_sid" ]]; then
        SESSION_ID="$new_sid"
        HAVE_SESSION=1
        log_info "Обновлён session_id=${SESSION_ID}" \
                 "Updated session_id=${SESSION_ID}"
      fi

      LAST_CONFIG_TEXT="$(printf '%s' "$API_BODY" | json_get config_text || true)"
      if [[ -z "$LAST_CONFIG_TEXT" ]]; then
        log_err "Ответ оркестратора не содержит config_text." \
                "Orchestrator response does not contain config_text."
        LAST_API_STATUS="BACKEND_ERROR_UNKNOWN"
        return 0
      fi

      LAST_API_STATUS="OK"
      return 0
      ;;
    404)
      LAST_API_STATUS="SESSION_NOT_FOUND"
      return 0
      ;;
    503)
      local detail
      detail="$(printf '%s' "$API_BODY" | json_get detail || true)"
      case "$detail" in
        all_backends_exhausted_for_client_and_reason)
          LAST_API_STATUS="EXHAUSTED"
          ;;
        no_backend_available_on_unused_servers)
          LAST_API_STATUS="NO_BACKENDS_AVAILABLE"
          ;;
        *)
          LAST_API_STATUS="BACKEND_ERROR_UNKNOWN"
          ;;
      esac
      return 0
      ;;
    000)
      LAST_API_STATUS="NETWORK_ERROR"
      return 0
      ;;
    *)
      LAST_API_STATUS="BACKEND_ERROR_UNKNOWN"
      return 0
      ;;
  esac
}

# ========= ПОДЪЁМ VPN =========

ensure_vpn_up() {
  local reason="$1"
  local mode="initial"

  while :; do
    ATTEMPT=$((ATTEMPT + 1))
    log_info \
      "=== Попытка ${ATTEMPT} поднять VPN (reason=${reason}) ===" \
      "=== Attempt ${ATTEMPT} to bring VPN up (reason=${reason}) ==="

    if [[ "$mode" == "initial" ]]; then
      request_initial_config "$reason"
    else
      request_next_config
    fi

    case "$LAST_API_STATUS" in
      OK)
        ;;
      EXHAUSTED)
        OP_STATUS="exhausted_all_backends"
        log_err \
          "Оркестратор: все сервера для этой операции уже исчерпаны." \
          "Orchestrator: all backends for this operation are exhausted."
        return 2
        ;;
      NO_BACKENDS_AVAILABLE)
        OP_STATUS="servers_temporarily_unavailable"
        log_err \
          "Оркестратор: оставшиеся сервера сейчас недоступны." \
          "Orchestrator: remaining backends are currently unavailable."
        return 3
        ;;
      SESSION_NOT_FOUND)
        OP_STATUS="session_gone"
        log_err \
          "Оркестратор: сессия не найдена (session_not_found)." \
          "Orchestrator: session not found (session_not_found)."
        return 4
        ;;
      NETWORK_ERROR)
        OP_STATUS="network_or_protocol_error"
        log_err \
          "Сетевая ошибка при обращении к оркестратору." \
          "Network error while talking to orchestrator."
        return 5
        ;;
      BACKEND_ERROR_UNKNOWN|*)
        OP_STATUS="network_or_protocol_error"
        log_err \
          "Неожиданный ответ оркестратора (HTTP=${API_HTTP_CODE})." \
          "Unexpected orchestrator response (HTTP=${API_HTTP_CODE})."
        return 6
        ;;
    esac

    # На этом этапе у нас есть LAST_CONFIG_TEXT
    log_info "Сохраняем конфиг в ${WG_CONF}..." \
             "Saving config to ${WG_CONF}..."
    printf '%s\n' "$LAST_CONFIG_TEXT" > "$WG_CONF"

    log_info \
      "Удаляем строки DNS= из конфига (SteamOS без resolvconf)..." \
      "Removing DNS= lines from config (SteamOS without resolvconf)..."
    sed -i '/^[[:space:]]*DNS[[:space:]]*=/d' "$WG_CONF" || true

    chmod 600 "$WG_CONF" || true

    log_info "Endpoint конфигурации:" \
             "Config endpoint:"
    print_endpoint_from_config < "$WG_CONF" || true
    detect_server_from_config
    if [[ -n "$CURRENT_ENDPOINT" ]]; then
      log_info \
        "Определён сервер: ${CURRENT_SERVER}, endpoint=${CURRENT_ENDPOINT}" \
        "Detected server: ${CURRENT_SERVER}, endpoint=${CURRENT_ENDPOINT}"
    fi

    # Чистим хвосты от прошлых запусков
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true

    log_info "Поднимаем туннель: wg-quick up ${WG_CONF}" \
             "Bringing tunnel up: wg-quick up ${WG_CONF}"
    if ! run_sudo wg-quick up "$WG_CONF"; then
      log_err \
        "Не удалось поднять туннель на этой конфигурации. Запросим другой конфиг у оркестратора." \
        "Failed to bring tunnel up with this configuration. Will ask orchestrator for another config."
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      TUNNEL_UP=0
      rm -f "$WG_CONF" || true
      mode="next"
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
      log_info \
        "Пинг 8.8.8.8 успешен. VPN выглядит рабочим." \
        "Ping to 8.8.8.8 successful. VPN looks OK."
      return 0
    else
      log_err \
        "Пинг 8.8.8.8 не прошёл. Пробуем другую конфигурацию через /vpn/report-broken..." \
        "Ping to 8.8.8.8 failed. Will request another config via /vpn/report-broken..."
      run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
      TUNNEL_UP=0
      rm -f "$WG_CONF" || true
      mode="next"
      continue
    fi
  done
}

finish_session() {
  local result="$1"  # success | cancelled
  if (( HAVE_SESSION )) && (( ! FINISH_SENT )); then
    log_info \
      "Отправляем finish(result=${result}) для session_id=${SESSION_ID}..." \
      "Sending finish(result=${result}) for session_id=${SESSION_ID}..."

    do_api_post "/api/v1/vpn/finish" "{\"session_id\":\"${SESSION_ID}\",\"result\":\"${result}\"}"

    case "$API_HTTP_CODE" in
      200)
        local already
        already="$(printf '%s' "$API_BODY" | json_get already_finalized || true)"
        if [[ "$already" == "true" ]]; then
          log_info \
            "Сессия уже была завершена ранее (already_finalized=true)." \
            "Session was already finalized earlier (already_finalized=true)."
        fi
        ;;
      404)
        log_info \
          "finish: сессия не найдена на стороне оркестратора (session_not_found)." \
          "finish: session not found on orchestrator side (session_not_found)."
        ;;
      000)
        log_err \
          "finish: сетевая ошибка при отправке результата в оркестратор." \
          "finish: network error while sending result to orchestrator."
        ;;
      *)
        log_info \
          "finish: неожиданный HTTP-код от оркестратора: ${API_HTTP_CODE}." \
          "finish: unexpected HTTP code from orchestrator: ${API_HTTP_CODE}."
        ;;
    esac

    FINISH_SENT=1
  fi

  if (( TUNNEL_UP )); then
    log_info "Отключаем туннель (wg-quick down)..." \
             "Bringing tunnel down (wg-quick down)..."
    run_sudo wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
    run_sudo ip link del client >/dev/null 2>&1 || true
    TUNNEL_UP=0
  fi

  if [[ -f "$WG_CONF" ]]; then
    rm -f "$WG_CONF" || true
  fi
}

# ========= УНИВЕРСАЛЬНАЯ ОБЁРТКА ДЛЯ VPN-ДЕЙСТВИЙ =========

run_with_vpn() {
  local reason="$1"
  shift

  log_info \
    "Запуск операции с VPN (reason=${reason})..." \
    "Starting VPN operation (reason=${reason})..."

  OP_STATUS=""

  if ! ensure_vpn_up "$reason"; then
    if [[ -z "$OP_STATUS" ]]; then
      OP_STATUS="network_or_protocol_error"
    fi
    log_info \
      "Финальный статус операции: ${OP_STATUS}" \
      "Final operation status: ${OP_STATUS}"
    return 1
  fi

  local status=0
  "$@" || status=$?

  if (( status == 0 )); then
    OP_STATUS="completed_with_server=${CURRENT_SERVER:-unknown}"
    finish_session "success"
  else
    OP_STATUS="client_aborted"
    finish_session "cancelled"
  fi

  log_info \
    "Финальный статус операции: ${OP_STATUS}" \
    "Final operation status: ${OP_STATUS}"

  return "$status"
}

# ========= ДИСПЕТЧЕР ДЕЙСТВИЙ =========

case "$ACTION" in
  openh264_fix)
    # Чистый фикс кодека через оркестратор
    run_with_vpn "fix_openh264" "$CFG_DIR/actions/openh264_fix.sh"
    ;;
  steamos_update)
    # Обновление SteamOS: reason=system_update
    run_with_vpn "system_update" "$CFG_DIR/actions/steamos_update.sh"
    ;;
  flatpak_update)
    # Обновление flatpak: тоже reason=system_update
    run_with_vpn "system_update" "$CFG_DIR/actions/flatpak_update.sh"
    ;;
  antizapret)
    # Антизапрет — локальная история, без оркестратора и без VPN-сессий
    log_info \
      "Запуск Geekcom antizapret (без VPN-оркестратора)..." \
      "Starting Geekcom antizapret (without VPN orchestrator)..."
    ANTIZAPRET_STATUS=0
    run_sudo "$CFG_DIR/actions/antizapret.sh" || ANTIZAPRET_STATUS=$?
    if (( ANTIZAPRET_STATUS == 0 )); then
      log_info \
        "antizapret завершён успешно." \
        "antizapret completed successfully."
    else
      log_err \
        "antizapret завершился с ошибкой (код ${ANTIZAPRET_STATUS})." \
        "antizapret finished with error (code ${ANTIZAPRET_STATUS})."
    fi
    ;;
  *)
    log_err "Неизвестное действие: ${ACTION}" \
            "Unknown ACTION: ${ACTION}"
    exit 1
    ;;
esac

log_info "Действие ${ACTION} завершено." \
         "ACTION ${ACTION} finished."
