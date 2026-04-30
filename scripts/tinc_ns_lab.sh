#!/usr/bin/env bash
set -euo pipefail

# Two-node tinc lab using Linux network namespaces.
# Local-only and reversible: sudo ./scripts/tinc_ns_lab.sh clean

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
UNDERLAY_MTU=${UNDERLAY_MTU:-1500}
TINC_MTU=${TINC_MTU:-1380}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Please run as root: sudo $0 $*" >&2
    exit 1
  fi
}

ns_exists() {
  ip netns list | awk '{print $1}' | grep -qx "$1"
}

ensure_lab() {
  ns_exists "$NS_A" && ns_exists "$NS_B" || { echo "Lab not running. Use: sudo $0 all" >&2; exit 1; }
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
  local node=$1 underlay=$2 vpn=$3 port=$4 peer=$5
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
ip link set \$INTERFACE mtu $TINC_MTU up
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

  write_node a "$UNDERLAY_A" "$VPN_A" "$PORT_A" b
  write_node b "$UNDERLAY_B" "$VPN_B" "$PORT_B" a
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
  ip -n "$NS_A" link set veth-a up mtu "$UNDERLAY_MTU"
  ip -n "$NS_B" link set veth-b up mtu "$UNDERLAY_MTU"
}

start() {
  need_root start
  ensure_lab
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

status_lab() {
  need_root status
  ensure_lab
  echo "== links =="
  ip -n "$NS_A" -br addr
  ip -n "$NS_B" -br addr
  echo "== qdisc =="
  ip netns exec "$NS_A" tc qdisc show dev veth-a
  ip netns exec "$NS_B" tc qdisc show dev veth-b
  echo "== tinc sockets =="
  ip netns exec "$NS_A" ss -lntup 2>/dev/null | grep tinc || true
  ip netns exec "$NS_B" ss -lntup 2>/dev/null | grep tinc || true
}

test_lab() {
  need_root test
  ensure_lab
  echo "== underlay =="
  ip netns exec "$NS_A" ping -c 2 -W 1 "$UNDERLAY_B"
  echo "== vpn ping =="
  ip netns exec "$NS_A" ping -c 5 -W 1 "$VPN_B"
  status_lab
  echo "== logs A =="
  tail -80 "$ROOT/a/log/tinc.log" || true
  echo "== logs B =="
  tail -80 "$ROOT/b/log/tinc.log" || true
}

netem() {
  need_root netem
  ensure_lab
  local delay=${1:-40ms}
  local loss=${2:-0%}
  local rate=${3:-}
  ip netns exec "$NS_A" tc qdisc replace dev veth-a root netem delay "$delay" loss "$loss"
  ip netns exec "$NS_B" tc qdisc replace dev veth-b root netem delay "$delay" loss "$loss"
  if [[ -n "$rate" ]]; then
    ip netns exec "$NS_A" tc qdisc replace dev veth-a root handle 1: netem delay "$delay" loss "$loss"
    ip netns exec "$NS_A" tc qdisc add dev veth-a parent 1: tbf rate "$rate" burst 32kbit latency 400ms
    ip netns exec "$NS_B" tc qdisc replace dev veth-b root handle 1: netem delay "$delay" loss "$loss"
    ip netns exec "$NS_B" tc qdisc add dev veth-b parent 1: tbf rate "$rate" burst 32kbit latency 400ms
  fi
  status_lab
}

reset_netem() {
  need_root reset-netem
  ensure_lab
  ip netns exec "$NS_A" tc qdisc del dev veth-a root 2>/dev/null || true
  ip netns exec "$NS_B" tc qdisc del dev veth-b root 2>/dev/null || true
  status_lab
}

set_underlay_mtu() {
  need_root mtu
  ensure_lab
  local mtu=${1:-1280}
  ip -n "$NS_A" link set veth-a mtu "$mtu"
  ip -n "$NS_B" link set veth-b mtu "$mtu"
  status_lab
}

iperf_lab() {
  need_root iperf
  ensure_lab
  local seconds=${1:-10}
  local proto=${2:-tcp}
  ip netns exec "$NS_B" pkill iperf3 2>/dev/null || true
  ip netns exec "$NS_B" iperf3 -s -1 >"$ROOT/b/log/iperf3.log" 2>&1 &
  local server_pid=$!
  sleep 1
  echo "== iperf3 $proto over tinc: $seconds sec =="
  if [[ "$proto" == "udp" ]]; then
    ip netns exec "$NS_A" iperf3 -c "$VPN_B" -u -b 20M -t "$seconds"
  else
    ip netns exec "$NS_A" iperf3 -c "$VPN_B" -t "$seconds"
  fi
  wait "$server_pid" 2>/dev/null || true
  echo "== server log =="
  cat "$ROOT/b/log/iperf3.log" || true
}

mss_lab() {
  need_root mss
  ensure_lab
  local expected=${1:-$((TINC_MTU - 40))}
  local capture="$ROOT/b/log/mss-tcpdump.log"
  local client="$ROOT/a/log/mss-iperf-client.log"
  local server="$ROOT/b/log/mss-iperf-server.log"

  ip netns exec "$NS_B" pkill iperf3 2>/dev/null || true
  ip netns exec "$NS_B" iperf3 -s -1 >"$server" 2>&1 &
  local server_pid=$!
  sleep 1

  ip netns exec "$NS_B" timeout 6 tcpdump -i tinc-b -nn -vvv -c 2 'tcp[tcpflags] & tcp-syn != 0' >"$capture" 2>&1 &
  local capture_pid=$!
  sleep 1

  ip netns exec "$NS_A" iperf3 -c "$VPN_B" -t 1 >"$client" 2>&1 || true
  wait "$capture_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true

  echo "== captured TCP SYN MSS over tinc =="
  cat "$capture"

  local mss
  mss=$(grep -om1 'mss [0-9]*' "$capture" | awk '{print $2}')
  if [[ -z "$mss" ]]; then
    echo "FAIL: no MSS option captured" >&2
    return 1
  fi

  echo "Observed MSS: $mss"
  echo "Expected MSS <= $expected (TINC_MTU=$TINC_MTU minus IPv4/TCP headers)"
  if (( mss <= expected )); then
    echo "PASS: ClampMSS is active"
  else
    echo "FAIL: MSS is larger than expected" >&2
    return 1
  fi
}

case "${1:-}" in
  setup) setup ;;
  start) start ;;
  stop) stop ;;
  status) status_lab ;;
  test) test_lab ;;
  iperf) shift; iperf_lab "$@" ;;
  mss) shift; mss_lab "$@" ;;
  netem) shift; netem "$@" ;;
  reset-netem) reset_netem ;;
  mtu) shift; set_underlay_mtu "$@" ;;
  clean) clean ;;
  all) setup; start; test_lab ;;
  *) echo "Usage: sudo $0 {setup|start|test|status|iperf [sec] [tcp|udp]|mss [expected]|netem [delay] [loss] [rate]|reset-netem|mtu [bytes]|stop|clean|all}" >&2; exit 2 ;;
esac
