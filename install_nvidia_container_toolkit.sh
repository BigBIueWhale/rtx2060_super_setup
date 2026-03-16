#!/bin/bash
set -euo pipefail

# Install NVIDIA Container Toolkit for Docker GPU support
# Run as root: sudo bash ~/setup/install_nvidia_container_toolkit.sh
# Requires: Docker and NVIDIA driver already installed

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo)"
    exit 1
fi

echo "=== Checking prerequisites ==="
if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is not installed. Run install_docker.sh first."
    exit 1
fi
if ! command -v nvidia-smi &>/dev/null; then
    echo "ERROR: NVIDIA driver not installed or nvidia-smi not found."
    exit 1
fi

echo "=== Setting up NVIDIA Container Toolkit APT repository ==="
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update

echo "=== Installing NVIDIA Container Toolkit ==="
apt-get install -y nvidia-container-toolkit

echo "=== Configuring Docker runtime for GPU support ==="
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

echo ""
echo "=== Done! ==="
echo "Test with: docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi"
