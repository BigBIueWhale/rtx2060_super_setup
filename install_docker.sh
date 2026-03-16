#!/bin/bash
set -euo pipefail

# Install Docker Engine on Ubuntu 24.04 LTS (official Docker docs)
# Run as root: sudo bash ~/setup/install_docker.sh

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo)"
    exit 1
fi

echo "=== Removing conflicting packages (if any) ==="
apt remove -y docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc 2>/dev/null || true

echo "=== Setting up Docker APT repository ==="
apt update
apt install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update

echo "=== Installing Docker Engine ==="
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "=== Adding user '${SUDO_USER:-}' to docker group ==="
if [ -n "${SUDO_USER:-}" ]; then
    usermod -aG docker "$SUDO_USER"
    echo "User '$SUDO_USER' added to docker group (log out and back in to take effect)"
fi

echo ""
echo "=== Done! ==="
echo "Verify with: docker --version"
