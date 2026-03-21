#!/bin/bash
# Helper to (re)start the legacy slicing core network using develop images.
# Usage: ./start_cn.sh -m rfsim   (uses eth0)
#        ./start_cn.sh -m usrp    (uses tun0)

set -euo pipefail

# Parse -m flag
MODE=""
while getopts "m:" opt; do
  case $opt in
    m) MODE="$OPTARG" ;;
    *) echo "Usage: $0 -m [rfsim|usrp]"; exit 1 ;;
  esac
done

if [[ "$MODE" != "rfsim" && "$MODE" != "usrp" ]]; then
  echo "Error: -m must be 'rfsim' or 'usrp'"
  echo "Usage: $0 -m [rfsim|usrp]"
  exit 1
fi

# Set interface based on mode
if [[ "$MODE" == "usrp" ]]; then
  IFACE="tun0"
else
  IFACE="eth0"
fi

echo "[slicing] Mode: $MODE — using interface: $IFACE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "[slicing] Recreating demo-oai-public-net network"
docker network rm demo-oai-public-net >/dev/null 2>&1 || true
docker network create \
  --driver=bridge \
  --subnet=192.168.70.128/26 \
  --gateway=192.168.70.129 \
  demo-oai-public-net >/dev/null 2>&1

COMPOSE_FILE="docker-compose-slicing.yaml"

echo "[slicing] Bringing down previous deployment (if any)"
docker-compose -f "${COMPOSE_FILE}" down

echo "[slicing] Starting slicing core services"
docker-compose -f "${COMPOSE_FILE}" up -d

echo "[slicing] Configuring UPF tunnel gateways on $IFACE"
sleep 5
docker exec -i oai-upf-slice1 ip addr add 12.1.1.1/24 dev "$IFACE" >/dev/null 2>&1 || true
docker exec -i oai-upf-slice1 ip link set "$IFACE" up >/dev/null 2>&1

docker exec -i oai-upf-slice2 ip addr add 12.1.2.1/24 dev "$IFACE" >/dev/null 2>&1 || true
docker exec -i oai-upf-slice2 ip link set "$IFACE" up >/dev/null 2>&1

echo "[slicing] Core network ready"

