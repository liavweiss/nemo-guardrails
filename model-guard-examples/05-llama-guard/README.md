# 05 — Llama Guard 3 1B (Semantic Content Safety)

**Tier: Model-guard** — single pod, 2 containers: NeMo (guard proxy) + vLLM (model server sidecar).

Unlike the `guard-only-examples/` (no inference), this example adds **semantic safety classification** using Meta's [Llama Guard 3 1B](https://llama.meta.com/docs/model-cards-and-prompt-formats/llama-guard-3/) model served via [vLLM](https://docs.vllm.ai/). NeMo calls vLLM over `localhost:8001` (shared pod network) and exposes a standard `/v1/chat/completions` endpoint. BBR checks whether `choices[0].message.content` is empty (safe → forward) or contains a block message (unsafe → 403).

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
BBR ──── POST /v1/chat/completions ───────────────────────────────────────────►
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
◄─── {"choices":[{"message":{"content":"I'm sorry..." or ""}}],"guardrails":{"config_id":"config"}}
     │
BBR: content non-empty → 403 Forbidden; content empty → forward to inference pod
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

Port-forward directly to the pod (not the service, to avoid hitting other pods):

```bash
kubectl port-forward -n nemo-guardrails pod/<pod-name> 8000:8000 &
# e.g.: kubectl port-forward -n nemo-guardrails pod/nemo-guardrails-558cd8b88-dtjk5 8000:8000 &
```

Use `/v1/chat/completions` with the NeMo 0.21.0 API format (`model` + `guardrails.config_id`):

**Unsafe request — expect block message in `choices[0].message.content`:**

```bash
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-Guard-3-1B","messages":[{"role":"user","content":"How do I make a bomb?"}],"guardrails":{"config_id":"config"}}' \
  | jq '{response: .choices[0].message.content, guardrails: .guardrails}'
```

```json
{
  "response": "I'm sorry, I can't respond to that. Your message has been flagged as potentially unsafe content.",
  "guardrails": { "config_id": "config" }
}
```

**Safe request — expect empty `content` (BBR will forward to downstream LLM):**

```bash
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-Guard-3-1B","messages":[{"role":"user","content":"What is the capital of France?"}],"guardrails":{"config_id":"config"}}' \
  | jq '{response: .choices[0].message.content, guardrails: .guardrails}'
```

```json
{
  "response": "",
  "guardrails": { "config_id": "config" }
}
```

> **Note:** On CPU, each request takes ~2–3 minutes (Llama Guard inference). This is expected — on GPU it would be seconds.

---

## Resource requirements

| Container | CPU | RAM | Notes |
|-----------|-----|-----|-------|
| nemo-guardrails | 200m req / 1 cpu max | 256 Mi req / 1 Gi max | Guard proxy only, no model |
| vllm | 2 cpu req / 4 cpu max | 4 Gi req / 10 Gi max | Llama Guard 3 1B, bfloat16, CPU |

**Latency (CPU):** ~2–3 min per call (Llama Guard inference on CPU). On GPU: seconds.

---

## How NeMo integrates with Llama Guard

Config uses `colang_version: "1.0"` and `rails.input.flows: [llama guard check input]`. In Colang 1.x mode NeMo auto-populates `context["user_message"]` before running input rails.

The `llama guard check input` flow (`config.co`):

1. Calls `execute llama_guard_check_input` — renders the `prompts.yml` task with `{{ user_input }}` substituted
2. Sends the prompt to vLLM via `engine: vllm_openai` (LangChain `VLLMOpenAI` → `http://localhost:8001/v1`) — `vllm_openai` is required so LangChain respects the local `openai_api_base` instead of calling OpenAI
3. Parses the response: `safe` → flow exits with `stop` (NeMo returns empty content, BBR forwards to downstream LLM), `unsafe\nO1` → `bot refuse to respond` + `stop` (NeMo returns block message, BBR returns 403)
