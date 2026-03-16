#!/bin/bash
set -euo pipefail

# Install CUDA 12.8 toolkit for RTX 2060 SUPER with driver 570.211.01
# Run as root: sudo bash ~/setup/install_cuda_toolkit.sh

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo)"
    exit 1
fi

echo "=== Installing CUDA 12.8 Toolkit ==="

cd /tmp
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt update
apt install -y cuda-toolkit-12-8

echo ""
echo "=== Adding CUDA to PATH for user: ${SUDO_USER:-$USER} ==="
USER_HOME=$(eval echo "~${SUDO_USER:-$USER}")
BASHRC="${USER_HOME}/.bashrc"

if ! grep -q '/usr/local/cuda/bin' "$BASHRC" 2>/dev/null; then
    echo 'export PATH=/usr/local/cuda/bin:$PATH' >> "$BASHRC"
    echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}' >> "$BASHRC"
    echo "Added CUDA to PATH in $BASHRC"
else
    echo "CUDA PATH already configured in $BASHRC"
fi

echo ""
echo "=== Done! ==="
echo "Run 'source ~/.bashrc' then 'nvcc -V' to verify."
