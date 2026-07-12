#!/usr/bin/env bash

set -Eeuo pipefail
#!/usr/bin/env bash

set -Eeuo pipefail

################################################################################
# Configuration
################################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
RUNTIME_DIR="/run/intergas-xtend-proxy"

CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
WIFI_INTERFACE="${WIFI_INTERFACE:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-}"
XTEND_HOST="${XTEND_HOST:-10.20.30.1}"
XTEND_CLIENT_IP="${XTEND_CLIENT_IP:-10.20.30.2/24}"

################################################################################
# Helpers
################################################################################

log() {
    local level="$1"
    shift

    printf '[%s] [%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$level" \
        "$*"
}

cleanup() {
    stop_wpa_supplicant || true
    log INFO "Stopping wifi monitor"
}

trap cleanup EXIT INT TERM

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log ERROR "Required command not found: $cmd"
        exit 1
    fi
}

wpa_config_file() {
    printf '%s/wpa_supplicant-%s.conf' "$RUNTIME_DIR" "$WIFI_INTERFACE"
}

wpa_pid_file() {
    printf '%s/wpa_supplicant-%s.pid' "$RUNTIME_DIR" "$WIFI_INTERFACE"
}

################################################################################
# Load environment
################################################################################

if [[ ! -f "$ENV_FILE" ]]; then
    log ERROR ".env file not found: $ENV_FILE"
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${WIFI_SSID:?WIFI_SSID is required in .env}"
: "${WIFI_PASSWORD:?WIFI_PASSWORD is required in .env}"

if [[ ! "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$CHECK_INTERVAL" -lt 5 ]]; then
    log ERROR "CHECK_INTERVAL must be a number >= 5"
    exit 1
fi

require_command awk
require_command ip
require_command iw
require_command ping
require_command wpa_cli
require_command wpa_passphrase
require_command wpa_supplicant

################################################################################
# Interface/wpa_supplicant setup
################################################################################

detect_wifi_interface() {
    if [[ -n "$WIFI_INTERFACE" ]]; then
        if ! iw dev "$WIFI_INTERFACE" info >/dev/null 2>&1; then
            log ERROR "Configured WIFI_INTERFACE '$WIFI_INTERFACE' is not a known Wi-Fi device"
            return 1
        fi
        return 0
    fi

    WIFI_INTERFACE="$(iw dev | awk '$1=="Interface" {print $2; exit}')"

    if [[ -z "$WIFI_INTERFACE" ]]; then
        log ERROR "No Wi-Fi interface found"
        return 1
    fi
}

configure_runtime_dir() {
    mkdir -p "$RUNTIME_DIR"
    chmod 700 "$RUNTIME_DIR"
}

write_wpa_config() {
    local config_file

    config_file="$(wpa_config_file)"

    {
        printf 'ctrl_interface=/run/wpa_supplicant\n'
        printf 'update_config=0\n'
        if [[ -n "$WIFI_COUNTRY" ]]; then
            printf 'country=%s\n' "$WIFI_COUNTRY"
        fi
        wpa_passphrase "$WIFI_SSID" "$WIFI_PASSWORD"
    } >"$config_file"

    chmod 600 "$config_file"
}

set_networkmanager_unmanaged() {
    if command -v nmcli >/dev/null 2>&1; then
        nmcli device set "$WIFI_INTERFACE" managed no >/dev/null 2>&1 || true
    fi
}

wpa_running() {
    local pid_file
    local pid

    pid_file="$(wpa_pid_file)"

    if [[ ! -f "$pid_file" ]]; then
        return 1
    fi

    pid="$(<"$pid_file")"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" >/dev/null 2>&1
}

stop_wpa_supplicant() {
    local pid_file
    local pid

    pid_file="$(wpa_pid_file)"

    if [[ -S "/run/wpa_supplicant/$WIFI_INTERFACE" ]]; then
        wpa_cli -i "$WIFI_INTERFACE" terminate >/dev/null 2>&1 || true
    fi

    if [[ -f "$pid_file" ]]; then
        pid="$(<"$pid_file")"
        if [[ -n "$pid" ]]; then
            kill "$pid" >/dev/null 2>&1 || true
        fi
        rm -f "$pid_file"
    fi

    ip addr flush dev "$WIFI_INTERFACE" scope global >/dev/null 2>&1 || true
}

start_wpa_supplicant() {
    configure_runtime_dir
    write_wpa_config
    set_networkmanager_unmanaged

    ip link set "$WIFI_INTERFACE" down >/dev/null 2>&1 || true
    ip link set "$WIFI_INTERFACE" up
    iw dev "$WIFI_INTERFACE" set power_save off >/dev/null 2>&1 || true

    if wpa_running; then
        return 0
    fi

    wpa_supplicant -B \
        -i "$WIFI_INTERFACE" \
        -c "$(wpa_config_file)" \
        -P "$(wpa_pid_file)"
}

################################################################################
# Functions
################################################################################

wpa_status_field() {
    local field="$1"

    wpa_cli -i "$WIFI_INTERFACE" status 2>/dev/null | awk -F= -v field="$field" '$1==field {print $2; exit}'
}

current_wpa_state() {
    wpa_status_field wpa_state
}

get_current_ssid() {
    wpa_status_field ssid
}

wifi_connected() {
    [[ "$(current_wpa_state)" == "COMPLETED" ]] && [[ "$(get_current_ssid)" == "$WIFI_SSID" ]]
}

ensure_xtend_address() {
    ip address replace "$XTEND_CLIENT_IP" dev "$WIFI_INTERFACE"
}

has_route_to_xtend() {
    ip route get "$XTEND_HOST" oif "$WIFI_INTERFACE" >/dev/null 2>&1
}

xtend_reachable() {
    ping -c 1 -W 2 -I "$WIFI_INTERFACE" "$XTEND_HOST" >/dev/null 2>&1
}

wait_for_wifi_connection() {
    local tries=0
    local max_tries=20
    local state

    while (( tries < max_tries )); do
        if wifi_connected; then
            return 0
        fi

        state="$(current_wpa_state)"
        if [[ -n "$state" ]]; then
            log DEBUG "wpa_state=$state"
        fi

        ((tries += 1))
        sleep 1
    done

    return 1
}

connect_wifi() {
    log INFO "Attempting connection to '$WIFI_SSID' via '$WIFI_INTERFACE'"

    stop_wpa_supplicant
    start_wpa_supplicant

    if ! wait_for_wifi_connection; then
        log WARN "wpa_supplicant did not reach COMPLETED state"
        return 1
    fi

    ensure_xtend_address

    if ! has_route_to_xtend || ! xtend_reachable; then
        log WARN "Associated with '$WIFI_SSID' but '$XTEND_HOST' is unreachable"
        return 1
    fi

    log INFO "Connected to '$WIFI_SSID'"
    return 0
}

################################################################################
# Main loop
################################################################################

log INFO "Starting wifi monitor"
log INFO "Target SSID: '$WIFI_SSID'"
detect_wifi_interface
log INFO "Wi-Fi interface: '$WIFI_INTERFACE'"
log INFO "Xtend host: '$XTEND_HOST'"
log INFO "Xtend client IP: '$XTEND_CLIENT_IP'"
if [[ -n "$WIFI_COUNTRY" ]]; then
    log INFO "Wi-Fi country: '$WIFI_COUNTRY'"
fi
log INFO "Check interval: ${CHECK_INTERVAL}s"

LAST_STATE="unknown"

while true; do
    CURRENT_SSID="$(get_current_ssid || true)"

    if [[ -n "$CURRENT_SSID" ]]; then
        log DEBUG "Current SSID: '$CURRENT_SSID'"
    else
        log WARN "No active WiFi connection detected"
    fi

    if wifi_connected; then
        ensure_xtend_address

        if ! has_route_to_xtend || ! xtend_reachable; then
            log WARN "Connected to '$WIFI_SSID' but '$XTEND_HOST' is unreachable; reconnecting"
            LAST_STATE="disconnected"
            connect_wifi || true
            sleep "$CHECK_INTERVAL"
            continue
        fi

        if [[ "$LAST_STATE" != "connected" ]]; then
            log INFO "Connected to '$WIFI_SSID'"
            LAST_STATE="connected"
        fi
    else
        if [[ "$LAST_STATE" != "disconnected" ]]; then
            log WARN "Disconnected from '$WIFI_SSID'"
            LAST_STATE="disconnected"
        fi

        connect_wifi || true
    fi

    sleep "$CHECK_INTERVAL"
done