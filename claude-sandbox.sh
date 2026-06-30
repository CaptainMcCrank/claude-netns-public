#!/usr/bin/env bash
# Run `claude` in an isolated network namespace so tcpdump sees ONLY its traffic.
#
#   sudo ./claude-sandbox.sh up        # create namespace + NAT
#   sudo ./claude-sandbox.sh sniff     # tcpdump on the namespace's interface
#   sudo ./claude-sandbox.sh run       # launch claude inside the namespace (as your user)
#   sudo ./claude-sandbox.sh down      # tear everything down
#
# Typical use: terminal 1 -> `up` then `sniff`; terminal 2 -> `run`.

set -euo pipefail

NS=claudesbx
HOST_IF=veth-host
NS_IF=veth-ns
HOST_IP=10.200.1.1
NS_IP=10.200.1.2
SUBNET=10.200.1.0/24
USER_NAME="${SUDO_USER:-$(id -un)}"
PCAP="/home/${USER_NAME}/Development/claude-netns/claude.pcap"

# Pick the host's default-route interface for NAT egress.
UPLINK="$(ip route show default | awk '/default/ {print $5; exit}')"

up() {
  ip netns add "$NS"
  ip link add "$HOST_IF" type veth peer name "$NS_IF"
  ip link set "$NS_IF" netns "$NS"

  ip addr add "${HOST_IP}/24" dev "$HOST_IF"
  ip link set "$HOST_IF" up

  ip netns exec "$NS" ip addr add "${NS_IP}/24" dev "$NS_IF"
  ip netns exec "$NS" ip link set "$NS_IF" up
  ip netns exec "$NS" ip link set lo up
  ip netns exec "$NS" ip route add default via "$HOST_IP"

  # DNS for processes inside the namespace
  mkdir -p "/etc/netns/$NS"
  echo "nameserver 1.1.1.1" > "/etc/netns/$NS/resolv.conf"

  # NAT the namespace out through the real uplink
  sysctl -wq net.ipv4.ip_forward=1
  iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$UPLINK" -j MASQUERADE
  iptables -A FORWARD -i "$HOST_IF" -o "$UPLINK" -j ACCEPT
  iptables -A FORWARD -i "$UPLINK" -o "$HOST_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

  echo "namespace '$NS' up. uplink=$UPLINK"
}

sniff() {
  # The host side of the veth carries exactly and only the namespace's traffic.
  echo "writing $PCAP  (Ctrl-C to stop). Live DNS + TLS SNI shown below:"
  tcpdump -i "$HOST_IF" -n -w "$PCAP" -U &
  TPID=$!
  trap 'kill "$TPID" 2>/dev/null || true' EXIT
  # Print DNS queries and TLS ClientHello (SNI) live so you can watch destinations.
  tcpdump -i "$HOST_IF" -n -l 'udp port 53 or (tcp[((tcp[12]&0xf0)>>2)]=22)' 2>/dev/null || true
  wait "$TPID"
}

run() {
  # Drop back to your user inside the namespace so claude uses your config/creds.
  exec ip netns exec "$NS" sudo -u "$USER_NAME" --preserve-env=HOME,PATH \
       env HOME="/home/${USER_NAME}" claude "$@"
}

down() {
  iptables -t nat -D POSTROUTING -s "$SUBNET" -o "$UPLINK" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i "$HOST_IF" -o "$UPLINK" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$UPLINK" -o "$HOST_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  ip netns del "$NS" 2>/dev/null || true
  ip link del "$HOST_IF" 2>/dev/null || true
  rm -rf "/etc/netns/$NS"
  echo "namespace '$NS' down."
}

case "${1:-}" in
  up) up ;;
  sniff) sniff ;;
  run) shift; run "$@" ;;
  down) down ;;
  *) echo "usage: sudo $0 {up|sniff|run|down}"; exit 1 ;;
esac
