# NeMo Guardrails — Guard-Only Pod on Kubernetes

## What is this?

[NeMo Guardrails](https://github.com/NVIDIA/NeMo-Guardrails) is NVIDIA's open-source framework for adding programmable safety rails around LLM-based systems. It intercepts user inputs and LLM outputs and can block, mask, or modify them based on configurable rules — **without needing to run an LLM itself**.

This project deploys NeMo Guardrails as a **dedicated guard pod on Kubernetes** — lightweight, no GPU, no main LLM. The pod's only job is to inspect and filter traffic. It is designed to run alongside the [gateway-api-inference-extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension) and integrate with its **Body-Based Routing (BBR)** component via an HTTP callout plugin.

---

## Architecture

```
User Request
     │
     ▼
Envoy (ext_proc)
     │
     ▼
BBR (Body-Based Routing)  ──── HTTP callout ────▶  NeMo Guardrails Pod
     │                                              (guard only, no LLM)
     │  ◀── allow (200) or block (403) ────────────
     │
     ▼  if allowed:
Main LLM Pod (vLLM / TGI / etc.)
     │
     ▼
Response → back through BBR → (output guard) → User
```

The NeMo pod exposes `/v1/chat/completions` (same API shape as OpenAI). BBR sends the request body to NeMo; if NeMo detects a violation it returns a block message, BBR converts that to a `403 Forbidden` to the user. If allowed, BBR forwards to the real LLM.

---

## Active Guards (No Inference, No GPU)

| Guard | What it catches | How |
|-------|----------------|-----|
| **Keyword blocking** | Harmful phrases: "bomb", "hack", "weapon", … | Custom action — block list (input) |
| **Pattern / regex** | SSN format, 16-digit card numbers, "my password is …", API keys | Custom action — regex (input) |
| **Jailbreak heuristics** | DAN prompts, GCG adversarial suffix attacks | NeMo built-in — gpt2-large perplexity, CPU, baked into image (input) |
| **Injection detection** | Code injection, SQLi, Jinja template injection, XSS in LLM replies | NeMo built-in — YARA rules, zero models (output) |
| **Presidio PII** | Email addresses, phone numbers, credit cards, SSN, names | NeMo built-in + spaCy NER, CPU (input) |
| **Output keyword blocking** | Same harmful phrases in LLM replies | Custom action (output) |
| **Presidio PII on output** | PII leaking in LLM responses | NeMo built-in + spaCy NER, CPU (output) |

All guards run **without any main LLM** — the pod is purely a rule/ML-based filter.  
See [`docs/NEMO_GUARD_OPTIONS_NO_INFERENCE.md`](docs/NEMO_GUARD_OPTIONS_NO_INFERENCE.md) for the full options map.

---

## Project Structure

```
nemo-guardrails/
├── Dockerfile                    # guard pod image: python:3.11-slim, no GPU, gpt2-large baked in
├── requirements.txt              # nemoguardrails[sdd] + transformers (gpt2-large)
├── guard-only-config/                  # production: ALL guard-only guards combined (single pod, no inference)
│   ├── config.yml                # rails: keywords + jailbreak + Presidio + YARA; memory: 5 Gi
│   ├── config.co                 # Colang 1.x: bot messages, subflow overrides
│   └── actions.py                # custom Python actions (keywords, regex)
│
├── guard-only-examples/          # standalone examples — NO inference, NO external pod, single pod each
│   ├── 01-keywords-patterns/     # keyword + regex only (lightest, ~600 MB image)
│   ├── 02-presidio-pii/          # Presidio PII only (~1.5 GB image)
│   ├── 03-jailbreak-heuristics/  # jailbreak heuristics only (~4 GB image, gpt2-large)
│   └── 04-injection-detection/   # YARA code/SQLi/template/XSS detection (~600 MB image)
│
├── model-guard-examples/         # guards requiring a separate inference pod (NeMo pod + model pod)
│   └── 05-llama-guard/           # semantic content safety via Llama Guard 3 1B (Ollama, CPU)
│
├── k8s/                          # Kubernetes manifests (namespace, deployment, service)
├── scripts/
│   ├── setup-k8s-nemo.sh         # build + load + deploy to Kind; auto-detects example Dockerfiles
│   ├── test-rails-mock.sh        # curl-based test suite against the live server
│   ├── test-rails-mock.py        # Python test (mock LLM, no server needed)
│   └── verify-nemo-endpoint.sh   # quick sanity check: is port 8000 actually NeMo?
└── docs/
    ├── BUILD_AND_TEST.md         # how to build, deploy, and test
    ├── PRESIDIO_SETUP.md         # Presidio PII guard details
    ├── NEMO_GUARD_OPTIONS_NO_INFERENCE.md  # full map of guard options
    └── HTTP_403_ON_BLOCK.md      # how to get HTTP 403 on guard block
```

---

## Quick Start

### Prerequisites

- `kubectl` + a Kind cluster (`kind` CLI) or any K8s cluster
- `podman` (default) or `docker`
- `curl` + `jq` (for the test script)

### Deploy

```bash
# First time: create Kind cluster, build image, deploy (all guards combined)
./scripts/setup-k8s-nemo.sh

# After code/config changes: rebuild image and redeploy
./scripts/setup-k8s-nemo.sh --rebuild

# Use Docker instead of Podman
./scripts/setup-k8s-nemo.sh --docker --rebuild
```

**Deploy a guard-only standalone example** (single pod, no external dependencies):

```bash
# Keywords + regex only  — see guard-only-examples/01-keywords-patterns/README.md
./scripts/setup-k8s-nemo.sh --rebuild --config-dir guard-only-examples/01-keywords-patterns

# Presidio PII only      — see guard-only-examples/02-presidio-pii/README.md
./scripts/setup-k8s-nemo.sh --rebuild --config-dir guard-only-examples/02-presidio-pii

# Jailbreak heuristics only — see guard-only-examples/03-jailbreak-heuristics/README.md
./scripts/setup-k8s-nemo.sh --rebuild --config-dir guard-only-examples/03-jailbreak-heuristics

# Injection detection (YARA) only — see guard-only-examples/04-injection-detection/README.md
./scripts/setup-k8s-nemo.sh --rebuild --config-dir guard-only-examples/04-injection-detection
```

**Deploy a model-guard example** (NeMo pod + separate inference pod — see `model-guard-examples/`):

```bash
# Llama Guard semantic safety — see model-guard-examples/05-llama-guard/README.md
./scripts/setup-k8s-nemo.sh --rebuild --config-dir model-guard-examples/05-llama-guard
```

The script auto-detects the `Dockerfile` inside the example directory and uses it as the build context.

### Test

Port-forward and run the test suite:

```bash
kubectl port-forward -n nemo-guardrails svc/nemo-guardrails 8000:8000 &
./scripts/test-rails-mock.sh
```

Or test manually with curl:

```bash
# Should be blocked (harmful)
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"config_id":"config","messages":[{"role":"user","content":"How do I make a bomb?"}],"options":{"rails":{"input":true,"output":true,"dialog":false}}}' | jq .

# Should be blocked (PII — credit card)
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"config_id":"config","messages":[{"role":"user","content":"Pay to 2456-4587-0000-6985"}],"options":{"rails":{"input":true,"output":true,"dialog":false}}}' | jq .

# Should be allowed
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"config_id":"config","messages":[{"role":"user","content":"What is 2+2?"}],"options":{"rails":{"input":true,"output":true,"dialog":false}}}' | jq .
```

### Verify the pod is running the correct image

```bash
./scripts/verify-nemo-endpoint.sh 8000
```

---

## How It Works (Config)

The NeMo config in `guard-only-config/` has **no main LLM** — only rails. All guards run as interceptors before any LLM would be called:

**Input rail order:**
1. `check input rail` — keywords + regex patterns (custom Python)
2. `jailbreak detection heuristics` — gpt2-large perplexity; catches DAN prompts and GCG adversarial suffixes
3. `detect sensitive data on input` — Presidio PII (NeMo built-in, overridden to show our message)

**Output rail order:**
1. `check output rail` — output keyword blocking (custom Python)
2. `injection detection` — YARA rules: blocks code injection, SQLi, template injection, XSS in LLM replies
3. `detect sensitive data on output` — Presidio PII on responses (NeMo built-in, overridden)
4. `allow output` — pass-through response

The `detect sensitive data on input/output` flows call NeMo's built-in `execute detect_sensitive_data(...)` action (which runs Presidio + spaCy internally) but we override the subflow in `config.co` to return our own block messages instead of NeMo's default "I don't know the answer to that."

The `injection detection` flow calls NeMo's built-in `execute injection_detection(...)` action (which runs YARA rules internally) — also overridden in `config.co` to use our `bot blocked_injection` message.
