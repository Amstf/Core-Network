#!/bin/bash

# setup_container.sh — Master script to download, import, and network-fix a container
# Usage: ./setup_container.sh <image-name.tar.gz> [alias] [container-name] [remote-user] [ssh-key-path]

IMAGE_NAME="$1"
ALIAS="${2:-${IMAGE_NAME%.tar.gz}}"
CONTAINER="${3:-${ALIAS}-cont}"
REMOTE_USER="${4:-alimustapha}"
SSH_KEY_PATH="$5"

if [ -z "$IMAGE_NAME" ]; then
  echo "Usage: $0 <image-name.tar.gz> [alias] [container-name] [remote-user] [ssh-key-path]"
  exit 1
fi

# Display setup summary
echo "🧩 Starting setup for:"
echo "  📦 Image:      $IMAGE_NAME"
echo "  🏷️  Alias:      $ALIAS"
echo "  🐧 Container:  $CONTAINER"
echo "  🌐 Remote User: $REMOTE_USER"
echo "  🔐 SSH Key:    ${SSH_KEY_PATH:-None provided}"
echo ""

# Step 1: Download image if needed
echo "▶️  [1/4] Running download_image.sh..."
./download_image.sh "$IMAGE_NAME" "$REMOTE_USER" || {
  echo "❌ Failed to download image."; exit 1;
}

# Step 2: Import & Launch
echo "▶️  [2/4] Running import_and_launch.sh..."
./import_and_launch.sh -f "./images/$IMAGE_NAME" -a "$ALIAS" -c "$CONTAINER" || {
  echo "❌ Failed to import/launch container."; exit 1;
}

# Step 3: Fix network
echo "▶️  [3/4] Running set_lxc_network.sh..."
./set_lxc_network.sh "$CONTAINER" || {
  echo "❌ Failed to fix container network."; exit 1;
}
# Step 3b: Lock eth0 IP to static after first DHCP lease
echo "▶️  [3b/4] Locking eth0 to static IP..."
lxc exec "$CONTAINER" -- apt update -y
lxc exec "$CONTAINER" -- apt install -y netplan.io

# Grab the current DHCP address on eth0
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
        addresses: [8.8.8.8,1.1.1.1]
EOF

  lxc exec "$CONTAINER" -- netplan apply || {
    echo "⚠️ Failed to apply netplan inside $CONTAINER"; exit 1;
  }

  echo "✅ eth0 is now static at $ETH0_IP"
else
  echo "❌ Could not detect DHCP IP for eth0, leaving as DHCP."
fi


# Step 4: Push SSH key and test SSH access
if [ -n "$SSH_KEY_PATH" ]; then
  echo "🔑 Pushing SSH key to container..."
  BASENAME=$(basename "$SSH_KEY_PATH")
  lxc exec "$CONTAINER" -- mkdir -p /root/.ssh
  lxc file push "$SSH_KEY_PATH" "$CONTAINER"/root/.ssh/id_rsa
  lxc file push "$SSH_KEY_PATH.pub" "$CONTAINER"/root/.ssh/id_rsa.pub
  lxc exec "$CONTAINER" -- chmod 600 /root/.ssh/id_rsa
  lxc exec "$CONTAINER" -- chmod 644 /root/.ssh/id_rsa.pub
  lxc exec "$CONTAINER" -- bash -c "ssh-keyscan github.com >> /root/.ssh/known_hosts"

  echo "🧪 Testing SSH connection to GitHub from inside container..."
  lxc exec "$CONTAINER" -- ssh -i /root/.ssh/id_rsa -T git@github.com
  SSH_EXIT=$?

  if [ "$SSH_EXIT" -eq 1 ]; then
    echo "✅ SSH authentication to GitHub succeeded (GitHub does not provide shell access)."
  elif [ "$SSH_EXIT" -ne 0 ]; then
    echo "⚠️  SSH test failed. Please check your key permissions or GitHub settings."
  fi
else
  echo "⚠️  No SSH key path provided. Skipping SSH key setup."
fi

echo "✅ All steps completed successfully for container '$CONTAINER'"

# Step 5: Clone repo and pull Docker images

REPO_URL="git@github.com:Amstf/OAI-CORE-Network.git"
REPO_DIR="OAI-CORE-Network/oai-cn5g-legacy"
DOCKER_COMPOSE_FILE="docker-compose-legacy.yml"

echo "▶️  [4/4] Cloning repository and pulling Docker images..."
lxc exec "$CONTAINER" -- bash -c "git clone $REPO_URL"
lxc exec "$CONTAINER" -- bash -c "systemctl restart docker || service docker restart"
lxc exec "$CONTAINER" -- bash -c "cd $REPO_DIR && docker-compose -f $DOCKER_COMPOSE_FILE pull"


echo "✅ All steps completed successfully for container '$CONTAINER'"
