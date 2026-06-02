#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# Xtend HTTP reverse proxy
#
# Runs on a Raspberry Pi (or similar) that has:
# - Wi-Fi connected to the Xtend AP
# - Ethernet connected to the Home Assistant network
#
# The script forwards requests from Home Assistant to the Xtend API.
###############################################################################

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

log() {
	local level="$1"
	shift
	printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

if [[ -f "$ENV_FILE" ]]; then
	set -a
	# shellcheck disable=SC1090
	source "$ENV_FILE"
	set +a
fi

# Where HA should connect
LISTEN_HOST="${LISTEN_HOST:-0.0.0.0}"
LISTEN_PORT="${LISTEN_PORT:-8080}"

# Where the physical Xtend API lives
XTEND_HOST="${XTEND_HOST:-10.20.30.1}"
XTEND_PORT="${XTEND_PORT:-80}"

# Keep defaults strict so only the expected endpoint is proxied by default.
ALLOWED_PATH="${ALLOWED_PATH:-/api/stats/values}"

if ! command -v python3 >/dev/null 2>&1; then
	log ERROR "python3 is required but not found in PATH"
	exit 1
fi

log INFO "Starting Xtend proxy"
log INFO "Listening on: ${LISTEN_HOST}:${LISTEN_PORT}"
log INFO "Forwarding to: ${XTEND_HOST}:${XTEND_PORT}"
log INFO "Allowed path: ${ALLOWED_PATH}"

export LISTEN_HOST
export LISTEN_PORT
export XTEND_HOST
export XTEND_PORT
export ALLOWED_PATH

exec python3 -u - <<'PY'
import os
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


LISTEN_HOST = os.environ["LISTEN_HOST"]
LISTEN_PORT = int(os.environ["LISTEN_PORT"])
XTEND_HOST = os.environ["XTEND_HOST"]
XTEND_PORT = int(os.environ["XTEND_PORT"])
ALLOWED_PATH = os.environ["ALLOWED_PATH"]


class XtendProxyHandler(BaseHTTPRequestHandler):
	protocol_version = "HTTP/1.1"

	def do_GET(self) -> None:
		if self.path == "/healthz":
			self._write_text(200, "ok")
			return

		target_path = self.path.split("?", 1)[0]
		if target_path != ALLOWED_PATH:
			self._write_text(404, "Not Found")
			return

		upstream_url = f"http://{XTEND_HOST}:{XTEND_PORT}{self.path}"
		request_headers = {
			"Accept": self.headers.get("Accept", "application/json"),
			"User-Agent": self.headers.get("User-Agent", "intergas-xtend-proxy"),
		}

		try:
			req = Request(upstream_url, headers=request_headers, method="GET")
			with urlopen(req, timeout=10) as upstream:
				body = upstream.read()
				status = upstream.getcode()
				content_type = upstream.headers.get("Content-Type", "application/json")

			self.send_response(status)
			self.send_header("Content-Type", content_type)
			self.send_header("Content-Length", str(len(body)))
			self.send_header("Connection", "close")
			self.end_headers()
			self.wfile.write(body)
		except HTTPError as exc:
			message = f"Upstream HTTP error: {exc.code}\n"
			self._write_text(502, message)
		except (URLError, TimeoutError, socket.timeout) as exc:
			message = f"Upstream unreachable: {exc}\n"
			self._write_text(502, message)

	def log_message(self, fmt: str, *args) -> None:
		# Keep logging simple and systemd/journal friendly.
		print(f"{self.address_string()} - {fmt % args}")

	def _write_text(self, status_code: int, text: str) -> None:
		body = text.encode("utf-8")
		self.send_response(status_code)
		self.send_header("Content-Type", "text/plain; charset=utf-8")
		self.send_header("Content-Length", str(len(body)))
		self.send_header("Connection", "close")
		self.end_headers()
		self.wfile.write(body)


def main() -> None:
	server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), XtendProxyHandler)
	print(
		f"Xtend proxy listening on http://{LISTEN_HOST}:{LISTEN_PORT} "
		f"-> http://{XTEND_HOST}:{XTEND_PORT}{ALLOWED_PATH}"
	)
	server.serve_forever()


if __name__ == "__main__":
	main()
PY
