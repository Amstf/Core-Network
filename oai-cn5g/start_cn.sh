#!/bin/bash
# Helper to (re)start the legacy slicing core network using develop images.
# This preserves the legacy addressing model so an existing gNB configuration
# can connect without changes.

set -euo pipefail

# Always run relative operations (compose file, configs) from the script's folder
# so the helper behaves correctly no matter where it is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "[slicing] Recreating demo-oai-public-net network"
docker network rm demo-oai-public-net >/dev/null 2>&1 || true
docker network create \
  --driver=bridge \
  --subnet=192.168.70.128/26 \
  --gateway=192.168.70.129 \
  demo-oai-public-net >/dev/null 2>&1

COMPOSE_FILE="docker-compose-legacy-slicing.yaml"

echo "[slicing] Bringing down previous deployment (if any)"
docker-compose -f "${COMPOSE_FILE}" down

echo "[slicing] Starting slicing core services"
docker-compose -f "${COMPOSE_FILE}" up -d

echo "[slicing] Configuring UPF tunnel gateways"
sleep 5
docker exec -i oai-upf-slice1 ip addr add 12.1.1.1/24 dev eth0 >/dev/null 2>&1 || true
docker exec -i oai-upf-slice1 ip link set eth0 up >/dev/null 2>&1

docker exec -i oai-upf-slice2 ip addr add 12.1.2.1/24 dev eth0 >/dev/null 2>&1 || true
docker exec -i oai-upf-slice2 ip link set eth0 up >/dev/null 2>&1

echo "[slicing] Core network ready"
