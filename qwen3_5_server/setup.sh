#!/bin/bash
set -euo pipefail

# ============================================================
# Qwen 3.5 9B — llama.cpp Server Setup
# Installs llama.cpp (pinned), downloads the GGUF model,
# and creates a systemd user service.
#
# Run as your regular user (NOT root):
#   bash ~/qwen3_5_server/setup.sh
# ============================================================

# ----- Pinned versions and constants -----

LLAMA_CPP_TAG="b8377"
LLAMA_CPP_REPO="https://github.com/ggml-org/llama.cpp.git"

GGUF_FILENAME="Qwen3.5-9B-UD-Q4_K_XL.gguf"
GGUF_URL="https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/${GGUF_FILENAME}"
GGUF_EXPECTED_SIZE_MIN_BYTES=5900000000   # 5.9 GB lower bound
GGUF_EXPECTED_SIZE_MAX_BYTES=6100000000   # 6.1 GB upper bound

CUDA_ARCH="75"  # Compute capability 7.5 = Turing (RTX 2060 SUPER)

PROJECT_DIR="$HOME/qwen3_5_server"
LLAMA_DIR="${PROJECT_DIR}/llama.cpp"
MODEL_DIR="${PROJECT_DIR}/models"
LLAMA_SERVER_BIN="${LLAMA_DIR}/build/bin/llama-server"
MODEL_PATH="${MODEL_DIR}/${GGUF_FILENAME}"

SERVICE_NAME="llama-server"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="${SERVICE_DIR}/${SERVICE_NAME}.service"

HOST="127.0.0.1"
PORT="8080"
CTX_SIZE="49152"
KV_CACHE_TYPE="q8_0"

# ----- Colors -----

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# ----- Assertion helpers -----

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

assert_dir_exists() {
    assert_true "Directory exists: $1" "[ -d '$1' ]"
}

# ============================================================
echo -e "\n${CYAN}=== 1. Validate Prerequisites ===${NC}"
# ============================================================

assert_true "Running as regular user (NOT root)" "[ '$(id -u)' -ne 0 ]"

assert_command_exists "git"
assert_command_exists "cmake"
assert_command_exists "make"
assert_command_exists "wget"
assert_command_exists "nvidia-smi"
assert_command_exists "nvcc"

# Validate cmake version >= 3.14
CMAKE_VERSION=$(cmake --version | head -1 | grep -oP '[\d.]+')
CMAKE_MAJOR=$(echo "$CMAKE_VERSION" | cut -d. -f1)
CMAKE_MINOR=$(echo "$CMAKE_VERSION" | cut -d. -f2)
assert_true "cmake version >= 3.14 (got: ${CMAKE_VERSION})" \
    "[ '$CMAKE_MAJOR' -gt 3 ] || ( [ '$CMAKE_MAJOR' -eq 3 ] && [ '$CMAKE_MINOR' -ge 14 ] )"

# Validate CUDA toolkit
NVCC_VERSION=$(nvcc -V 2>/dev/null | grep 'release' | grep -oP '[\d.]+' | head -1)
assert_true "CUDA toolkit is installed (nvcc version: ${NVCC_VERSION})" "[ -n '${NVCC_VERSION}' ]"

# Validate GPU
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
assert_true "NVIDIA GPU detected: ${GPU_NAME}" "[ -n '${GPU_NAME}' ]"

GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
assert_true "GPU VRAM >= 7000 MB (got: ${GPU_VRAM_MB} MB)" "[ '${GPU_VRAM_MB}' -ge 7000 ]"

# Validate disk space (need ~12 GB: 6 GB GGUF + 5 GB build + 1 GB margin)
AVAILABLE_KB=$(df --output=avail "$HOME" | tail -1 | tr -d ' ')
AVAILABLE_GB=$((AVAILABLE_KB / 1024 / 1024))
assert_true "Disk space >= 12 GB available (got: ${AVAILABLE_GB} GB)" "[ '${AVAILABLE_GB}' -ge 12 ]"

# Validate project directory exists
assert_dir_exists "${PROJECT_DIR}"

# ============================================================
echo -e "\n${CYAN}=== 2. Clone llama.cpp at tag ${LLAMA_CPP_TAG} ===${NC}"
# ============================================================

if [ -d "${LLAMA_DIR}" ]; then
    echo "  llama.cpp directory already exists at ${LLAMA_DIR}"
    cd "${LLAMA_DIR}"
    CURRENT_TAG=$(git describe --tags --exact-match HEAD 2>/dev/null || echo "unknown")
    assert_true "Existing clone is at tag ${LLAMA_CPP_TAG} (got: ${CURRENT_TAG})" \
        "[ '${CURRENT_TAG}' = '${LLAMA_CPP_TAG}' ]"
else
    echo "  Cloning llama.cpp..."
    git clone --depth=1 --branch "${LLAMA_CPP_TAG}" "${LLAMA_CPP_REPO}" "${LLAMA_DIR}"
    cd "${LLAMA_DIR}"
    CLONED_TAG=$(git describe --tags --exact-match HEAD 2>/dev/null || echo "unknown")
    assert_true "Cloned at tag ${LLAMA_CPP_TAG} (got: ${CLONED_TAG})" \
        "[ '${CLONED_TAG}' = '${LLAMA_CPP_TAG}' ]"
fi

# Validate Qwen 3.5 architecture support exists in this version
assert_file_exists "${LLAMA_DIR}/src/models/qwen35.cpp"

# Validate the enable_thinking fix is present (common_chat_template_direct_apply function)
assert_true "enable_thinking fix present (common_chat_template_direct_apply in chat.cpp)" \
    "grep -q 'common_chat_template_direct_apply' '${LLAMA_DIR}/common/chat.cpp'"

# ============================================================
echo -e "\n${CYAN}=== 3. Build llama.cpp with CUDA (compute capability ${CUDA_ARCH}) ===${NC}"
# ============================================================

if [ -f "${LLAMA_SERVER_BIN}" ]; then
    echo "  llama-server binary already exists at ${LLAMA_SERVER_BIN}"
    assert_true "llama-server is executable" "[ -x '${LLAMA_SERVER_BIN}' ]"
else
    echo "  Configuring cmake..."
    cmake -B "${LLAMA_DIR}/build" \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
        -DCMAKE_BUILD_TYPE=Release \
        -S "${LLAMA_DIR}"

    echo "  Building (this may take several minutes)..."
    cmake --build "${LLAMA_DIR}/build" --config Release -j "$(nproc)"

    assert_file_exists "${LLAMA_SERVER_BIN}"
    assert_true "llama-server is executable" "[ -x '${LLAMA_SERVER_BIN}' ]"
fi

# Validate the binary runs
LLAMA_VERSION=$("${LLAMA_SERVER_BIN}" --version 2>/dev/null || echo "unknown")
echo "  llama-server version: ${LLAMA_VERSION}"
assert_true "llama-server binary runs successfully" "[ '${LLAMA_VERSION}' != 'unknown' ]"

# ============================================================
echo -e "\n${CYAN}=== 4. Download GGUF Model ===${NC}"
# ============================================================

mkdir -p "${MODEL_DIR}"

if [ -f "${MODEL_PATH}" ]; then
    echo "  GGUF file already exists at ${MODEL_PATH}"
else
    echo "  Downloading ${GGUF_FILENAME} (5.97 GB)..."
    echo "  URL: ${GGUF_URL}"
    wget --progress=bar:force:noscroll -O "${MODEL_PATH}" "${GGUF_URL}"
fi

assert_file_exists "${MODEL_PATH}"

# Validate file size is in expected range
GGUF_ACTUAL_SIZE=$(stat -c%s "${MODEL_PATH}")
assert_true "GGUF file size is in expected range (got: ${GGUF_ACTUAL_SIZE} bytes, expected: ${GGUF_EXPECTED_SIZE_MIN_BYTES}–${GGUF_EXPECTED_SIZE_MAX_BYTES})" \
    "[ '${GGUF_ACTUAL_SIZE}' -ge '${GGUF_EXPECTED_SIZE_MIN_BYTES}' ] && [ '${GGUF_ACTUAL_SIZE}' -le '${GGUF_EXPECTED_SIZE_MAX_BYTES}' ]"

# Validate GGUF magic number (first 4 bytes should be "GGUF")
GGUF_MAGIC=$(head -c4 "${MODEL_PATH}" | cat -v)
assert_true "GGUF file has valid magic number (got: ${GGUF_MAGIC})" \
    "[ '${GGUF_MAGIC}' = 'GGUF' ]"

# ============================================================
echo -e "\n${CYAN}=== 5. Create Systemd User Service ===${NC}"
# ============================================================

mkdir -p "${SERVICE_DIR}"

# Stop existing service if running (not fatal if it doesn't exist)
systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true

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

echo "  Service file written to ${SERVICE_FILE}"

# ============================================================
echo -e "\n${CYAN}=== 6. Enable and Start Service ===${NC}"
# ============================================================

systemctl --user daemon-reload

systemctl --user enable "${SERVICE_NAME}"
assert_true "Service enabled" "systemctl --user is-enabled ${SERVICE_NAME} | grep -q enabled"

systemctl --user start "${SERVICE_NAME}"

echo "  Waiting for llama-server to initialize (loading model into VRAM)..."

# Wait for the server to become ready (up to 120 seconds)
READY=false
for i in $(seq 1 120); do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://${HOST}:${PORT}/health" 2>/dev/null || echo "000")
    if [ "${HTTP_CODE}" = "200" ]; then
        READY=true
        break
    fi
    sleep 1
done

assert_true "Server is responding on http://${HOST}:${PORT}/health (waited ${i}s)" "[ '${READY}' = 'true' ]"

# Validate the service is still running (didn't crash right after responding)
sleep 2
assert_true "Service is active" "systemctl --user is-active ${SERVICE_NAME} | grep -q active"

# ============================================================
echo -e "\n${CYAN}=== 7. Health Check ===${NC}"
# ============================================================

# Check /health endpoint
HEALTH=$(curl -s "http://${HOST}:${PORT}/health")
echo "  /health response: ${HEALTH}"
assert_true "Health endpoint returns status" "echo '${HEALTH}' | grep -q 'status'"

# Check /v1/models endpoint
MODELS=$(curl -s "http://${HOST}:${PORT}/v1/models")
echo "  /v1/models response: ${MODELS}"
assert_true "Models endpoint returns data" "echo '${MODELS}' | grep -q 'data'"

# ============================================================
echo -e "\n${CYAN}=== Setup Complete ===${NC}"
# ============================================================

echo ""
echo "  llama.cpp version:  ${LLAMA_CPP_TAG}"
echo "  Model:              ${GGUF_FILENAME} ($(numfmt --to=iec-i --suffix=B ${GGUF_ACTUAL_SIZE}))"
echo "  Context size:       ${CTX_SIZE} tokens"
echo "  KV cache type:      ${KV_CACHE_TYPE}"
echo "  API endpoint:       http://${HOST}:${PORT}/v1/chat/completions"
echo "  Service:            systemctl --user status ${SERVICE_NAME}"
echo "  Logs:               journalctl --user -u ${SERVICE_NAME} -f"
echo ""
echo -e "  ${GREEN}Ready for agentic coding flows.${NC}"
