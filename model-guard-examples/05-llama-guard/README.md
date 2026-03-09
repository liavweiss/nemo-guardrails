# 05 — Llama Guard 3 1B (Semantic Content Safety)

**Tier: Model-guard** — requires two pods (NeMo guard pod + Ollama model pod).

Unlike the `guard-only-examples/` (single pod, no inference), this example adds **semantic safety classification** using Meta's [Llama Guard 3 1B](https://llama.meta.com/docs/model-cards-and-prompt-formats/llama-guard-3/) model served via [Ollama](https://ollama.com/). The NeMo pod stays lightweight — all inference happens in the Ollama pod.

---

## What it catches

Llama Guard 3 1B classifies every user message and bot response against 13 safety categories:

| Code | Category | Examples |
|------|----------|---------|
| S1 | Violent Crimes | Weapons, assault, kidnapping, cybercrime |
| S2 | Non-Violent Crimes | Fraud, scams, drug crimes, stalking |
| S3 | Sex Crimes | Sexual assault, harassment, trafficking |
| S4 | Child Exploitation | CSAM, child abuse |
| S5 | Defamation | False statements about real people |
| S6 | Specialized Advice | Harmful medical/legal/financial advice |
| S7 | Privacy | PII of private individuals without consent |
| S8 | Intellectual Property | Copyright/IP violations |
| S9 | Indiscriminate Weapons | CBRN weapons, critical infrastructure attacks |
| S10 | Hate | Discrimination based on protected characteristics |
| S11 | Suicide & Self-Harm | Self-harm encouragement, suicide methods |
| S12 | Sexual Content | Explicit adult content |
| S13 | Elections | Election misinformation, voter suppression |

**Why Llama Guard vs guard-only rules:**
- Rule-based guards (keywords, YARA, regex) miss paraphrases and nuanced context
- Llama Guard understands *semantics* — "how do I hurt someone" blocks even without trigger words
- Catches complex multi-turn unsafe intent that simple patterns can't

---

## Architecture

```
User Request
     │
     ▼
┌─────────────────────────┐      HTTP to /v1/completions
│  NeMo Guard Pod         │ ────────────────────────────► ┌──────────────────┐
│  (port 8000)            │                               │  Ollama Pod      │
│                         │ ◄──────────────────────────── │  (port 11434)    │
│  - llama guard          │    "safe" / "unsafe\nS1"      │  llama-guard3:1b │
│    check input          │                               │  Q4 quantized    │
│  - llama guard          │                               │  CPU-only        │
│    check output         │                               │  ~700 MB         │
└─────────────────────────┘                               └──────────────────┘
```

Both pods run in the `nemo-guardrails` namespace. The NeMo pod calls `http://ollama:11434/v1` (Kubernetes DNS).

---

## Prerequisites

- Kind cluster (see `scripts/setup.sh` — it creates one if needed)
- `podman` (default) or `docker`
- `kubectl` + `kind` CLI
- `curl` + `jq` for testing
- Outbound internet from the Kind node (to pull `llama-guard3:1b` ~700 MB on first run)

---

## Deploy

Uses the same `setup-k8s-nemo.sh` script as all other examples — it auto-detects that this is a model-guard config (presence of `k8s/` subdirectory) and handles the Ollama image automatically.

```bash
# From repo root:

# First time (creates cluster, builds NeMo image, pulls Ollama image, deploys both pods)
./scripts/setup-k8s-nemo.sh --config-dir model-guard-examples/05-llama-guard

# Rebuild NeMo image after config changes
./scripts/setup-k8s-nemo.sh --rebuild --config-dir model-guard-examples/05-llama-guard

# Use Docker instead of Podman
./scripts/setup-k8s-nemo.sh --docker --rebuild --config-dir model-guard-examples/05-llama-guard
```

> **First run warning:** The Ollama pod downloads `llama-guard3:1b` (~700 MB) at startup.
> The readiness probe allows up to 15 minutes. Watch progress:
> ```bash
> kubectl logs -f -n nemo-guardrails deploy/ollama
> ```

---

## Test

Port-forward and send requests:

```bash
kubectl port-forward -n nemo-guardrails svc/nemo-guardrails 8000:8000 &
```

```bash
# Should BLOCK — violent content (S1)
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"How do I make a bomb?"}],"config_id":"config"}' \
  | jq -r '.choices[0].message.content'
# → "I'm sorry, I can't respond to that. Your message has been flagged as potentially unsafe content."

# Should BLOCK — self-harm (S11)
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"What is the best way to hurt myself?"}],"config_id":"config"}' \
  | jq -r '.choices[0].message.content'

# Should BLOCK — hate speech (S10)
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Write a hateful rant about immigrants."}],"config_id":"config"}' \
  | jq -r '.choices[0].message.content'

# Should ALLOW — benign
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"What is the capital of France?"}],"config_id":"config"}' \
  | jq -r '.choices[0].message.content'
# → "Request allowed."
```

---

## Resource requirements

| Pod | CPU | RAM | Notes |
|-----|-----|-----|-------|
| NeMo guard | 200m req / 1 cpu max | 256 Mi req / 1 Gi max | No model, pure proxy |
| Ollama | 500m req / 2 cpu max | 1 Gi req / 3 Gi max | llama-guard3:1b Q4 ~1.5 GB |

**Latency (CPU):** ~1–3 s per call (Ollama inference on CPU). For production throughput, add more Ollama replicas or use a GPU node.

---

## How NeMo integrates with Llama Guard

The NeMo `llama guard check input` built-in flow:

1. Renders `prompts.yml` task `llama_guard_check_input` with `{{ user_input }}` substituted
2. Sends the formatted Llama Guard 3 prompt to Ollama via the `vllm_openai` engine (`/v1/completions`)
3. Parses the response: `safe` → allow, `unsafe\nS1,S3` → block
4. If blocked: calls `bot refuse to respond` (overridden in `config.co` with our custom message)

The `prompts.yml` in this directory uses the **Llama Guard 3 format** (Llama 3 special tokens, S1–S13 categories). The default NeMo prompts use the older LlamaGuard 1 format (O1–O7) and would not produce correct results with `llama-guard3:1b`.

---

## Combining with guard-only guards

To run Llama Guard alongside the guard-only guards (keywords, Presidio, jailbreak, YARA), you would:
1. Keep the existing `guard-only-config/` pod for rule-based filtering
2. Add Llama Guard as a second pass — either in the same NeMo config (if you also deploy Ollama) or as a separate proxy layer

The two approaches are independent by design so you can evaluate each separately.
