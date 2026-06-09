#!/usr/bin/env bash

set -Eeuo pipefail

################################################################################
# Configuration
################################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

LOG_TAG="wifi-monitor"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
WIFI_INTERFACE="${WIFI_INTERFACE:-}"
XTEND_HOST="${XTEND_HOST:-10.20.30.1}"

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

require_command nmcli
require_command awk
require_command ip
require_command ping

################################################################################
# Interface/network manager setup
################################################################################

wait_for_network_manager() {
    local tries=0
    local max_tries=30

    while (( tries < max_tries )); do
        if nmcli -t -f RUNNING general status | grep -qi '^running$'; then
            return 0
        fi
        ((tries += 1))
        sleep 1
    done

    log ERROR "NetworkManager did not become ready in time"
    return 1
}

detect_wifi_interface() {
    if [[ -n "$WIFI_INTERFACE" ]]; then
        if ! nmcli -t -f DEVICE,TYPE device status | awk -F: -v dev="$WIFI_INTERFACE" '$1==dev && $2=="wifi" {found=1} END {exit(found?0:1)}'; then
            log ERROR "Configured WIFI_INTERFACE '$WIFI_INTERFACE' is not a known Wi-Fi device"
            return 1
        fi
        return 0
    fi

    WIFI_INTERFACE="$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2=="wifi" {print $1; exit}')"

    if [[ -z "$WIFI_INTERFACE" ]]; then
        log ERROR "No Wi-Fi interface found"
        return 1
    fi
}

################################################################################
# Functions
################################################################################

get_current_ssid() {
    LC_ALL=C nmcli -t -f ACTIVE,SSID device wifi list ifname "$WIFI_INTERFACE" \
        | awk -F: '$1=="yes" {print $2; exit}'
}

wifi_connected() {
    local current_ssid="$1"
    [[ "$current_ssid" == "$WIFI_SSID" ]]
}

has_route_to_xtend() {
    ip route get "$XTEND_HOST" oif "$WIFI_INTERFACE" >/dev/null 2>&1
}

xtend_reachable() {
    ping -c 1 -W 2 -I "$WIFI_INTERFACE" "$XTEND_HOST" >/dev/null 2>&1
}

connect_wifi() {

    log INFO "Attempting connection to '$WIFI_SSID' via '$WIFI_INTERFACE'"

    # Prefer an existing connection profile when present.
    if nmcli --wait 10 connection up "$WIFI_SSID" ifname "$WIFI_INTERFACE" >/dev/null 2>&1; then
        log INFO "Connected using existing profile '$WIFI_SSID'"
        return 0
    fi

    nmcli device wifi rescan ifname "$WIFI_INTERFACE" >/dev/null 2>&1 || true

    if nmcli --wait 15 device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" ifname "$WIFI_INTERFACE"; then
        log INFO "Successfully connected to '$WIFI_SSID'"
        return 0
    fi

    log ERROR "Connection attempt failed"

    log INFO "Available WiFi networks:"
    nmcli --colors no device wifi list ifname "$WIFI_INTERFACE"

    return 1
}

################################################################################
# Main loop
################################################################################

log INFO "Starting wifi monitor"
log INFO "Target SSID: '$WIFI_SSID'"
wait_for_network_manager
detect_wifi_interface
log INFO "Wi-Fi interface: '$WIFI_INTERFACE'"
log INFO "Xtend host: '$XTEND_HOST'"
log INFO "Check interval: ${CHECK_INTERVAL}s"

LAST_STATE="unknown"

while true; do

    CURRENT_SSID="$(get_current_ssid || true)"

    if [[ -n "$CURRENT_SSID" ]]; then
        log DEBUG "Current SSID: '$CURRENT_SSID'"
    else
        log WARN "No active WiFi connection detected"
    fi

    if wifi_connected "$CURRENT_SSID"; then

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