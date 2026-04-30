#!/usr/bin/env bash
set -euo pipefail

# Two-node tinc lab using Linux network namespaces.
# This is local-only and reversible: sudo ./scripts/tinc_ns_lab.sh clean

ROOT=${ROOT:-/tmp/tinc-openwrt-hardened-lab}
REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
TINCD=${TINCD:-$REPO/src/tincd}
NET=${NET:-lab}
NS_A=${NS_A:-tinc-a}
NS_B=${NS_B:-tinc-b}
UNDERLAY_A=10.255.91.1
UNDERLAY_B=10.255.91.2
VPN_A=10.91.0.1
VPN_B=10.91.0.2
PORT_A=6551
PORT_B=6552

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Please run as root: sudo $0 $*" >&2
    exit 1
  fi
}

clean() {
  need_root clean
  pkill -f "tincd.*$ROOT" 2>/dev/null || true
  ip netns pids "$NS_A" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns pids "$NS_B" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns del "$NS_A" 2>/dev/null || true
  ip netns del "$NS_B" 2>/dev/null || true
  rm -rf "$ROOT"
}

write_node() {
  local node=$1 underlay=$2 vpn=$3 port=$4 peer=$5 peer_underlay=$6 peer_vpn=$7 peer_port=$8
  local dir="$ROOT/$node"
  mkdir -p "$dir/hosts" "$dir/log"
  openssl genrsa -out "$dir/rsa_key.priv" 2048 >/dev/null 2>&1

  cat >"$dir/tinc.conf" <<EOF
Name = $node
Device = /dev/net/tun
DeviceType = tun
Interface = tinc-$node
AddressFamily = ipv4
Port = $port
ConnectTo = $peer
PingTimeout = 5
MaxTimeout = 20
ClampMSS = yes
PMTUDiscovery = yes
EOF

  cat >"$dir/hosts/$node" <<EOF
Address = $underlay
Port = $port
Subnet = $vpn/32
ClampMSS = yes
PMTUDiscovery = yes
EOF
  openssl rsa -in "$dir/rsa_key.priv" -RSAPublicKey_out >>"$dir/hosts/$node" 2>/dev/null

  cat >"$dir/tinc-up" <<EOF
#!/bin/sh
ip addr add $vpn/24 dev \$INTERFACE
ip link set \$INTERFACE mtu 1380 up
EOF
  chmod +x "$dir/tinc-up"

  cat >"$dir/tinc-down" <<'EOF'
#!/bin/sh
ip link set $INTERFACE down 2>/dev/null || true
EOF
  chmod +x "$dir/tinc-down"
}

setup() {
  need_root setup
  clean || true
  mkdir -p "$ROOT"

  write_node a "$UNDERLAY_A" "$VPN_A" "$PORT_A" b "$UNDERLAY_B" "$VPN_B" "$PORT_B"
  write_node b "$UNDERLAY_B" "$VPN_B" "$PORT_B" a "$UNDERLAY_A" "$VPN_A" "$PORT_A"
  cp "$ROOT/a/hosts/a" "$ROOT/b/hosts/a"
  cp "$ROOT/b/hosts/b" "$ROOT/a/hosts/b"

  ip netns add "$NS_A"
  ip netns add "$NS_B"
  ip link add veth-a type veth peer name veth-b
  ip link set veth-a netns "$NS_A"
  ip link set veth-b netns "$NS_B"
  ip -n "$NS_A" addr add "$UNDERLAY_A/24" dev veth-a
  ip -n "$NS_B" addr add "$UNDERLAY_B/24" dev veth-b
  ip -n "$NS_A" link set lo up
  ip -n "$NS_B" link set lo up
  ip -n "$NS_A" link set veth-a up mtu 1500
  ip -n "$NS_B" link set veth-b up mtu 1500
}

start() {
  need_root start
  [[ -x "$TINCD" ]] || { echo "Missing tincd: $TINCD" >&2; exit 1; }
  ip netns exec "$NS_A" "$TINCD" -n "$NET" -c "$ROOT/a" --logfile="$ROOT/a/log/tinc.log" --pidfile="$ROOT/a/tinc.pid" -d1
  ip netns exec "$NS_B" "$TINCD" -n "$NET" -c "$ROOT/b" --logfile="$ROOT/b/log/tinc.log" --pidfile="$ROOT/b/tinc.pid" -d1
  sleep 2
}

stop() {
  need_root stop
  [[ -f "$ROOT/a/tinc.pid" ]] && kill "$(cat "$ROOT/a/tinc.pid")" 2>/dev/null || true
  [[ -f "$ROOT/b/tinc.pid" ]] && kill "$(cat "$ROOT/b/tinc.pid")" 2>/dev/null || true
}

test_lab() {
  need_root test
  echo "== underlay =="
  ip netns exec "$NS_A" ping -c 2 -W 1 "$UNDERLAY_B"
  echo "== vpn ping =="
  ip netns exec "$NS_A" ping -c 5 -W 1 "$VPN_B"
  echo "== links =="
  ip -n "$NS_A" -br addr
  ip -n "$NS_B" -br addr
  echo "== logs A =="
  tail -80 "$ROOT/a/log/tinc.log" || true
  echo "== logs B =="
  tail -80 "$ROOT/b/log/tinc.log" || true
}

case "${1:-}" in
  setup) setup ;;
  start) start ;;
  stop) stop ;;
  test) test_lab ;;
  clean) clean ;;
  all) setup; start; test_lab ;;
  *) echo "Usage: sudo $0 {setup|start|test|stop|clean|all}" >&2; exit 2 ;;
esac
