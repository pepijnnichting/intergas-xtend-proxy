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
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
FORCE="false"

usage() {
    cat <<'EOF'
Usage:
  sudo ./install.sh [options]

Options:
  --ssid <name>           Xtend Wi-Fi SSID (e.g. Xtend_xxxxxxxxxx)
  --password <password>   Xtend Wi-Fi password
  --check-interval <sec>  Reconnect check interval in seconds (default: 60)
  --force                 Overwrite existing .env without prompting
  -h, --help              Show this help

Environment variables (alternative to flags):
  WIFI_SSID, WIFI_PASSWORD, CHECK_INTERVAL
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

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssid)
                WIFI_SSID="${2:-}"
                shift 2
                ;;
            --password)
                WIFI_PASSWORD="${2:-}"
                shift 2
                ;;
            --check-interval)
                CHECK_INTERVAL="${2:-}"
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
    log INFO "Installing required packages (nginx, network-manager)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y nginx network-manager
}

install_files() {
    local service_user

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        service_user="$SUDO_USER"
    else
        service_user="pi"
    fi

    log INFO "Installing files to $INSTALL_DIR"
    install -d -m 0755 "$INSTALL_DIR"

    install -m 0755 "$SCRIPT_DIR/xtend-connect.sh" "$INSTALL_DIR/xtend-connect.sh"
    install -m 0644 "$SCRIPT_DIR/xtend-connect.service" "$INSTALL_DIR/xtend-connect.service"
    install -m 0644 "$SCRIPT_DIR/xtend-proxy.nginx.conf" "$INSTALL_DIR/xtend-proxy.nginx.conf"

    # Make the service run as the invoking sudo user by default.
    sed -i.bak "s/^User=.*/User=${service_user}/" "$INSTALL_DIR/xtend-connect.service"

    install -m 0644 "$INSTALL_DIR/xtend-connect.service" "$SYSTEMD_DIR/xtend-connect.service"
}

write_env_file() {
    local overwrite

    if [[ -z "$WIFI_SSID" ]]; then
        read -r -p "Xtend SSID (e.g. Xtend_xxxxxxxxxx): " WIFI_SSID
    fi

    if [[ -z "$WIFI_PASSWORD" ]]; then
        read -r -s -p "Xtend password: " WIFI_PASSWORD
        printf '\n'
    fi

    [[ -n "$WIFI_SSID" ]] || die "WIFI_SSID is required"
    [[ -n "$WIFI_PASSWORD" ]] || die "WIFI_PASSWORD is required"
    [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] || die "CHECK_INTERVAL must be a number"

    overwrite="yes"
    if [[ -f "$ENV_FILE" && "$FORCE" != "true" ]]; then
        read -r -p "$ENV_FILE already exists. Overwrite? [y/N]: " overwrite
        overwrite="${overwrite:-N}"
    fi

    if [[ ! -f "$ENV_FILE" || "$FORCE" == "true" || "$overwrite" =~ ^[Yy]$ ]]; then
        umask 077
        cat >"$ENV_FILE" <<EOF
WIFI_SSID=$WIFI_SSID
WIFI_PASSWORD=$WIFI_PASSWORD
CHECK_INTERVAL=$CHECK_INTERVAL
EOF
        log INFO "Wrote $ENV_FILE"
    else
        log INFO "Keeping existing $ENV_FILE"
    fi
}

configure_nginx() {
    log INFO "Configuring nginx site"

    install -m 0644 "$INSTALL_DIR/xtend-proxy.nginx.conf" "$NGINX_AVAILABLE_DIR/xtend-proxy"
    ln -sfn "$NGINX_AVAILABLE_DIR/xtend-proxy" "$NGINX_ENABLED_DIR/xtend-proxy"
    rm -f "$NGINX_ENABLED_DIR/default"

    nginx -t
}

enable_services() {
    log INFO "Enabling and starting services"
    systemctl daemon-reload
    systemctl enable --now nginx
    systemctl reload nginx
    systemctl enable --now xtend-connect.service
}

print_summary() {
    cat <<EOF

Install complete.

Next steps:
1) Find the Raspberry Pi LAN IP:
   ip -4 addr show

2) Test the proxy from your LAN:
   curl "http://<PI_IP>:8080/healthz"
   curl "http://<PI_IP>:8080/api/stats/values?fields=0001"

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
    write_env_file
    configure_nginx
    enable_services
    print_summary
}

main "$@"
