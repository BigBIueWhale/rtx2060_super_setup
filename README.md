# AI Server Setup on HP Pavilion Gaming Desktop TG01-1xxx

This document records every step taken to set up an HP Pavilion Gaming Desktop TG01-1xxx (hostname: `rtx2060`) as an AI inference server. The machine has an NVIDIA GeForce RTX 2060 SUPER graphics card with 8 GB of VRAM.

## System Specifications

| Component | Details |
|---|---|
| Machine | HP Pavilion Gaming Desktop TG01-1xxx |
| Hostname | `rtx2060` |
| GPU | NVIDIA GeForce RTX 2060 SUPER (Turing architecture, TU106 chip), 8192 MiB VRAM |
| CPU | 16 cores (x86-64) |
| RAM | 62 GB |
| Storage | 937 GB NVMe SSD (`/dev/nvme0n1p2`) |
| Operating System | Ubuntu Server 24.04.4 LTS (Noble Numbat) |
| Kernel | Linux 6.8.0-106-generic |
| Architecture | x86-64 |

## Context and Decisions

This setup was guided by the instructions in [github.com/BigBIueWhale/personal_server](https://github.com/BigBIueWhale/personal_server), which targets a different machine (NVIDIA GeForce RTX 5090 on Ubuntu Desktop 24.04 LTS). Several adaptations were necessary:

- **NVIDIA driver**: The `personal_server` instructions install `nvidia-driver-580-open` for the RTX 5090. Our system already had `nvidia-headless-no-dkms-570-server-open` (driver version **570.211.01**) pre-installed, which is the correct server-variant driver for the NVIDIA GeForce RTX 2060 SUPER. No driver installation was needed.

- **CUDA Toolkit version**: The `personal_server` instructions install `cuda-toolkit-13-0` (CUDA 13.0), which pairs with driver 580. Our driver 570.211.01 supports up to **CUDA 12.8** (as reported by `nvidia-smi`). We installed `cuda-toolkit-12-8` instead.

- **nvidia-smi utility**: The headless server driver packages (`nvidia-headless-no-dkms-570-server-open`) do not include the `nvidia-smi` monitoring utility. We manually installed the `nvidia-utils-570-server` package to get it.

- **Docker and NVIDIA Container Toolkit**: These steps are identical to the `personal_server` instructions and were followed as-is from the official Docker and NVIDIA documentation.

## Pre-existing State (Before Setup)

The following NVIDIA packages were already installed on the system via Ubuntu's package manager before any setup steps:

- `libnvidia-cfg1-570-server` (570.211.01)
- `libnvidia-compute-570-server` (570.211.01)
- `linux-modules-nvidia-570-server-open-6.8.0-106-generic`
- `linux-modules-nvidia-570-server-open-generic`
- `nvidia-compute-utils-570-server` (570.211.01)
- `nvidia-firmware-570-server-570.211.01`
- `nvidia-headless-no-dkms-570-server-open` (570.211.01)
- `nvidia-kernel-common-570-server` (570.211.01)
- `nvidia-kernel-source-570-server-open` (570.211.01)

The NVIDIA kernel module was loaded and functional (verified via `/proc/driver/nvidia/version`), but `nvidia-smi` was not available and the CUDA Toolkit (`nvcc`) was not installed.

---

## Step 0: Install tmux Terminal Multiplexer

tmux is a terminal multiplexer that keeps shell sessions alive on the server even when the SSH connection drops. This is critical because the following installation steps involve long-running commands (e.g., downloading and installing large packages) that would be killed if the SSH session disconnects.

tmux was already installed (version 3.4) via Ubuntu's default packages.

### tmux Color Fix

By default, tmux can override the terminal's color scheme, making text hard to read. We created `~/.tmux.conf` with the following contents to restore proper 256-color and true-color support:

```
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm*:Tc"
```

After creating this file, tmux was restarted (`tmux kill-server` followed by `tmux`) for the changes to take effect.

### Basic tmux Usage

| Action | Command |
|---|---|
| Start a new session | `tmux` |
| Create a new window | `Ctrl+B` then `C` |
| Switch between windows | `Ctrl+B` then `0`/`1`/`2`... |
| Detach (leave running in background) | `Ctrl+B` then `D` |
| Reattach after SSH reconnect | `tmux attach` |
| List sessions | `tmux ls` |

---

## Step 1: Install nvidia-smi Utility

The `nvidia-smi` command-line utility is used to monitor GPU status (temperature, memory usage, running processes, driver version, supported CUDA version). It was not included in the headless server driver packages.

```bash
sudo apt install nvidia-utils-570-server
```

### Verification

```bash
nvidia-smi
```

Expected output includes:

```
NVIDIA-SMI 570.211.01    Driver Version: 570.211.01    CUDA Version: 12.8
NVIDIA GeForce RTX 2060 SUPER    8192MiB
```

The "CUDA Version: 12.8" field in the `nvidia-smi` output indicates the maximum CUDA Toolkit version supported by this driver. This is what determined that we should install `cuda-toolkit-12-8` and not `cuda-toolkit-13-0`.

---

## Step 2: Install NVIDIA CUDA Toolkit 12.8

The NVIDIA CUDA Toolkit provides the CUDA compiler (`nvcc`), CUDA runtime libraries, and development headers needed for GPU-accelerated applications and AI inference frameworks.

**Script:** `~/setup/install_cuda_toolkit.sh`

```bash
sudo bash ~/setup/install_cuda_toolkit.sh
```

### What the script does

1. Downloads the NVIDIA CUDA repository keyring package (`cuda-keyring_1.1-1_all.deb`) from `https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/`
2. Registers the NVIDIA CUDA APT repository on the system
3. Installs the `cuda-toolkit-12-8` package
4. Appends CUDA binary and library paths to `~/.bashrc`:
   - `export PATH=/usr/local/cuda/bin:$PATH`
   - `export LD_LIBRARY_PATH=/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}`

### Verification

```bash
source ~/.bashrc
nvcc -V
```

Expected output:

```
Cuda compilation tools, release 12.8, V12.8.93
```

---

## Step 3: Install Docker Engine

Docker Engine is the container runtime used to run AI applications (such as Open WebUI) in isolated containers with GPU access.

The installation follows the official Docker documentation at `https://docs.docker.com/engine/install/ubuntu/`.

**Script:** `~/setup/install_docker.sh`

```bash
sudo bash ~/setup/install_docker.sh
```

### What the script does

1. Removes any conflicting pre-existing Docker-related packages (`docker.io`, `docker-compose`, `podman-docker`, `containerd`, `runc`)
2. Adds Docker's official GPG signing key from `https://download.docker.com/linux/ubuntu/gpg` to `/etc/apt/keyrings/docker.asc`
3. Adds the Docker APT repository for Ubuntu 24.04 (Noble Numbat) to `/etc/apt/sources.list.d/docker.sources`
4. Installs the following packages:
   - `docker-ce` (Docker Community Edition daemon)
   - `docker-ce-cli` (Docker command-line interface)
   - `containerd.io` (container runtime)
   - `docker-buildx-plugin` (extended build capabilities)
   - `docker-compose-plugin` (multi-container orchestration)
5. Adds the invoking user (via `$SUDO_USER`) to the `docker` Unix group so that `docker` commands can be run without `sudo`

### Post-installation: Activating Docker Group Membership

After the script completes, the user's `docker` group membership does not take effect until the session is refreshed. Instead of logging out and back in, run:

```bash
newgrp docker
```

### Verification

```bash
docker --version
```

---

## Step 4: Install NVIDIA Container Toolkit

The NVIDIA Container Toolkit enables Docker containers to access the host's NVIDIA GPU. Without it, the `--gpus` flag in `docker run` does not work.

**Script:** `~/setup/install_nvidia_container_toolkit.sh`

```bash
sudo bash ~/setup/install_nvidia_container_toolkit.sh
```

### What the script does

1. Verifies that both Docker Engine and `nvidia-smi` are available (exits with an error if either is missing)
2. Adds the NVIDIA Container Toolkit GPG signing key from `https://nvidia.github.io/libnvidia-container/gpgkey` to `/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg`
3. Adds the NVIDIA Container Toolkit APT repository to `/etc/apt/sources.list.d/nvidia-container-toolkit.list`
4. Installs the `nvidia-container-toolkit` package
5. Runs `nvidia-ctk runtime configure --runtime=docker` to register the NVIDIA runtime with Docker (modifies `/etc/docker/daemon.json`)
6. Restarts the Docker daemon (`systemctl restart docker`) to apply the configuration

### Verification

```bash
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi
```

Expected output: the same `nvidia-smi` GPU table as on the host, but running from inside a Docker container. This confirms that the NVIDIA GeForce RTX 2060 SUPER is accessible to containerized applications.

```
NVIDIA-SMI 570.211.01    Driver Version: 570.211.01    CUDA Version: 12.8
NVIDIA GeForce RTX 2060 SUPER    8192MiB
```

---

## Final State After Setup

| Component | Version / Status |
|---|---|
| NVIDIA Driver | 570.211.01 (server, open kernel module) |
| CUDA Toolkit | 12.8 (V12.8.93) |
| Docker Engine | Community Edition (from official Docker APT repository) |
| NVIDIA Container Toolkit | Installed from `nvidia.github.io` APT repository |
| GPU in Docker | Verified working via `docker run --gpus all` |

## What Comes Next

The following steps from the `personal_server` repository have not yet been completed:

- **Ollama** — Local large language model inference server (section 10 of `personal_server/README.md`)
- **Open WebUI** — Web-based chat frontend for Ollama (section 9 of `personal_server/README.md`)
