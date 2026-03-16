# Qwen 3.5 9B Local Inference Server

A systemd user service running **Qwen 3.5 9B** (Alibaba Qwen) via **llama.cpp** on an NVIDIA GeForce RTX 2060 SUPER (8 GB VRAM). Provides an OpenAI-compatible API at `http://127.0.0.1:8080/v1/chat/completions` with tool calling, thinking mode, and sampling parameters tuned for agentic coding flows.

---

## System

| Component | Details |
|---|---|
| Machine | HP Pavilion Gaming Desktop TG01-1xxx (hostname: `rtx2060`) |
| GPU | NVIDIA GeForce RTX 2060 SUPER, 8192 MiB VRAM, Turing architecture (TU106), compute capability 7.5 |
| NVIDIA Driver | 570.211.01 (server, open kernel module) |
| CUDA Toolkit | 12.8 (V12.8.93), installed at `/usr/local/cuda` |
| Operating System | Ubuntu Server 24.04.4 LTS (Noble Numbat) |
| Kernel | Linux 6.8.0-106-generic (x86-64) |

---

## Pinned Versions

Every external dependency is pinned to a specific version or commit hash. No floating tags, no `latest`.

| Component | Version | Pin |
|---|---|---|
| llama.cpp | Release **b8377** (March 16, 2026) | Git tag `b8377` |
| GGUF model file | `Qwen3.5-9B-UD-Q4_K_XL.gguf` | From [unsloth/Qwen3.5-9B-GGUF](https://huggingface.co/unsloth/Qwen3.5-9B-GGUF), 5.97 GB |
| CUDA build target | Compute capability 7.5 (Turing) | CMake flag `-DCMAKE_CUDA_ARCHITECTURES=75` |

---

## Why This Model and Quantization

### Qwen 3.5 9B

Qwen 3.5 is a **hybrid architecture** combining 24 Gated DeltaNet (GDN) recurrent layers with 8 standard full-attention layers (`full_attention_interval=4`). The recurrent layers use a fixed-size state (not a per-token KV cache), which means only the 8 full-attention layers allocate KV cache that grows with context length. This gives Qwen 3.5 roughly **4x the context capacity** of a standard 32-layer transformer on the same VRAM budget.

Qwen 3.5 is a **thinking model** by default. It generates reasoning inside `<think>...</think>` tags before producing its response. Unlike Qwen 3, Qwen 3.5 does **not** support `/think` and `/nothink` soft switches in user messages. Thinking is controlled only via the `enable_thinking` template parameter.

### Why Unsloth Dynamic 2.0 UD-Q4_K_XL (not standard Q4_K_M)

Standard Q4_K_M quantization treats every tensor equally — the novel GDN/SSM layers (`ssm_alpha`, `ssm_beta`, `ssm_out`) that control the recurrent memory dynamics get the same low-precision Q4_K as generic FFN layers. Unsloth Dynamic 2.0 uses per-tensor quantization that protects these critical layers at dramatically higher precision:

| Tensor (GDN layers) | Standard Q4_K_M | Unsloth UD-Q4_K_XL |
|---|---|---|
| `ssm_alpha` | Q4_K (4.5 bpw) | **F16 (16.0 bpw)** |
| `ssm_beta` | Q4_K (4.5 bpw) | **F16 (16.0 bpw)** |
| `ssm_out` | Q5_K (5.5 bpw) | **Q8_0 (8.5 bpw)** |

The UD-Q4_K_XL is 5.97 GB versus 5.68 GB for Q4_K_M — a 0.29 GB increase that buys substantially better recurrent layer fidelity. The extra bit budget is funded by selective IQ4_XS on a handful of generic FFN blocks where quality impact is minimal.

---

## Model Architecture (from [Qwen/Qwen3.5-9B config.json](https://huggingface.co/Qwen/Qwen3.5-9B/blob/main/config.json))

| Parameter | Value |
|---|---|
| `num_hidden_layers` | 32 |
| `num_attention_heads` | 16 |
| `num_key_value_heads` | 4 |
| `head_dim` | 256 |
| `hidden_size` | 4096 |
| `intermediate_size` | 12288 |
| `max_position_embeddings` | 262,144 (256K native, up to 1M with YaRN) |
| `full_attention_interval` | 4 (every 4th layer is full attention) |
| `vocab_size` | 248,320 |
| `rms_norm_eps` | 1e-06 |
| `rope_theta` | 10,000,000 |
| `partial_rotary_factor` | 0.25 |
| `mrope_interleaved` | true (Interleaved Multi-scale RoPE) |
| `mrope_section` | [11, 11, 10] |
| `linear_num_key_heads` | 16 |
| `linear_num_value_heads` | 32 |
| `linear_key_head_dim` | 128 |
| `linear_value_head_dim` | 128 |
| `linear_conv_kernel_dim` | 4 |
| `mtp_num_hidden_layers` | 1 |

**Layer layout** (32 layers): `[linear, linear, linear, full, linear, linear, linear, full, ...]` — 8 repeating blocks of 3 recurrent + 1 full attention.

---

## VRAM Calculation

### Model Weights

| Component | VRAM |
|---|---|
| Model weights (UD-Q4_K_XL GGUF) | 5,970 MB (5.97 GB) |
| CUDA context + compute buffers | ~300 MB |
| Recurrent state (24 GDN layers, fixed size) | ~50 MB |
| **Total fixed cost** | **~6,320 MB** |
| **Available for KV cache** | **~1,872 MB** |

### KV Cache Cost Per Token

Only the **8 full-attention layers** allocate per-token KV cache. Each layer stores K and V tensors:

```
Per layer per token: 4 KV-heads x 256 head_dim x 2 (K + V) = 2,048 elements
8 layers total: 2,048 x 8 = 16,384 elements per token
```

| KV Cache Type | Bytes per Element | Bytes per Token (8 layers) | Max Context (in ~1,872 MB) |
|---|---|---|---|
| **FP16 (chosen)** | **2.0** | **32,768 (~32 KB)** | **~59,900 tokens** |
| Q8_0 | 1.0625 | 17,408 (~17 KB) | ~112,800 tokens |
| Q4_0 | 0.5625 | 9,216 (~9 KB) | ~213,300 tokens |

**KV cache quantization is not used.** Quantizing the KV cache (Q8_0 or Q4_0) yields unacceptable quality and stability decreases for long agentic coding flows. The llama.cpp documentation itself warns about degraded tool calling performance with quantized KV caches. FP16 is the only acceptable option for production use.

### Chosen Context Size: 55,296 tokens (54K)

With FP16 KV cache, 55,296 tokens uses approximately **1,728 MB** of the available ~1,872 MB, leaving ~**144 MB** for batch processing buffers, flash attention workspace, and other runtime allocations. This uses nearly the full 8,192 MiB of VRAM on the RTX 2060 SUPER.

**Note:** The Qwen 3.5 model card recommends a minimum of 128K context "to preserve thinking capabilities." This is not achievable on 8 GB VRAM with the 9B model at FP16 KV cache. The 54K context is a hardware-imposed trade-off. Thinking mode still works at 54K — the recommendation is about quality at the upper end of deep reasoning chains, not a hard functional requirement.

---

## Server Configuration

The `llama-server` process is started with every parameter explicitly specified. No defaults are relied upon.

### Server Flags

```
llama-server \
  --model          ~/qwen3_5_server/models/Qwen3.5-9B-UD-Q4_K_XL.gguf \
  --host           127.0.0.1 \
  --port           8080 \
  --ctx-size       55296 \
  --flash-attn     on \
  --cache-type-k   f16 \
  --cache-type-v   f16 \
  --gpu-layers     999 \
  --jinja \
  --reasoning-format deepseek \
  --reasoning-budget -1 \
  --temp           0.6 \
  --top-k          20 \
  --top-p          0.95 \
  --min-p          0.0 \
  --repeat-penalty 1.0 \
  --predict        -1 \
  --metrics \
  --no-webui \
  --log-timestamps
```

### Flag-by-Flag Explanation

| Flag | Value | Reason |
|---|---|---|
| `--model` | Path to GGUF | The Unsloth Dynamic 2.0 UD-Q4_K_XL quantization of Qwen 3.5 9B |
| `--host 127.0.0.1` | Localhost only | Not exposed to the network. Clients connect locally. |
| `--port 8080` | Default llama.cpp port | OpenAI-compatible API at `/v1/chat/completions` |
| `--ctx-size 55296` | 54K tokens | Maximum context for 8 GB VRAM with FP16 KV cache, leaving ~144 MB headroom (see VRAM calculation) |
| `--flash-attn on` | Enabled | Reduces VRAM usage and increases throughput for the 8 full-attention layers. Explicitly `on` instead of `auto` to fail loudly if unsupported. |
| `--cache-type-k f16` | FP16 keys (default) | Full precision. KV cache quantization (Q8_0, Q4_0) degrades quality and stability for tool calling and long agentic flows. |
| `--cache-type-v f16` | FP16 values (default) | Same rationale as keys |
| `--gpu-layers 999` | Offload all 32 layers to GPU | Forces full GPU offload. Model is 5.97 GB — fits entirely in 8 GB VRAM. Using a large number instead of `auto` to prevent silent CPU fallback. |
| `--jinja` | Enabled (default) | Required for tool calling. Processes the Jinja2 chat template embedded in the GGUF file. This is the template from the official Qwen 3.5 model — it handles the Qwen3-Coder XML tool calling format, thinking blocks, and multi-turn conversation management. Explicitly specified even though it's the default, because tool calling completely breaks without it. |
| `--reasoning-format deepseek` | Extract thinking | Parses `<think>...</think>` blocks from model output and returns them in the `reasoning_content` field of the OpenAI-compatible response. Named "deepseek" after the format popularized by DeepSeek R1, but applies to any model using `<think>` tags including Qwen 3.5. The alternative `auto` would also work — it auto-detects. Explicitly set for deterministic behavior. |
| `--reasoning-budget -1` | Unrestricted | No limit on thinking token budget. The model decides when to stop reasoning. `-1` means unlimited. |
| `--temp 0.6` | Low temperature | Qwen 3.5 model card "Thinking — Precise Coding" profile. Lower than the general profile (1.0) for more deterministic code generation. |
| `--top-k 20` | Top-K sampling | Qwen 3.5 model card recommendation for all profiles |
| `--top-p 0.95` | Nucleus sampling | Qwen 3.5 model card "Thinking — Precise Coding" profile |
| `--min-p 0.0` | Disabled | Qwen 3.5 model card recommendation (0.0 = disabled) |
| `--repeat-penalty 1.0` | Disabled | Qwen 3.5 model card explicitly recommends 1.0 (disabled) for all four parameter profiles. Repeat penalty is distinct from presence penalty. |
| `--predict -1` | No output limit | Unlimited generation length per request. Clients set their own `max_tokens`. |
| `--metrics` | Prometheus metrics | Exposes `/metrics` endpoint for monitoring token throughput, queue depth, and VRAM usage |
| `--no-webui` | Disabled | No need for the built-in web UI — this is a headless API service |
| `--log-timestamps` | Enabled | Timestamps in log output for debugging service issues via `journalctl` |

### Sampling Parameter Profiles (Per-Request Override)

The server defaults are set to the **Thinking — Precise Coding** profile. Clients can override any parameter per request. All four profiles from the [Qwen 3.5 model card](https://huggingface.co/Qwen/Qwen3.5-9B):

| Profile | temperature | top_p | top_k | min_p | presence_penalty | repeat_penalty |
|---|---|---|---|---|---|---|
| **Thinking — Precise Coding** (server default) | 0.6 | 0.95 | 20 | 0.0 | 0.0 | 1.0 |
| Thinking — General | 1.0 | 0.95 | 20 | 0.0 | 1.5 | 1.0 |
| Non-Thinking — General | 0.7 | 0.8 | 20 | 0.0 | 1.5 | 1.0 |
| Non-Thinking — Hard Reasoning | 1.0 | 1.0 | 40 | 0.0 | 2.0 | 1.0 |

---

## Tool Calling

Tool calling uses the **Qwen3-Coder XML format** — the format Qwen 3.5 was trained on. This is handled automatically by the Jinja2 template embedded in the GGUF file when `--jinja` is enabled.

The format uses XML-style tags:
```xml
<tool_call>
<function=function_name>
<parameter=param_name>
value
</parameter>
</function>
</tool_call>
```

Clients send standard OpenAI-format `tools` arrays in their `/v1/chat/completions` requests. The server translates between OpenAI JSON format and the model's native XML format transparently.

**Important:** This is NOT the Hermes-style JSON format (`<tool_call>{"name": ...}</tool_call>`) used by Qwen 3 and Qwen 2.5. Qwen 3.5 was trained on the Qwen3-Coder XML format. Using the wrong format causes tool calling to silently fail — the model receives prompts in a format it was never trained on. This is the primary bug that affects Ollama's Qwen 3.5 integration (see [BigBIueWhale/qwen3_5_27b_research](https://github.com/BigBIueWhale/qwen3_5_27b_research) for the full analysis). llama.cpp avoids this bug entirely by executing the model's own Jinja2 template rather than reimplementing it.

### Special Tokens

| Token | ID | Purpose |
|---|---|---|
| `<\|im_start\|>` | 248045 | Message start delimiter |
| `<\|im_end\|>` | 248046 | Message end delimiter / EOS token |
| `<\|endoftext\|>` | 248044 | Pad token |
| `<think>` | 248068 | Thinking block start |
| `</think>` | 248069 | Thinking block end |
| `<tool_call>` | 248058 | Tool call block start |
| `</tool_call>` | 248059 | Tool call block end |
| `<tool_response>` | 248066 | Tool response start |
| `</tool_response>` | 248067 | Tool response end |

---

## Why llama.cpp Instead of Ollama

Ollama v0.17.4 has four critical bugs that make Qwen 3.5's agentic capabilities completely non-functional ([full analysis](https://github.com/BigBIueWhale/qwen3_5_27b_research)):

1. **Wrong tool calling format** — Ollama sends the Qwen 3 Hermes-style JSON format instead of the Qwen3-Coder XML format that Qwen 3.5 was trained on
2. **Repetition penalties silently ignored** — `repeat_penalty`, `presence_penalty`, and `frequency_penalty` are accepted by the API and silently discarded in the Go runner
3. **Unclosed `</think>` tags** — Multi-turn prompts with thinking + tool calls have corrupted `<think>` blocks
4. **Missing generation prompt after tool calls** — The model receives no `<|im_start|>assistant` to begin generating after tool call turns

llama.cpp avoids all of these by executing the model's own Jinja2 chat template directly, rather than reimplementing it in application code.

---

## Setup

```bash
bash ~/rtx2060_super_setup/qwen3_5_server/setup.sh
```

The script is **idempotent** — safe to run multiple times:

- Detects existing llama.cpp clone and only rebuilds if the pinned tag has changed
- Skips the 5.97 GB GGUF download if the correct file already exists (validated by size + GGUF magic number)
- Re-downloads automatically if the file is corrupt, truncated, or the wrong size
- Downloads to a `.tmp` file first and validates before moving into place (no partial files left behind)
- Always regenerates the systemd service file (cheap, ensures config is up to date)
- Stops the service before making changes, restarts after

**Steps:**

1. Validates all system prerequisites (GPU, CUDA, cmake, disk space, lingering) with fatal assertions
2. Stops existing service if running
3. Clones llama.cpp at the pinned tag `b8377` (or validates existing clone is at the correct tag; removes and re-clones if tag changed)
4. Builds `llama-server` with CUDA support targeting compute capability 7.5 (Turing / RTX 2060 SUPER)
5. Downloads the Unsloth UD-Q4_K_XL GGUF (5.97 GB) with size and magic number validation
6. Creates a systemd user service at `~/.config/systemd/user/llama-server.service`
7. Enables and starts the service
8. Runs a health check against the API

The script runs as your regular user (not root). It uses `systemctl --user` for the service. Systemd user lingering must be enabled beforehand (see the [main README](../README.md#step-5-enable-systemd-user-lingering)).

---

## Verification

After setup, verify the service is running:

```bash
# Service status
systemctl --user status llama-server

# View logs
journalctl --user -u llama-server -f

# Health check
curl -s http://127.0.0.1:8080/health | python3 -m json.tool

# Model info
curl -s http://127.0.0.1:8080/v1/models | python3 -m json.tool
```

### Test: Simple Chat

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.5-9b",
    "messages": [{"role": "user", "content": "Write a Python function that checks if a number is prime."}],
    "temperature": 0.6,
    "max_tokens": 4096
  }' | python3 -m json.tool
```

### Test: Tool Calling

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.5-9b",
    "messages": [{"role": "user", "content": "What is the weather in San Francisco?"}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather for a location",
        "parameters": {
          "type": "object",
          "properties": {
            "city": {"type": "string", "description": "City name"}
          },
          "required": ["city"]
        }
      }
    }],
    "temperature": 0.6,
    "max_tokens": 4096
  }' | python3 -m json.tool
```

The response should include `tool_calls` with `function.name: "get_weather"` and `function.arguments` containing `{"city": "San Francisco"}`.

---

## Service Management

```bash
# Start
systemctl --user start llama-server

# Stop
systemctl --user stop llama-server

# Restart
systemctl --user restart llama-server

# View logs (follow)
journalctl --user -u llama-server -f

# View logs (last 100 lines)
journalctl --user -u llama-server -n 100

# Prometheus metrics
curl -s http://127.0.0.1:8080/metrics
```

The service is configured with `Restart=on-failure` and a 5-second restart delay. If `llama-server` crashes, systemd will automatically restart it.

---

## References

- [Qwen/Qwen3.5-9B](https://huggingface.co/Qwen/Qwen3.5-9B) — Official model card, architecture, recommended parameters
- [Qwen/Qwen3.5-9B config.json](https://huggingface.co/Qwen/Qwen3.5-9B/blob/main/config.json) — Full architecture parameters
- [unsloth/Qwen3.5-9B-GGUF](https://huggingface.co/unsloth/Qwen3.5-9B-GGUF) — Unsloth Dynamic 2.0 quantized GGUF files
- [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) — Inference engine
- [llama.cpp function calling docs](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md) — Tool calling setup
- [llama.cpp server docs](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) — Server flags reference
- [BigBIueWhale/qwen3_5_27b_research](https://github.com/BigBIueWhale/qwen3_5_27b_research) — Analysis of Ollama bugs with Qwen 3.5
