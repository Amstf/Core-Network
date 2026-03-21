#!/bin/bash

# setup_core_container.sh — Master script to download, import, and network-fix a container
# Usage:
#   ./setup_core_container.sh <image-name.tar.gz> [alias] [container-name] [remote-user] [ssh-key-path] [local-repo-path]
#   ./setup_core_container.sh <image-name.tar.gz> [alias] [container-name] [remote-user] [ssh-key-path] --clone

# ─── Parse arguments ────────────────────────────────────────────────────────

IMAGE_NAME="$1"
ALIAS="${2:-${IMAGE_NAME%.tar.gz}}"
CONTAINER="${3:-${ALIAS}-cont}"
REMOTE_USER="${4:-alimustapha}"
SSH_KEY_PATH="$5"
REPO_OR_FLAG="$6"

USE_CLONE=false
LOCAL_REPO_PATH=""

if [ "$REPO_OR_FLAG" = "--clone" ]; then
  USE_CLONE=true
elif [ -n "$REPO_OR_FLAG" ]; then
  LOCAL_REPO_PATH="$REPO_OR_FLAG"
else
  # Default local path if no argument given and no --clone flag
  LOCAL_REPO_PATH="$(cd "$(dirname "$0")/../.." && pwd)"
fi

REPO_URL="git@github.com:Amstf/Core-Network.git"
DEST_PATH="/root/Core-Network"
DOCKER_COMPOSE_FILE="docker-compose-slicing.yaml"

# ─── Validate input ─────────────────────────────────────────────────────────

if [ -z "$IMAGE_NAME" ]; then
  echo "Usage: $0 <image-name.tar.gz> [alias] [container-name] [remote-user] [ssh-key-path] [local-repo-path|--clone]"
  exit 1
fi

if [ "$USE_CLONE" = false ] && [ ! -d "$LOCAL_REPO_PATH" ]; then
  echo "❌ Local repo path not found: $LOCAL_REPO_PATH"
  echo "   Either fix the path, or pass --clone to clone from GitHub instead."
  exit 1
fi

# ─── Display setup summary ───────────────────────────────────────────────────

echo "🧩 Starting setup for:"
echo "  📦 Image:       $IMAGE_NAME"
echo "  🏷️  Alias:       $ALIAS"
echo "  🐧 Container:   $CONTAINER"
echo "  🌐 Remote User: $REMOTE_USER"
echo "  🔐 SSH Key:     ${SSH_KEY_PATH:-None provided}"
if [ "$USE_CLONE" = true ]; then
  echo "  📥 Repo mode:   Clone from GitHub ($REPO_URL)"
else
  echo "  📁 Repo mode:   Copy from local ($LOCAL_REPO_PATH)"
fi
echo ""

# ─── Step 1: Download image ──────────────────────────────────────────────────

echo "▶️  [1/5] Running download_image.sh..."
./download_image.sh "$IMAGE_NAME" "$REMOTE_USER" || {
  echo "❌ Failed to download image."; exit 1;
}

# ─── Step 2: Import & Launch ─────────────────────────────────────────────────

echo "▶️  [2/5] Running import_and_launch.sh..."
./import_and_launch.sh -f "./images/$IMAGE_NAME" -a "$ALIAS" -c "$CONTAINER" || {
  echo "❌ Failed to import/launch container."; exit 1;
}

# ─── Step 2b: Set container privileges for Docker-in-LXC ─────────────────────

echo "▶️  [2b/5] Configuring container privileges..."
lxc stop "$CONTAINER"
lxc config set "$CONTAINER" security.privileged true
lxc config set "$CONTAINER" security.nesting true
lxc config set "$CONTAINER" raw.lxc "lxc.cap.drop ="
lxc start "$CONTAINER"
sleep 5
echo "✅ Container privileges configured."

# ─── Step 3: Fix network ─────────────────────────────────────────────────────

echo "▶️  [3/5] Running set_lxc_network.sh..."
./set_lxc_network.sh "$CONTAINER" || {
  echo "❌ Failed to fix container network."; exit 1;
}

# ─── Step 3b: Lock eth0 to static IP ────────────────────────────────────────

echo "▶️  [3b/5] Locking eth0 to static IP..."
lxc exec "$CONTAINER" -- apt update -y
lxc exec "$CONTAINER" -- apt install -y netplan.io

ETH0_IP=$(lxc exec "$CONTAINER" -- bash -c "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1")
ETH0_GW=$(lxc exec "$CONTAINER" -- bash -c "ip route | grep '^default' | awk '{print \$3}'")

if [ -n "$ETH0_IP" ] && [ -n "$ETH0_GW" ]; then
  echo "  🌐 Found eth0 IP: $ETH0_IP, Gateway: $ETH0_GW"

  NETPLAN_FILE="/etc/netplan/60-static-eth0.yaml"

  lxc exec "$CONTAINER" -- bash -c "cat > $NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    eth0:
      addresses:
        - $ETH0_IP/24
      gateway4: $ETH0_GW
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF

  lxc exec "$CONTAINER" -- netplan apply || {
    echo "⚠️  Failed to apply netplan inside $CONTAINER"; exit 1;
  }
  echo "✅ eth0 is now static at $ETH0_IP"
else
  echo "⚠️  Could not detect DHCP IP for eth0, leaving as DHCP."
fi

# ─── Step 4: Push SSH key ────────────────────────────────────────────────────

if [ -n "$SSH_KEY_PATH" ]; then
  echo "▶️  [4/5] Pushing SSH key to container..."
  lxc exec "$CONTAINER" -- mkdir -p /root/.ssh
  lxc file push "$SSH_KEY_PATH"     "$CONTAINER"/root/.ssh/id_rsa
  lxc file push "$SSH_KEY_PATH.pub" "$CONTAINER"/root/.ssh/id_rsa.pub
  lxc exec "$CONTAINER" -- chmod 600 /root/.ssh/id_rsa
  lxc exec "$CONTAINER" -- chmod 644 /root/.ssh/id_rsa.pub
  lxc exec "$CONTAINER" -- bash -c "ssh-keyscan github.com >> /root/.ssh/known_hosts"

  echo "🧪 Testing SSH connection to GitHub from inside container..."
  lxc exec "$CONTAINER" -- ssh -i /root/.ssh/id_rsa -T git@github.com
  SSH_EXIT=$?

  if [ "$SSH_EXIT" -eq 1 ]; then
    echo "✅ SSH authentication to GitHub succeeded."
  elif [ "$SSH_EXIT" -ne 0 ]; then
    echo "⚠️  SSH test failed. Check key permissions or GitHub settings."
  fi
else
  echo "⚠️  No SSH key path provided. Skipping SSH key setup."
  if [ "$USE_CLONE" = true ]; then
    echo "❌ --clone requires an SSH key. Provide one as argument 5."
    exit 1
  fi
fi

# ─── Step 5: Get the repository ──────────────────────────────────────────────

echo "▶️  [5/5] Setting up Core-Network repository..."

if [ "$USE_CLONE" = true ]; then

  echo "  📥 Cloning from GitHub: $REPO_URL"
  lxc exec "$CONTAINER" -- bash -c "git clone $REPO_URL $DEST_PATH" || {
    echo "❌ Failed to clone repository."; exit 1;
  }
  echo "✅ Repository cloned to $CONTAINER:$DEST_PATH"

else

  echo "  📁 Copying from local: $LOCAL_REPO_PATH"
  lxc file push --recursive "$LOCAL_REPO_PATH" "$CONTAINER"/root/ || {
    echo "❌ Failed to copy Core-Network into container."; exit 1;
  }
  echo "✅ Repository copied to $CONTAINER:$DEST_PATH"

fi

# ─── Step 5b: Pull Docker images ─────────────────────────────────────────────

echo "  🐳 Restarting Docker and pulling images..."
lxc exec "$CONTAINER" -- bash -c "systemctl restart docker || service docker restart"
sleep 3
lxc exec "$CONTAINER" -- bash -c "cd $DEST_PATH/oai-cn5g && docker-compose -f $DOCKER_COMPOSE_FILE pull" || {
  echo "❌ Failed to pull Docker images."; exit 1;
}
echo "✅ Docker images pulled successfully."

# ─── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "🎉 All steps completed successfully for container '$CONTAINER'"
echo "   Container IP : $ETH0_IP"
echo "   Repo location: $DEST_PATH"