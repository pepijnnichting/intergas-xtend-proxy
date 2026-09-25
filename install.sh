#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/intergas-xtend-proxy"
SYSTEMD_DIR="/etc/systemd/system"
NGINX_AVAILABLE_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
ENV_FILE="$INSTALL_DIR/.env"

WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
WIFI_INTERFACE="${WIFI_INTERFACE:-}"
WIFI_COUNTRY="${WIFI_COUNTRY:-}"
XTEND_HOST_SET="${XTEND_HOST+x}"
XTEND_HOST="${XTEND_HOST-}"
CHECK_INTERVAL_SET="${CHECK_INTERVAL+x}"
XTEND_CLIENT_IP_SET="${XTEND_CLIENT_IP+x}"
CHECK_INTERVAL="${CHECK_INTERVAL-}"
XTEND_CLIENT_IP="${XTEND_CLIENT_IP-}"
FORCE="false"
WIFI_SSID_SET="false"
WIFI_PASSWORD_SET="false"
WIFI_INTERFACE_SET="false"
WIFI_COUNTRY_SET="false"
EXISTING_WIFI_SSID=""
EXISTING_WIFI_PASSWORD=""
EXISTING_WIFI_INTERFACE=""
EXISTING_WIFI_COUNTRY=""
EXISTING_XTEND_HOST=""
EXISTING_CHECK_INTERVAL=""
EXISTING_XTEND_CLIENT_IP=""

if [[ -n "$WIFI_SSID" ]]; then
    WIFI_SSID_SET="true"
fi

if [[ -n "$WIFI_PASSWORD" ]]; then
    WIFI_PASSWORD_SET="true"
fi

if [[ -n "$WIFI_INTERFACE" ]]; then
    WIFI_INTERFACE_SET="true"
fi

if [[ -n "$WIFI_COUNTRY" ]]; then
    WIFI_COUNTRY_SET="true"
fi

[[ "$XTEND_HOST_SET" == x ]] && XTEND_HOST_SET="true" || XTEND_HOST_SET="false"

[[ "$CHECK_INTERVAL_SET" == x ]] && CHECK_INTERVAL_SET="true" || CHECK_INTERVAL_SET="false"
[[ "$XTEND_CLIENT_IP_SET" == x ]] && XTEND_CLIENT_IP_SET="true" || XTEND_CLIENT_IP_SET="false"

usage() {
    cat <<'EOF'
Usage:
  sudo ./install.sh [options]

Options:
  --ssid <name>           Xtend Wi-Fi SSID (e.g. Xtend_xxxxxxxxxx)
  --password <password>   Xtend Wi-Fi password
  --interface <name>      Wi-Fi interface name (optional, e.g. wlan0)
  --country <code>        Wi-Fi country code (optional, e.g. NL)
  --xtend-host <address>  Xtend address (default: 10.20.30.1)
  --check-interval <sec>  Reconnect check interval in seconds (default: 60)
  --client-ip <cidr>      Static IP on the Xtend subnet (default: 10.20.30.2/24)
  --force                 Overwrite existing .env without prompting
  -h, --help              Show this help

Environment variables (alternative to flags):
  WIFI_SSID, WIFI_PASSWORD, WIFI_INTERFACE, WIFI_COUNTRY, XTEND_HOST,
  CHECK_INTERVAL, XTEND_CLIENT_IP
EOF
}

log() {
    local level="$1"
    shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

die() {
    log ERROR "$*"
    exit 1
}

is_ipv4() {
    local address="$1" octet
    local -a octets
    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<<"$address"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || return 1
    done
}

read_env_value() {
    local key="$1"

    if [[ ! -f "$ENV_FILE" ]]; then
        return 0
    fi

    awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1)}' "$ENV_FILE" | tail -n1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssid)
                [[ $# -ge 2 && -n "$2" ]] || die "--ssid needs a value"
                WIFI_SSID="$2"
                WIFI_SSID_SET="true"
                shift 2
                ;;
            --password)
                [[ $# -ge 2 && -n "$2" ]] || die "--password needs a value"
                WIFI_PASSWORD="$2"
                WIFI_PASSWORD_SET="true"
                shift 2
                ;;
            --interface)
                [[ $# -ge 2 && -n "$2" ]] || die "--interface needs a value"
                WIFI_INTERFACE="$2"
                WIFI_INTERFACE_SET="true"
                shift 2
                ;;
            --country)
                [[ $# -ge 2 && -n "$2" ]] || die "--country needs a value"
                WIFI_COUNTRY="$2"
                WIFI_COUNTRY_SET="true"
                shift 2
                ;;
            --xtend-host)
                [[ $# -ge 2 && -n "$2" ]] || die "--xtend-host needs a value"
                XTEND_HOST="$2"
                XTEND_HOST_SET="true"
                shift 2
                ;;
            --check-interval)
                [[ $# -ge 2 && -n "$2" ]] || die "--check-interval needs a value"
                CHECK_INTERVAL="$2"
                CHECK_INTERVAL_SET="true"
                shift 2
                ;;
            --client-ip)
                [[ $# -ge 2 && -n "$2" ]] || die "--client-ip needs a value"
                XTEND_CLIENT_IP="$2"
                XTEND_CLIENT_IP_SET="true"
                shift 2
                ;;
            --force)
                FORCE="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        die "Run this script as root (use: sudo ./install.sh ...)"
    fi
}

install_packages() {
    log INFO "Installing required packages (nginx, wpasupplicant, iw)"
    command -v apt-get >/dev/null 2>&1 || die "This installer supports Debian/Raspberry Pi OS (apt-get) only"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y nginx wpasupplicant iw
}

install_files() {

    log INFO "Installing files to $INSTALL_DIR"
    install -d -m 0755 "$INSTALL_DIR"

    install -m 0755 "$SCRIPT_DIR/xtend-connect.sh" "$INSTALL_DIR/xtend-connect.sh"
    install -m 0644 "$SCRIPT_DIR/xtend-connect.service" "$INSTALL_DIR/xtend-connect.service"
    install -m 0644 "$SCRIPT_DIR/xtend-proxy.nginx.conf" "$INSTALL_DIR/xtend-proxy.nginx.conf"

    install -m 0644 "$INSTALL_DIR/xtend-connect.service" "$SYSTEMD_DIR/xtend-connect.service"
}

load_existing_env_defaults() {
    if [[ ! -f "$ENV_FILE" ]]; then
        return
    fi

    EXISTING_WIFI_SSID="$(read_env_value WIFI_SSID)"
    EXISTING_WIFI_PASSWORD="$(read_env_value WIFI_PASSWORD)"
    EXISTING_WIFI_INTERFACE="$(read_env_value WIFI_INTERFACE)"
    EXISTING_WIFI_COUNTRY="$(read_env_value WIFI_COUNTRY)"
    EXISTING_XTEND_HOST="$(read_env_value XTEND_HOST)"
    EXISTING_CHECK_INTERVAL="$(read_env_value CHECK_INTERVAL)"
    EXISTING_XTEND_CLIENT_IP="$(read_env_value XTEND_CLIENT_IP)"

    if [[ "$WIFI_SSID_SET" != "true" && -n "$EXISTING_WIFI_SSID" ]]; then
        WIFI_SSID="$EXISTING_WIFI_SSID"
    fi

    if [[ "$WIFI_PASSWORD_SET" != "true" && -n "$EXISTING_WIFI_PASSWORD" ]]; then
        WIFI_PASSWORD="$EXISTING_WIFI_PASSWORD"
    fi

    if [[ "$WIFI_INTERFACE_SET" != "true" && -n "$EXISTING_WIFI_INTERFACE" ]]; then
        WIFI_INTERFACE="$EXISTING_WIFI_INTERFACE"
    fi

    if [[ "$WIFI_COUNTRY_SET" != "true" && -n "$EXISTING_WIFI_COUNTRY" ]]; then
        WIFI_COUNTRY="$EXISTING_WIFI_COUNTRY"
    fi

    if [[ "$XTEND_HOST_SET" != "true" && -n "$EXISTING_XTEND_HOST" ]]; then
        XTEND_HOST="$EXISTING_XTEND_HOST"
    fi

    if [[ "$CHECK_INTERVAL_SET" != "true" ]] \
        && [[ -n "$EXISTING_CHECK_INTERVAL" ]] \
        && [[ "$EXISTING_CHECK_INTERVAL" =~ ^[0-9]+$ ]]; then
        CHECK_INTERVAL="$EXISTING_CHECK_INTERVAL"
    fi

    if [[ "$XTEND_CLIENT_IP_SET" != "true" ]] && [[ -n "$EXISTING_XTEND_CLIENT_IP" ]]; then
        XTEND_CLIENT_IP="$EXISTING_XTEND_CLIENT_IP"
    fi

    log INFO "Loaded existing values from $ENV_FILE"
}

write_env_file() {
    local overwrite temporary_env

    if [[ -z "$WIFI_SSID" ]]; then
        read -r -p "Xtend SSID (e.g. Xtend_xxxxxxxxxx): " WIFI_SSID
    fi

    if [[ -z "$WIFI_PASSWORD" ]]; then
        read -r -s -p "Xtend password: " WIFI_PASSWORD
        printf '\n'
    fi

    CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
    XTEND_CLIENT_IP="${XTEND_CLIENT_IP:-10.20.30.2/24}"
    XTEND_HOST="${XTEND_HOST:-10.20.30.1}"
    [[ -n "$WIFI_SSID" && ${#WIFI_SSID} -le 32 ]] || die "WIFI_SSID must be 1–32 characters"
    [[ "$WIFI_PASSWORD" =~ ^.{8,63}$ ]] || die "WIFI_PASSWORD must be 8–63 characters"
    [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] || die "CHECK_INTERVAL must be a number"
    local client_ip prefix
    [[ "$XTEND_CLIENT_IP" =~ ^([^/]+)/([0-9]{1,2})$ ]] || die "XTEND_CLIENT_IP must be in CIDR form, e.g. 10.20.30.2/24"
    client_ip="${BASH_REMATCH[1]}"; prefix="${BASH_REMATCH[2]}"
    is_ipv4 "$client_ip" && ((10#$prefix <= 32)) || die "XTEND_CLIENT_IP must be in CIDR form, e.g. 10.20.30.2/24"
    [[ -z "$WIFI_INTERFACE" || "$WIFI_INTERFACE" =~ ^[[:alnum:]_.:-]+$ ]] || die "WIFI_INTERFACE contains invalid characters"
    [[ -z "$WIFI_COUNTRY" || "$WIFI_COUNTRY" =~ ^[A-Za-z]{2}$ ]] || die "WIFI_COUNTRY must be a two-letter country code"
    is_ipv4 "$XTEND_HOST" || die "XTEND_HOST must be an IPv4 address"

    if [[ -f "$ENV_FILE" && "$FORCE" != "true" ]]; then
        if [[ "$WIFI_SSID" == "$EXISTING_WIFI_SSID" ]] \
            && [[ "$WIFI_PASSWORD" == "$EXISTING_WIFI_PASSWORD" ]] \
            && [[ "$WIFI_INTERFACE" == "$EXISTING_WIFI_INTERFACE" ]] \
            && [[ "$WIFI_COUNTRY" == "$EXISTING_WIFI_COUNTRY" ]] \
            && [[ "$XTEND_HOST" == "$EXISTING_XTEND_HOST" ]] \
            && [[ "$CHECK_INTERVAL" == "$EXISTING_CHECK_INTERVAL" ]] \
            && [[ "$XTEND_CLIENT_IP" == "$EXISTING_XTEND_CLIENT_IP" ]]; then
            log INFO "Existing $ENV_FILE already matches requested values"
            return
        fi
    fi

    overwrite="yes"
    if [[ -f "$ENV_FILE" && "$FORCE" != "true" ]]; then
        read -r -p "$ENV_FILE already exists. Overwrite? [y/N]: " overwrite
        overwrite="${overwrite:-N}"
    fi

    if [[ ! -f "$ENV_FILE" || "$FORCE" == "true" || "$overwrite" =~ ^[Yy]$ ]]; then
        umask 077
        temporary_env="$(mktemp "$INSTALL_DIR/.env.XXXXXX")"
        trap 'rm -f "$temporary_env"' RETURN
        {
            printf 'WIFI_SSID=%s\nWIFI_PASSWORD=%s\nCHECK_INTERVAL=%s\nXTEND_CLIENT_IP=%s\nXTEND_HOST=%s\n' \
                "$WIFI_SSID" "$WIFI_PASSWORD" "$CHECK_INTERVAL" "$XTEND_CLIENT_IP" "$XTEND_HOST"
            [[ -z "$WIFI_INTERFACE" ]] || printf 'WIFI_INTERFACE=%s\n' "$WIFI_INTERFACE"
            [[ -z "$WIFI_COUNTRY" ]] || printf 'WIFI_COUNTRY=%s\n' "$WIFI_COUNTRY"
        } >"$temporary_env"
        chmod 600 "$temporary_env"
        mv -f "$temporary_env" "$ENV_FILE"
        trap - RETURN
        log INFO "Wrote $ENV_FILE"
    else
        log INFO "Keeping existing $ENV_FILE"
    fi
}

configure_nginx() {
    log INFO "Configuring nginx site"

    install -m 0644 "$INSTALL_DIR/xtend-proxy.nginx.conf" "$NGINX_AVAILABLE_DIR/xtend-proxy"
    # Do not remove the distribution's default site: it may serve another app.
    # Port 8080 does not conflict with it.
    ln -sfn "$NGINX_AVAILABLE_DIR/xtend-proxy" "$NGINX_ENABLED_DIR/xtend-proxy"

    nginx -t
}

enable_services() {
    log INFO "Enabling and starting services"
    systemctl daemon-reload
    systemctl enable --now nginx
    systemctl reload nginx
    systemctl enable --now xtend-connect.service
    systemctl is-active --quiet nginx || die "nginx did not start; inspect: systemctl status nginx"
    systemctl is-active --quiet xtend-connect.service || die "xtend-connect did not start; inspect: systemctl status xtend-connect.service"
}

print_summary() {
    cat <<EOF

Install complete.

Next steps:
1) Find the Raspberry Pi LAN IP:
   ip -4 addr show

2) Test the proxy from your LAN:
   curl "http://<PI_IP>:8080/healthz"
    curl "http://<PI_IP>:8080/api/stats/values?fields=79b3"
    Open web UI: http://<PI_IP>:8080/

3) In Home Assistant Intergas Xtend integration:
   Host: <PI_IP>
   Port: 8080

Useful logs:
  journalctl -u xtend-connect.service -f
  journalctl -u nginx -f
EOF
}

main() {
    parse_args "$@"
    require_root
    install_packages
    install_files
    load_existing_env_defaults
    write_env_file
    configure_nginx
    enable_services
    print_summary
}

main "$@"
