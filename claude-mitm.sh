#!/usr/bin/env bash
# Inspect the DECRYPTED HTTPS that `claude` sends, using mitmproxy.
#
# tcpdump only shows encrypted bytes. To read request/response bodies you must
# terminate TLS at a proxy you control and have claude (Node) trust its CA.
#
#   ./claude-mitm.sh proxy     # start mitmweb on :8080 (browse capture at http://127.0.0.1:8081)
#   ./claude-mitm.sh run       # run claude routed through the proxy, trusting its CA
#
# Requires: pip install mitmproxy   (or pipx install mitmproxy)
# First `proxy` run generates the CA at ~/.mitmproxy/mitmproxy-ca-cert.pem

set -euo pipefail

CA="$HOME/.mitmproxy/mitmproxy-ca-cert.pem"
PORT=8080

case "${1:-}" in
  proxy)
    exec mitmweb --listen-port "$PORT" --web-port 8081
    ;;
  run)
    shift
    if [[ ! -f "$CA" ]]; then
      echo "CA not found at $CA — run './claude-mitm.sh proxy' once first." >&2
      exit 1
    fi
    # Node honors HTTPS_PROXY and NODE_EXTRA_CA_CERTS.
    export HTTPS_PROXY="http://127.0.0.1:${PORT}"
    export HTTP_PROXY="http://127.0.0.1:${PORT}"
    export NODE_EXTRA_CA_CERTS="$CA"
    exec claude "$@"
    ;;
  *)
    echo "usage: $0 {proxy|run}"; exit 1 ;;
esac
