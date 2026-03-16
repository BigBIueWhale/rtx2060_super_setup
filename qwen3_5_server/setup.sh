#!/bin/bash
set -euo pipefail

# ============================================================
# Qwen 3.5 9B — llama.cpp Server Setup
#
# Idempotent setup script. Safe to run multiple times:
#   - Detects existing llama.cpp clone and rebuilds only if
#     the pinned tag has changed
#   - Skips GGUF download if the correct file already exists
#   - Re-downloads if the file size doesn't match expectations
#   - Always regenerates the systemd service file (cheap)
#   - Stops the service before changes and restarts after
#
# Run as your regular user (NOT root):
#   bash ~/rtx2060_super_setup/qwen3_5_server/setup.sh
# ============================================================

# ----- Pinned versions and constants -----

LLAMA_CPP_TAG="b8377"
LLAMA_CPP_REPO="https://github.com/ggml-org/llama.cpp.git"

GGUF_FILENAME="Qwen3.5-9B-UD-Q4_K_XL.gguf"
GGUF_URL="https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/${GGUF_FILENAME}"
GGUF_EXPECTED_SIZE_MIN_BYTES=5900000000   # 5.9 GB lower bound
GGUF_EXPECTED_SIZE_MAX_BYTES=6100000000   # 6.1 GB upper bound

CUDA_ARCH="75"  # Compute capability 7.5 = Turing (RTX 2060 SUPER)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}"
LLAMA_DIR="${PROJECT_DIR}/llama.cpp"
MODEL_DIR="${PROJECT_DIR}/models"
LLAMA_SERVER_BIN="${LLAMA_DIR}/build/bin/llama-server"
MODEL_PATH="${MODEL_DIR}/${GGUF_FILENAME}"

SERVICE_NAME="llama-server"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="${SERVICE_DIR}/${SERVICE_NAME}.service"

HOST="127.0.0.1"
PORT="8080"
CTX_SIZE="55296"
KV_CACHE_TYPE="f16"

# ----- Colors -----

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ----- Helpers -----

assert_true() {
    local description="$1"
    local condition="$2"
    if eval "$condition"; then
        echo -e "  ${GREEN}PASS${NC}: $description"
    else
        echo -e "  ${RED}FAIL${NC}: $description"
        echo -e "  ${RED}FATAL: Aborting setup.${NC}"
        exit 1
    fi
}

assert_command_exists() {
    assert_true "Command available: $1" "command -v '$1' &>/dev/null"
}

assert_file_exists() {
    assert_true "File exists: $1" "[ -f '$1' ]"
}

info() {
    echo -e "  ${YELLOW}INFO${NC}: $1"
}

# ============================================================
echo -e "\n${CYAN}=== 1. Validate Prerequisites ===${NC}"
# ============================================================

assert_true "Running as regular user (NOT root)" "[ '$(id -u)' -ne 0 ]"

assert_command_exists "git"
assert_command_exists "cmake"
assert_command_exists "make"
assert_command_exists "wget"
assert_command_exists "curl"
assert_command_exists "nvidia-smi"
assert_command_exists "nvcc"

# cmake version
CMAKE_VERSION=$(cmake --version | head -1 | grep -oP '[\d.]+')
CMAKE_MAJOR=$(echo "$CMAKE_VERSION" | cut -d. -f1)
CMAKE_MINOR=$(echo "$CMAKE_VERSION" | cut -d. -f2)
assert_true "cmake version >= 3.14 (got: ${CMAKE_VERSION})" \
    "[ '$CMAKE_MAJOR' -gt 3 ] || ( [ '$CMAKE_MAJOR' -eq 3 ] && [ '$CMAKE_MINOR' -ge 14 ] )"

# CUDA toolkit
NVCC_VERSION=$(nvcc -V 2>/dev/null | grep 'release' | grep -oP '[\d.]+' | head -1)
assert_true "CUDA toolkit installed (nvcc version: ${NVCC_VERSION})" "[ -n '${NVCC_VERSION}' ]"

# GPU
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
assert_true "NVIDIA GPU detected: ${GPU_NAME}" "[ -n '${GPU_NAME}' ]"

GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
assert_true "GPU VRAM >= 7000 MB (got: ${GPU_VRAM_MB} MB)" "[ '${GPU_VRAM_MB}' -ge 7000 ]"

# Disk space (need ~12 GB: 6 GB GGUF + 5 GB build + 1 GB margin)
AVAILABLE_KB=$(df --output=avail "$HOME" | tail -1 | tr -d ' ')
AVAILABLE_GB=$((AVAILABLE_KB / 1024 / 1024))
assert_true "Disk space >= 12 GB available (got: ${AVAILABLE_GB} GB)" "[ '${AVAILABLE_GB}' -ge 12 ]"

# Lingering (required for user service to start at boot)
LINGER=$(loginctl show-user "$(whoami)" --property=Linger 2>/dev/null | cut -d= -f2 || echo "unknown")
assert_true "Systemd user lingering is enabled (got: ${LINGER})" "[ '${LINGER}' = 'yes' ]"

# ============================================================
echo -e "\n${CYAN}=== 2. Stop Existing Service (if running) ===${NC}"
# ============================================================

if systemctl --user is-active "${SERVICE_NAME}" &>/dev/null; then
    info "Stopping existing ${SERVICE_NAME} service..."
    systemctl --user stop "${SERVICE_NAME}"
    info "Service stopped."
else
    info "No existing ${SERVICE_NAME} service running."
fi

# ============================================================
echo -e "\n${CYAN}=== 3. Clone or Update llama.cpp at tag ${LLAMA_CPP_TAG} ===${NC}"
# ============================================================

NEED_BUILD=false

if [ -d "${LLAMA_DIR}/.git" ]; then
    cd "${LLAMA_DIR}"
    CURRENT_TAG=$(git describe --tags --exact-match HEAD 2>/dev/null || echo "unknown")

    if [ "${CURRENT_TAG}" = "${LLAMA_CPP_TAG}" ]; then
        info "llama.cpp already at tag ${LLAMA_CPP_TAG}. Skipping clone."
    else
        info "llama.cpp is at tag ${CURRENT_TAG}, expected ${LLAMA_CPP_TAG}."
        info "Removing stale llama.cpp clone..."
        cd "${PROJECT_DIR}"
        rm -rf "${LLAMA_DIR}"
        NEED_BUILD=true
    fi
elif [ -d "${LLAMA_DIR}" ]; then
    info "llama.cpp directory exists but is not a git repo. Removing..."
    rm -rf "${LLAMA_DIR}"
    NEED_BUILD=true
fi

if [ ! -d "${LLAMA_DIR}" ]; then
    info "Cloning llama.cpp at tag ${LLAMA_CPP_TAG}..."
    git clone --depth=1 --branch "${LLAMA_CPP_TAG}" "${LLAMA_CPP_REPO}" "${LLAMA_DIR}"
    NEED_BUILD=true
fi

cd "${LLAMA_DIR}"
CLONED_TAG=$(git describe --tags --exact-match HEAD 2>/dev/null || echo "unknown")
assert_true "llama.cpp is at tag ${LLAMA_CPP_TAG} (got: ${CLONED_TAG})" \
    "[ '${CLONED_TAG}' = '${LLAMA_CPP_TAG}' ]"

# Validate Qwen 3.5 architecture support
assert_file_exists "${LLAMA_DIR}/src/models/qwen35.cpp"

# Validate the enable_thinking fix is present
assert_true "enable_thinking fix present (common_chat_template_direct_apply in chat.cpp)" \
    "grep -q 'common_chat_template_direct_apply' '${LLAMA_DIR}/common/chat.cpp'"

# ============================================================
echo -e "\n${CYAN}=== 4. Build llama.cpp with CUDA (compute capability ${CUDA_ARCH}) ===${NC}"
# ============================================================

if [ "${NEED_BUILD}" = true ] || [ ! -f "${LLAMA_SERVER_BIN}" ]; then
    if [ -d "${LLAMA_DIR}/build" ] && [ "${NEED_BUILD}" = true ]; then
        info "Removing stale build directory..."
        rm -rf "${LLAMA_DIR}/build"
    fi

    info "Configuring cmake..."
    cmake -B "${LLAMA_DIR}/build" \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
        -DCMAKE_BUILD_TYPE=Release \
        -S "${LLAMA_DIR}"

    info "Building with $(nproc) threads (this may take several minutes)..."
    cmake --build "${LLAMA_DIR}/build" --config Release -j "$(nproc)"
else
    info "llama-server binary already exists. Skipping build."
fi

assert_file_exists "${LLAMA_SERVER_BIN}"
assert_true "llama-server is executable" "[ -x '${LLAMA_SERVER_BIN}' ]"

# Validate the binary runs
LLAMA_VERSION=$("${LLAMA_SERVER_BIN}" --version 2>/dev/null || echo "unknown")
assert_true "llama-server runs successfully (version: ${LLAMA_VERSION})" \
    "[ '${LLAMA_VERSION}' != 'unknown' ]"

# ============================================================
echo -e "\n${CYAN}=== 5. Download GGUF Model ===${NC}"
# ============================================================

mkdir -p "${MODEL_DIR}"

NEED_DOWNLOAD=false

if [ -f "${MODEL_PATH}" ]; then
    GGUF_ACTUAL_SIZE=$(stat -c%s "${MODEL_PATH}")
    if [ "${GGUF_ACTUAL_SIZE}" -ge "${GGUF_EXPECTED_SIZE_MIN_BYTES}" ] && \
       [ "${GGUF_ACTUAL_SIZE}" -le "${GGUF_EXPECTED_SIZE_MAX_BYTES}" ]; then
        # Check GGUF magic number
        GGUF_MAGIC=$(head -c4 "${MODEL_PATH}" | cat -v)
        if [ "${GGUF_MAGIC}" = "GGUF" ]; then
            info "GGUF already downloaded and valid ($(numfmt --to=iec-i --suffix=B "${GGUF_ACTUAL_SIZE}")). Skipping download."
        else
            info "GGUF file exists but has invalid magic number. Re-downloading..."
            rm -f "${MODEL_PATH}"
            NEED_DOWNLOAD=true
        fi
    else
        info "GGUF file exists but size is wrong (got: ${GGUF_ACTUAL_SIZE} bytes). Re-downloading..."
        rm -f "${MODEL_PATH}"
        NEED_DOWNLOAD=true
    fi
else
    NEED_DOWNLOAD=true
fi

if [ "${NEED_DOWNLOAD}" = true ]; then
    # Remove any partial downloads
    rm -f "${MODEL_PATH}.tmp"

    info "Downloading ${GGUF_FILENAME} (5.97 GB)..."
    info "URL: ${GGUF_URL}"
    wget --progress=bar:force:noscroll -O "${MODEL_PATH}.tmp" "${GGUF_URL}"

    # Validate before moving into place
    TMP_SIZE=$(stat -c%s "${MODEL_PATH}.tmp")
    assert_true "Downloaded file size in expected range (got: ${TMP_SIZE} bytes)" \
        "[ '${TMP_SIZE}' -ge '${GGUF_EXPECTED_SIZE_MIN_BYTES}' ] && [ '${TMP_SIZE}' -le '${GGUF_EXPECTED_SIZE_MAX_BYTES}' ]"

    TMP_MAGIC=$(head -c4 "${MODEL_PATH}.tmp" | cat -v)
    assert_true "Downloaded file has valid GGUF magic number" \
        "[ '${TMP_MAGIC}' = 'GGUF' ]"

    mv "${MODEL_PATH}.tmp" "${MODEL_PATH}"
    info "Download complete."
fi

assert_file_exists "${MODEL_PATH}"

# Final validation of the model file
GGUF_ACTUAL_SIZE=$(stat -c%s "${MODEL_PATH}")
assert_true "GGUF file size in expected range (got: ${GGUF_ACTUAL_SIZE} bytes)" \
    "[ '${GGUF_ACTUAL_SIZE}' -ge '${GGUF_EXPECTED_SIZE_MIN_BYTES}' ] && [ '${GGUF_ACTUAL_SIZE}' -le '${GGUF_EXPECTED_SIZE_MAX_BYTES}' ]"

GGUF_MAGIC=$(head -c4 "${MODEL_PATH}" | cat -v)
assert_true "GGUF magic number is valid" "[ '${GGUF_MAGIC}' = 'GGUF' ]"

# ============================================================
echo -e "\n${CYAN}=== 6. Create Systemd User Service ===${NC}"
# ============================================================

mkdir -p "${SERVICE_DIR}"

cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Qwen 3.5 9B llama.cpp Inference Server
Documentation=https://github.com/ggml-org/llama.cpp
After=network.target

[Service]
Type=simple
ExecStart=${LLAMA_SERVER_BIN} \\
  --model          ${MODEL_PATH} \\
  --host           ${HOST} \\
  --port           ${PORT} \\
  --ctx-size       ${CTX_SIZE} \\
  --flash-attn     on \\
  --cache-type-k   ${KV_CACHE_TYPE} \\
  --cache-type-v   ${KV_CACHE_TYPE} \\
  --gpu-layers     999 \\
  --jinja \\
  --reasoning-format deepseek \\
  --reasoning-budget -1 \\
  --temp           0.6 \\
  --top-k          20 \\
  --top-p          0.95 \\
  --min-p          0.0 \\
  --repeat-penalty 1.0 \\
  --predict        -1 \\
  --metrics \\
  --no-webui \\
  --log-timestamps

Restart=on-failure
RestartSec=5
Environment=CUDA_VISIBLE_DEVICES=0

[Install]
WantedBy=default.target
EOF

assert_file_exists "${SERVICE_FILE}"
info "Service file written to ${SERVICE_FILE}"

# ============================================================
echo -e "\n${CYAN}=== 7. Enable and Start Service ===${NC}"
# ============================================================

systemctl --user daemon-reload

systemctl --user enable "${SERVICE_NAME}"
assert_true "Service enabled" "systemctl --user is-enabled ${SERVICE_NAME} | grep -q enabled"

systemctl --user start "${SERVICE_NAME}"

info "Waiting for llama-server to initialize (loading model into VRAM)..."

READY=false
for i in $(seq 1 120); do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST}:${PORT}/health" 2>/dev/null || echo "000")
    if [ "${HTTP_CODE}" = "200" ]; then
        READY=true
        break
    fi
    sleep 1
done

assert_true "Server responding on http://${HOST}:${PORT}/health (waited ${i}s)" \
    "[ '${READY}' = 'true' ]"

# Ensure it didn't crash right after first response
sleep 2
assert_true "Service is still active after 2s" \
    "systemctl --user is-active ${SERVICE_NAME} | grep -q active"

# ============================================================
echo -e "\n${CYAN}=== 8. Health Check ===${NC}"
# ============================================================

HEALTH=$(curl -s "http://${HOST}:${PORT}/health")
echo "  /health: ${HEALTH}"
assert_true "Health endpoint returns status" "echo '${HEALTH}' | grep -q 'status'"

MODELS=$(curl -s "http://${HOST}:${PORT}/v1/models")
echo "  /v1/models: ${MODELS}"
assert_true "Models endpoint returns data" "echo '${MODELS}' | grep -q 'data'"

# ============================================================
echo -e "\n${CYAN}=== Setup Complete ===${NC}"
# ============================================================

echo ""
echo "  llama.cpp tag:      ${LLAMA_CPP_TAG}"
echo "  llama-server:       ${LLAMA_VERSION}"
echo "  Model:              ${GGUF_FILENAME} ($(numfmt --to=iec-i --suffix=B "${GGUF_ACTUAL_SIZE}"))"
echo "  Context size:       ${CTX_SIZE} tokens"
echo "  KV cache type:      ${KV_CACHE_TYPE}"
echo "  API endpoint:       http://${HOST}:${PORT}/v1/chat/completions"
echo "  Service:            systemctl --user status ${SERVICE_NAME}"
echo "  Logs:               journalctl --user -u ${SERVICE_NAME} -f"
echo ""
echo -e "  ${GREEN}Ready for agentic coding flows.${NC}"
