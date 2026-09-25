#!/usr/bin/env bash
# Keep a dedicated Wi-Fi interface connected to an Intergas Xtend access point.
# This script is intentionally self-contained: it is run by systemd as root.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/.env}"
readonly RUNTIME_DIR="/run/intergas-xtend-proxy"

log() { local level="$1"; shift; printf '[%(%Y-%m-%d %H:%M:%S)T] [%s] %s\n' -1 "$level" "$*"; }
die() { log ERROR "$*"; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

is_ipv4() {
    local ip="$1" octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local -a octets
    IFS=. read -r -a octets <<<"$ip"
    for octet in "${octets[@]}"; do ((10#$octet <= 255)) || return 1; done
}

validate_config() {
    [[ -n "$WIFI_SSID" && ${#WIFI_SSID} -le 32 ]] || die "WIFI_SSID must be 1–32 characters"
    [[ "$WIFI_PASSWORD" =~ ^.{8,63}$ ]] || die "WIFI_PASSWORD must be 8–63 characters"
    [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] && ((CHECK_INTERVAL >= 5)) || die "CHECK_INTERVAL must be a number >= 5"
    [[ -z "$WIFI_INTERFACE" || "$WIFI_INTERFACE" =~ ^[[:alnum:]_.:-]+$ ]] || die "WIFI_INTERFACE contains invalid characters"
    [[ -z "$WIFI_COUNTRY" || "$WIFI_COUNTRY" =~ ^[A-Za-z]{2}$ ]] || die "WIFI_COUNTRY must be a two-letter country code"
    is_ipv4 "$XTEND_HOST" || die "XTEND_HOST must be an IPv4 address"
    local client_ip prefix
    [[ "$XTEND_CLIENT_IP" =~ ^([^/]+)/([0-9]{1,2})$ ]] || die "XTEND_CLIENT_IP must be IPv4 CIDR notation"
    client_ip="${BASH_REMATCH[1]}"; prefix="${BASH_REMATCH[2]}"
    is_ipv4 "$client_ip" && ((10#$prefix <= 32)) || die "XTEND_CLIENT_IP must be IPv4 CIDR notation"
}

# Read a simple KEY=value file without executing it. Wi-Fi passwords containing
# shell metacharacters therefore remain data, not code.
load_config() {
    [[ -r "$CONFIG_FILE" ]] || die "Configuration file not readable: $CONFIG_FILE"
    local line key value line_number=0
    declare -A values=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_number += 1)); line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || die "Invalid configuration at line $line_number (expected KEY=value)"
        key="${line%%=*}"; value="${line#*=}"
        [[ "$key" =~ ^(WIFI_SSID|WIFI_PASSWORD|WIFI_INTERFACE|WIFI_COUNTRY|CHECK_INTERVAL|XTEND_HOST|XTEND_CLIENT_IP)$ ]] || die "Unknown configuration key '$key' at line $line_number"
        [[ -z "${values[$key]+x}" ]] || die "Duplicate configuration key '$key'"
        values[$key]="$value"
    done <"$CONFIG_FILE"
    WIFI_SSID="${values[WIFI_SSID]:-}"; WIFI_PASSWORD="${values[WIFI_PASSWORD]:-}"
    WIFI_INTERFACE="${values[WIFI_INTERFACE]:-}"; WIFI_COUNTRY="${values[WIFI_COUNTRY]:-}"
    CHECK_INTERVAL="${values[CHECK_INTERVAL]:-60}"; XTEND_HOST="${values[XTEND_HOST]:-10.20.30.1}"
    XTEND_CLIENT_IP="${values[XTEND_CLIENT_IP]:-10.20.30.2/24}"
    validate_config
}

wpa_config_file() { printf '%s/wpa_supplicant-%s.conf' "$RUNTIME_DIR" "$WIFI_INTERFACE"; }
wpa_pid_file() { printf '%s/wpa_supplicant-%s.pid' "$RUNTIME_DIR" "$WIFI_INTERFACE"; }
wpa_ctrl_socket() { printf '%s/%s' "$RUNTIME_DIR" "$WIFI_INTERFACE"; }

detect_wifi_interface() {
    if [[ -n "$WIFI_INTERFACE" ]]; then
        iw dev "$WIFI_INTERFACE" info >/dev/null 2>&1 || die "Configured WIFI_INTERFACE '$WIFI_INTERFACE' is not a Wi-Fi device"
        return
    fi
    WIFI_INTERFACE="$(iw dev | awk '$1 == "Interface" { print $2; exit }')"
    [[ -n "$WIFI_INTERFACE" ]] || die "No Wi-Fi interface found; set WIFI_INTERFACE explicitly"
}

configure_runtime_dir() { install -d -m 0700 "$RUNTIME_DIR"; }

write_wpa_config() {
    local config_file temporary_file
    config_file="$(wpa_config_file)"; temporary_file="$(mktemp "$RUNTIME_DIR/.wpa.XXXXXX")"
    trap 'rm -f "$temporary_file"' RETURN
    {
        printf 'ctrl_interface=%s\nupdate_config=0\n' "$RUNTIME_DIR"
        [[ -z "$WIFI_COUNTRY" ]] || printf 'country=%s\n' "${WIFI_COUNTRY^^}"
        # wpa_passphrase emits a commented clear-text psk; never persist that.
        wpa_passphrase "$WIFI_SSID" "$WIFI_PASSWORD" | awk '
            # Let wpa_supplicant negotiate WPA2/cipher details advertised by the
            # Xtend. Pinning those values makes some appliance access points
            # reject the association before authentication can start.
            /^network=\{/ { print; print "\tscan_ssid=1"; next }
            /^[[:space:]]*#psk=/ { next }
            { print }
        '
    } >"$temporary_file"
    chmod 600 "$temporary_file"; mv -f "$temporary_file" "$config_file"; trap - RETURN
}

set_networkmanager_unmanaged() { command -v nmcli >/dev/null 2>&1 && nmcli device set "$WIFI_INTERFACE" managed no >/dev/null 2>&1 || true; }
wpa_running() {
    local pid_file pid; pid_file="$(wpa_pid_file)"; [[ -f "$pid_file" ]] || return 1
    pid="$(<"$pid_file")"; [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1
}
stop_wpa_supplicant() {
    local pid_file pid; pid_file="$(wpa_pid_file)"
    [[ ! -S "$(wpa_ctrl_socket)" ]] || wpa_cli -p "$RUNTIME_DIR" -i "$WIFI_INTERFACE" terminate >/dev/null 2>&1 || true
    if [[ -f "$pid_file" ]]; then pid="$(<"$pid_file")"; [[ ! "$pid" =~ ^[0-9]+$ ]] || kill "$pid" >/dev/null 2>&1 || true; rm -f "$pid_file"; fi
    ip addr flush dev "$WIFI_INTERFACE" scope global >/dev/null 2>&1 || true
}
start_wpa_supplicant() {
    configure_runtime_dir; wpa_running && return
    write_wpa_config; set_networkmanager_unmanaged
    ip link set "$WIFI_INTERFACE" down >/dev/null 2>&1 || true; ip link set "$WIFI_INTERFACE" up
    iw dev "$WIFI_INTERFACE" set power_save off >/dev/null 2>&1 || true
    wpa_supplicant -B -i "$WIFI_INTERFACE" -c "$(wpa_config_file)" -P "$(wpa_pid_file)"
}

wpa_status_field() { wpa_cli -p "$RUNTIME_DIR" -i "$WIFI_INTERFACE" status 2>/dev/null | awk -F= -v key="$1" '$1 == key { print substr($0, length(key) + 2); exit }'; }
wifi_connected() { [[ "$(wpa_status_field wpa_state)" == COMPLETED && "$(wpa_status_field ssid)" == "$WIFI_SSID" ]]; }
ensure_xtend_address() { ip address replace "$XTEND_CLIENT_IP" dev "$WIFI_INTERFACE"; }
xtend_reachable() { ping -c 1 -W 2 -I "$WIFI_INTERFACE" "$XTEND_HOST" >/dev/null 2>&1; }
connect_wifi() {
    local attempt state; log INFO "Connecting '$WIFI_INTERFACE' to '$WIFI_SSID'"
    stop_wpa_supplicant; start_wpa_supplicant
    for ((attempt = 1; attempt <= 20; attempt++)); do
        wifi_connected && { ensure_xtend_address; xtend_reachable && return 0; }
        state="$(wpa_status_field wpa_state || true)"; log DEBUG "Connection attempt $attempt/20; wpa_state=${state:-unknown}"; sleep 1
    done
    return 1
}
cleanup() { [[ -z "${WIFI_INTERFACE:-}" ]] || stop_wpa_supplicant; log INFO "Wi-Fi monitor stopped"; }
trap cleanup EXIT INT TERM

main() {
    local current_ssid last_state=unknown command
    for command in awk ip iw ping wpa_cli wpa_passphrase wpa_supplicant install mktemp; do require_command "$command"; done
    load_config; detect_wifi_interface
    log INFO "Starting Wi-Fi monitor (interface=$WIFI_INTERFACE, Xtend=$XTEND_HOST, interval=${CHECK_INTERVAL}s)"
    while true; do
        current_ssid="$(wpa_status_field ssid || true)"
        if wifi_connected; then
            ensure_xtend_address
            if xtend_reachable; then [[ "$last_state" == connected ]] || log INFO "Connected to '$WIFI_SSID'"; last_state=connected
            else log WARN "Xtend is unreachable while connected; reconnecting"; last_state=disconnected; connect_wifi || log WARN "Connection attempt failed; retrying later"; fi
        else
            [[ "$last_state" == disconnected ]] || log WARN "Not connected to '$WIFI_SSID' (current: ${current_ssid:-none})"
            last_state=disconnected; connect_wifi || log WARN "Connection attempt failed; retrying later"
        fi
        sleep "$CHECK_INTERVAL"
    done
}
main "$@"
