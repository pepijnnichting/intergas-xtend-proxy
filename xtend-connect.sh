#!/usr/bin/env bash

set -Eeuo pipefail

################################################################################
# Configuration
################################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

LOG_TAG="wifi-monitor"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"

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

################################################################################
# Functions
################################################################################

get_current_ssid() {
    LC_ALL=C nmcli -t -f NAME,TYPE connection show --active \
        | awk -F: '$2=="802-11-wireless" {print $1; exit}'
}

wifi_connected() {
    local current_ssid="$1"
    [[ "$current_ssid" == "$WIFI_SSID" ]]
}

connect_wifi() {

    log INFO "Attempting connection to '$WIFI_SSID'"

    # Remove broken/stale connection profiles if they exist
    nmcli connection delete "$WIFI_SSID" >/dev/null 2>&1 || true

    if nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD"; then
        log INFO "Successfully connected to '$WIFI_SSID'"
        return 0
    fi

    log ERROR "Connection attempt failed"

    log INFO "Available WiFi networks:"
    nmcli --colors no device wifi list

    return 1
}

################################################################################
# Main loop
################################################################################

log INFO "Starting wifi monitor"
log INFO "Target SSID: '$WIFI_SSID'"
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