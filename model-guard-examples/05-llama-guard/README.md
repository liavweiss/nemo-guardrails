# 05 — Llama Guard 3 1B (Semantic Content Safety)

**Tier: Model-guard** — single pod with two containers (NeMo + Ollama sidecar).

Unlike the `guard-only-examples/` (single pod, no inference), this example adds **semantic safety classification** using Meta's [Llama Guard 3 1B](https://llama.meta.com/docs/model-cards-and-prompt-formats/llama-guard-3/) model served via [Ollama](https://ollama.com/). NeMo and Ollama run as sidecar containers in the same pod — NeMo stays lightweight and calls Ollama over `localhost`.

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
┌──────────────────────────────────────────────────────────┐
│  Single Pod  (nemo-guardrails namespace)                 │
│                                                          │
│  ┌─────────────────────────┐    localhost:11434          │
│  │  NeMo container         │ ──────────────────────────► │
│  │  (port 8000)            │ ◄────────────────────────── │
│  │  - llama guard          │    "safe" / "unsafe\nO1"    │
│  │    check input          │                             │
│  └─────────────────────────┘                             │
│                                                          │
│  ┌─────────────────────────┐                             │
│  │  Ollama sidecar         │                             │
│  │  (port 11434)           │                             │
│  │  llama-guard3:1b        │                             │
│  │  Q4 quantized, CPU-only │                             │
│  └─────────────────────────┘                             │
└──────────────────────────────────────────────────────────┘
```

NeMo and Ollama share the same pod network namespace — NeMo calls `http://localhost:11434/v1` (no K8s DNS hop).
An **init container** pulls `llama-guard3:1b` into a shared volume before the pod starts, so Ollama is ready immediately on each (re)start.

---

## Prerequisites

- Kind cluster (see `scripts/setup-k8s-nemo.sh` — it creates one if needed)
- `podman` (default) or `docker`
- `kubectl` + `kind` CLI
- `curl` + `jq` for testing
- Outbound internet from the Kind node (to pull `llama-guard3:1b` ~700 MB on first run)

---

## Deploy

Uses the same `setup-k8s-nemo.sh` script as all other examples — it auto-detects that this is a model-guard config (presence of `k8s/` subdirectory) and handles the Ollama image automatically.

```bash
# From repo root:

# First time (creates cluster, builds NeMo image, pre-loads Ollama image, deploys pod)
./scripts/setup-k8s-nemo.sh --config-dir model-guard-examples/05-llama-guard

# Rebuild NeMo image after config changes
./scripts/setup-k8s-nemo.sh --rebuild --config-dir model-guard-examples/05-llama-guard

# Use Docker instead of Podman
./scripts/setup-k8s-nemo.sh --docker --rebuild --config-dir model-guard-examples/05-llama-guard
```

> **First run warning:** The init container pulls `llama-guard3:1b` (~700 MB) before the pod starts.
> This takes ~5-10 min on first run. Watch progress:
> ```bash
> kubectl logs -f -n nemo-guardrails -l app=nemo-guardrails -c model-puller
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

Single pod with two containers:

| Container | CPU | RAM | Notes |
|-----------|-----|-----|-------|
| nemo-guardrails | 200m req / 1 cpu max | 256 Mi req / 1 Gi max | No model, pure proxy |
| ollama (sidecar) | 500m req / 2 cpu max | 1 Gi req / 3 Gi max | llama-guard3:1b Q4 ~1.5 GB |
| model-puller (init) | 200m req / 2 cpu max | 512 Mi req / 2 Gi max | Runs once at pod startup, then exits |

**Latency (CPU):** ~60–90 s per call on a small CPU node. For production throughput, use a GPU node (~1–3 s).

---

## How NeMo integrates with Llama Guard

Config uses `colang_version: "1.0"` and `rails.input.flows: - llama guard check input`. In Colang 1.x mode NeMo auto-populates `context["user_message"]` before running input rails, which is what `LlamaGuardCheckInputAction` reads.

The `llama guard check input` flow (overridden in `config.co`):

1. Calls `execute llama_guard_check_input` — renders `prompts.yml` task `llama_guard_check_input` with `{{ user_input }}` substituted
2. Sends the prompt to Ollama via `engine: openai` (LangChain `ChatOpenAI` → `localhost:11434/v1/chat/completions`)
3. Parses the response: `safe` → allow, `unsafe\nO1` → block
4. Blocked: responds with our custom refusal message and `stop` (no main LLM needed)
5. Allowed: responds with `"Request allowed."` and `stop`

---

## Combining with guard-only guards

To run Llama Guard alongside the guard-only guards (keywords, Presidio, jailbreak, YARA), you would:
1. Keep the existing `guard-only-config/` pod for rule-based filtering
2. Add Llama Guard as a second pass — either in the same NeMo config (if you also deploy Ollama) or as a separate proxy layer

The two approaches are independent by design so you can evaluate each separately.
