#!/usr/bin/env bash
# Rootless capture of claude's network traffic.
#
# Creates a user+net+mount namespace (no sudo), attaches slirp4netns for
# userspace NAT, captures on the namespace's tap0 (we have CAP_NET_RAW *inside*
# the user namespace), then runs `claude` with a web-fetch prompt and tears down.
#
#   ./rootless-capture.sh "Use WebFetch to get https://example.com and report the title."
#
# Output: claude.pcap (capture) and claude-stdout.txt (claude's reply) in this dir.

set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
PCAP="$WORKDIR/claude.pcap"
OUT="$WORKDIR/claude-stdout.txt"
PROMPT="${1:-Use WebFetch to retrieve https://example.com and tell me the page title.}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Inner script: runs as root *inside* the namespace.
cat > "$TMP/inner.sh" <<INNER
#!/usr/bin/env bash
set -euo pipefail
ip link set lo up 2>/dev/null || true

# slirp4netns provides DNS at 10.0.2.3; point resolv.conf there via a bind mount
# (only visible inside our mount namespace).
echo "nameserver 10.0.2.3" > "$TMP/resolv.conf"
mount --bind "$TMP/resolv.conf" /etc/resolv.conf

# Wait until slirp4netns (running in the parent) configures tap0's default route.
for i in \$(seq 1 100); do
  ip route 2>/dev/null | grep -q '^default' && break
  sleep 0.1
done
echo "[inner] interfaces:"; ip -brief addr 2>/dev/null || true
echo "[inner] routes:"; ip route 2>/dev/null || true

# Capture everything crossing tap0 — this is ONLY this namespace's traffic.
# (Custom raw-socket sniffer: tcpdump can't drop privileges in this userns.)
python3 "$WORKDIR/nssniff.py" tap0 "$PCAP" 2>"$WORKDIR/sniff.log" &
TPID=\$!
sleep 0.5

# Run claude through the namespace, using the real user's config.
printf '%s' "$PROMPT" | claude -p --allowedTools WebFetch WebSearch > "$OUT" 2>&1 || echo "[inner] claude exited \$?"

sleep 0.8
kill \$TPID 2>/dev/null || true
wait \$TPID 2>/dev/null || true
echo "[inner] sniffer stderr:"; cat "$WORKDIR/sniff.log" 2>/dev/null | sed 's/^/  /'
echo "[inner] capture done"
INNER
chmod +x "$TMP/inner.sh"

# Launch the namespace; --fork+--kill-child so the child dies with unshare.
unshare --user --map-root-user --net --mount --pid --fork --kill-child \
        bash "$TMP/inner.sh" &
NSPID=$!

# Give unshare a moment to create the namespaces, then attach slirp4netns.
sleep 0.4
slirp4netns --configure --mtu=65520 --disable-host-loopback "$NSPID" tap0 \
        >"$TMP/slirp.log" 2>&1 &
SLIRP=$!

# Wait for the namespaced work to finish, then stop slirp.
wait "$NSPID" 2>/dev/null || true
kill "$SLIRP" 2>/dev/null || true

echo "=== slirp4netns log ==="; cat "$TMP/slirp.log" 2>/dev/null || true
echo "=== pcap ==="; ls -la "$PCAP" 2>/dev/null || echo "no pcap produced"
