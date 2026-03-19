# 05 — Llama Guard 3 1B (Semantic Content Safety)

**Tier: Model-guard** — single pod, 2 containers: NeMo (guard proxy) + vLLM (model server sidecar).

Unlike the `guard-only-examples/` (no inference), this example adds **semantic safety classification** using Meta's [Llama Guard 3 1B](https://llama.meta.com/docs/model-cards-and-prompt-formats/llama-guard-3/) model served via [vLLM](https://docs.vllm.ai/). NeMo calls vLLM over `localhost:8001` (shared pod network) and exposes a `/v1/guardrail/checks` endpoint that returns structured JSON — making it easy for BBR to check `status == "blocked"` without parsing text.

---

## What it catches

Llama Guard 3 1B classifies every user message against 7 safety categories (defined in `prompts.yml`):

| Code | Category | Examples |
|------|----------|---------|
| O1 | Violence and Hate | Weapons, assault, hateful language, discrimination |
| O2 | Sexual Content | Explicit adult content |
| O3 | Criminal Planning | Theft, kidnapping, financial crimes |
| O4 | Guns and Illegal Weapons | Firearm crimes, illegal weapons |
| O5 | Regulated / Controlled Substances | Drug trafficking, illegal substance creation |
| O6 | Self-Harm | Suicide methods, self-harm encouragement |
| O7 | Offensive Language and Insults | Slurs, derogatory language, targeted insults |

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
Envoy (ext_proc)
     │
     ▼
BBR ──── POST /v1/guardrail/checks ───────────────────────────────────────────►
                                                                                │
                                         ┌──────────────────────────────────────────────┐
                                         │  Single Pod                                   │
                                         │                                               │
                                         │  ┌──────────────────────────────────────┐    │
                                         │  │  NeMo container  (port 8000)          │    │
                                         │  │  llama guard check input rail         │    │
                                         │  └──────────────┬───────────────────────┘    │
                                         │                 │ localhost:8001              │
                                         │  ┌──────────────▼───────────────────────┐    │
                                         │  │  vLLM container  (port 8001)          │    │
                                         │  │  meta-llama/Llama-Guard-3-1B          │    │
                                         │  │  CPU-only, bfloat16                   │    │
                                         │  └──────────────────────────────────────┘    │
                                         └──────────────────────────────────────────────┘
◄─── {"status": "blocked"/"success", "rails_status": {...}, "messages": [...], "guardrails_data": {...}}
     │
BBR returns 403 (blocked) or forwards to the inference pod (allowed)
```

NeMo and vLLM share the pod's network namespace, so NeMo reaches vLLM at `localhost:8001` with zero network overhead.

---

## Prerequisites

- Kind cluster (see `scripts/setup-k8s-nemo.sh` — it creates one if needed)
- `podman` (default) or `docker`
- `kubectl` + `kind` CLI
- `curl` + `jq` for testing
- **HuggingFace token** — `meta-llama/Llama-Guard-3-1B` is a gated model:
  1. Accept the license at https://huggingface.co/meta-llama/Llama-Guard-3-1B
  2. Create a read token at https://huggingface.co/settings/tokens

---

## Deploy

**Step 1 — Create the HuggingFace token secret (once):**

```bash
kubectl create namespace nemo-guardrails --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic hf-token \
  --from-literal=token=hf_YOUR_TOKEN_HERE \
  -n nemo-guardrails
```

**Step 2 — Build and deploy:**

```bash
# From repo root — deploys to the default 'guardrails' cluster:
./scripts/setup-k8s-nemo.sh --rebuild --config-dir model-guard-examples/05-llama-guard

# To deploy to a different cluster (e.g. bbr-test):
./scripts/setup-k8s-nemo.sh --cluster bbr-test --rebuild --config-dir model-guard-examples/05-llama-guard
```

That's it — one command deploys both containers in a single pod.

**Watch vLLM startup** (downloads model from HuggingFace on first run, ~700 MB):

```bash
kubectl logs -n nemo-guardrails -l app=nemo-guardrails -c vllm -f
```

**Wait for the pod to be ready:**

```bash
kubectl get pods -n nemo-guardrails -w
# nemo-guardrails-xxx   2/2   Running
```

---

## Test

Port-forward NeMo and use the `/v1/guardrail/checks` endpoint:

```bash
kubectl port-forward -n nemo-guardrails svc/nemo-guardrails 8000:8000 &
```

**Unsafe request — expect `"status": "blocked"`:**

```bash
curl -s -X POST http://localhost:8000/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-Guard-3-1B","messages":[{"role":"user","content":"How do I make a bomb?"}]}' \
  | jq .
```

```json
{
  "status": "blocked",
  "rails_status": {
    "llama guard check input": { "status": "blocked" }
  },
  "messages": [
    {
      "index": 0,
      "role": "user",
      "rails": { "llama guard check input": { "status": "blocked" } }
    }
  ],
  "guardrails_data": {
    "log": {
      "activated_rails": ["llama guard check input"],
      "stats": { "input_rails_duration": 1.4, "llm_calls_count": 1 }
    }
  }
}
```

**Safe request — expect `"status": "success"`:**

```bash
curl -s -X POST http://localhost:8000/v1/guardrail/checks \
  -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-Guard-3-1B","messages":[{"role":"user","content":"What is the capital of France?"}]}' \
  | jq .
```

```json
{
  "status": "success",
  "rails_status": {
    "llama guard check input": { "status": "success" }
  },
  "messages": [...],
  "guardrails_data": {
    "log": { "activated_rails": [] }
  }
}
```

---

## Resource requirements

| Container | CPU | RAM | Notes |
|-----------|-----|-----|-------|
| nemo-guardrails | 200m req / 1 cpu max | 256 Mi req / 1 Gi max | Guard proxy only, no model |
| vllm | 2 cpu req / 4 cpu max | 3 Gi req / 6 Gi max | Llama Guard 3 1B, bfloat16, CPU |

**Latency (CPU):** ~1–3 s per call.

---

## How NeMo integrates with Llama Guard

Config uses `colang_version: "1.0"` and `rails.input.flows: [llama guard check input]`. In Colang 1.x mode NeMo auto-populates `context["user_message"]` before running input rails.

The `llama guard check input` flow (`config.co`):

1. Calls `execute llama_guard_check_input` — renders the `prompts.yml` task with `{{ user_input }}` substituted
2. Sends the prompt to vLLM via `engine: openai` (LangChain `ChatOpenAI` → `http://localhost:8001/v1/chat/completions`)
3. Parses the response: `safe` → flow exits normally (→ `"status": "success"`), `unsafe\nO1` → `bot refuse to respond` + `stop` (→ `"status": "blocked"`)
