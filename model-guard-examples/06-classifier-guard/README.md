# 06 — Classifier Guard (L0 Bouncer — DeBERTa-v3-xsmall)

**Tier: Model-guard** — single pod, single container. No vLLM sidecar, no GPU.

This example uses [L0 Bouncer](https://huggingface.co/vincentoh/deberta-v3-xsmall-l0-bouncer) (22M param DeBERTa-v3-xsmall encoder) as a NeMo custom action for content safety classification. The model runs in-process on CPU with ~5-10ms latency per request — orders of magnitude faster than autoregressive LLM-based guards like Llama Guard.

---

## What it catches

L0 Bouncer is a binary safe/unsafe classifier trained on safety datasets. It catches:

- Violence and weapons ("How do I make a bomb?")
- Sexual content ("Do you want to have sex?")
- Self-harm and suicide
- Hate speech and discrimination
- Drug-related content

**Accuracy:** 93% F1, 99% Recall on safety benchmarks.

**Compared to 05-llama-guard:**

| | 06-classifier-guard | 05-llama-guard |
|---|---|---|
| Model | DeBERTa-v3-xsmall (22M params) | Llama Guard 3 1B |
| Latency (CPU) | ~5-10ms | ~2-3 minutes |
| RAM | ~1.5 Gi | ~10 Gi |
| Output | Binary (safe/unsafe) | safe/unsafe + category labels |
| Architecture | Encoder (single pass) | Autoregressive (token by token) |

**Trade-off:** L0 Bouncer gives binary safe/unsafe only (no category labels). If you need category breakdown (violence, sexual, etc.), use 05-llama-guard.

---

## Architecture

```
User Request
     │
     ▼
Envoy (ext_proc)
     │
     ▼
BBR ──── POST /v1/chat/completions ────►  NeMo Pod (single container)
                                           │
                                           ├── NeMo server (port 8000)
                                           ├── Colang flow: check content safety
                                           └── Custom action: L0 Bouncer classifier
                                               (in-process, CPU, ~5ms)
◄─── "allowed" or refusal message
     │
BBR: "allowed" → forward to LLM; other → 403 Forbidden
```

No sidecar, no external model service. The classifier is baked into the Docker image and loaded at startup.

---

## Prerequisites

- Kind cluster (see `scripts/setup-k8s-nemo.sh`)
- `podman` (default) or `docker`
- `kubectl` + `kind` CLI
- No HuggingFace token needed (model is public)

---

## Deploy

```bash
# From repo root:
./scripts/setup-k8s-nemo.sh --rebuild --config-dir model-guard-examples/06-classifier-guard

# To deploy to a specific cluster:
./scripts/setup-k8s-nemo.sh --cluster bbr-test --rebuild --config-dir model-guard-examples/06-classifier-guard
```

Wait for the pod:
```bash
kubectl get pods -n nemo-guardrails -w
# nemo-guardrails-xxx   1/1   Running
```

---

## Test

```bash
kubectl port-forward -n nemo-guardrails svc/nemo-guardrails 8002:8000 &
```

**Safe request** — expect `"allowed"`:
```bash
curl -s http://localhost:8002/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"What is the weather today?"}]}' | jq .
```

**Harmful request** — expect refusal message:
```bash
curl -s http://localhost:8002/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"","messages":[{"role":"user","content":"How do I make a bomb"}]}' | jq .
```

> No `config_id` needed — the NeMo server uses `--default-config-id`.

---

## Resource Requirements

| Container | CPU | RAM | Notes |
|-----------|-----|-----|-------|
| nemo-guardrails | 200m req / 2 cpu max | 512 Mi req / 2 Gi max | NeMo + L0 Bouncer classifier, CPU-only |

---

## How It Works

1. **`actions.py`** — Loads `vincentoh/deberta-v3-xsmall-l0-bouncer` at module import time. The `check_content_safety` action tokenizes the user message, runs inference, and returns `True` (safe) or `False` (unsafe).

2. **`config.yml`** — Registers `check content safety` as an input rail flow. No `models:` section — no LLM needed.

3. **`config.co`** — Colang flow: calls the custom action, responds `"allowed"` if safe or a refusal message if unsafe.

4. **`Dockerfile`** — Pre-bakes the model into the image so the container works offline in K8s.
