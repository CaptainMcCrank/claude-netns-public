#!/usr/bin/env bash
# One-shot DECRYPTED capture of claude's HTTPS traffic via mitmproxy.
#
# Starts mitmdump with the mitm_logger addon, runs a single claude prompt routed
# through it (Node trusting mitmproxy's CA), then stops the proxy. The full
# decrypted transcript lands in mitm.txt.
#
#   ./mitm-capture.sh "Use the WebFetch tool to fetch https://example.com and report the title."
#
# Requires: mitmproxy (pipx install mitmproxy), and the CA generated once by any
# mitmproxy run (~/.mitmproxy/mitmproxy-ca-cert.pem).

set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${MITM_PORT:-8091}"
CA="$HOME/.mitmproxy/mitmproxy-ca-cert.pem"
LOG="$WORKDIR/mitm.txt"
OUT="$WORKDIR/claude-stdout.txt"
PROMPT="${1:-Use the WebFetch tool to fetch https://example.com and report the page title.}"

[[ -f "$CA" ]] || { echo "CA missing at $CA — run 'mitmdump' once to generate it." >&2; exit 1; }

: > "$LOG"

# Start the intercepting proxy in the background.
mitmdump -p "$PORT" -q -s "$WORKDIR/mitm_logger.py" \
         --set "logfile=$LOG" --set bodymax=4000 \
         >"$WORKDIR/mitmdump.log" 2>&1 &
MP=$!
trap 'kill "$MP" 2>/dev/null || true' EXIT

# Wait for the proxy to accept connections.
for i in $(seq 1 50); do
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && { exec 3>&- 3<&-; break; }
  sleep 0.1
done

# Route claude through the proxy, trusting the mitmproxy CA (Node honors both).
HTTPS_PROXY="http://127.0.0.1:$PORT" \
HTTP_PROXY="http://127.0.0.1:$PORT" \
NODE_EXTRA_CA_CERTS="$CA" \
  bash -c 'printf "%s" "$1" | claude -p --allowedTools WebFetch WebSearch' _ "$PROMPT" \
  > "$OUT" 2>&1 || echo "(claude exited non-zero)"

sleep 1
kill "$MP" 2>/dev/null || true
wait "$MP" 2>/dev/null || true

echo "=== claude reply ==="; cat "$OUT"
echo "=== transcript: $LOG ($(wc -l < "$LOG") lines) ==="
