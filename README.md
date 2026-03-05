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
| **Keyword blocking** | Harmful phrases: "bomb", "hack", "weapon", … | Custom action — block list |
| **Pattern / regex** | SSN format, 16-digit card numbers, "my password is …", API keys | Custom action — regex |
| **Presidio PII** | Email addresses, phone numbers, credit cards, SSN, names | NeMo built-in + spaCy NER (CPU) |
| **Output keyword blocking** | Same harmful phrases in LLM replies | Custom action on output |
| **Presidio PII on output** | PII leaking in LLM responses | NeMo built-in + spaCy NER (CPU) |

All guards run **without any main LLM** — the pod is purely a rule/ML-based filter.

---

## What's Next (Planned Guards)

See [`docs/NEMO_GUARD_OPTIONS_NO_INFERENCE.md`](docs/NEMO_GUARD_OPTIONS_NO_INFERENCE.md) for the full options map. The most immediate candidates:

- **Injection detection (YARA)** — detect code/SQLi/template/XSS in outputs. Zero-model, rule-based. Easy to add.
- **Jailbreak heuristics** — perplexity-based detection of adversarial prompts (uses GPT-2 for perplexity only, runs as a separate microservice).

---

## Project Structure

```
nemo-guardrails/
├── Dockerfile                    # builds the guard pod image (python:3.11-slim, no GPU)
├── requirements.txt              # nemoguardrails[sdd] + Presidio deps
├── nemo-config/                  # NeMo Guardrails configuration (single unified config)
│   ├── config.yml                # rails: input + output, Presidio entities, thresholds
│   ├── config.co                 # Colang 1.x: bot messages, subflow overrides
│   └── actions.py                # custom Python actions (keywords, regex, length)
├── k8s/                          # Kubernetes manifests (namespace, deployment, service)
├── kind-config.yaml              # Kind cluster config for local testing
├── scripts/
│   ├── setup-k8s-nemo.sh         # build + load image + deploy to Kind (Podman/Docker)
│   ├── test-rails-mock.sh        # curl-based test suite against the live server
│   ├── test-rails-mock.py        # Python test (mock LLM, no server needed)
│   └── verify-nemo-endpoint.sh   # quick sanity check: is port 8000 actually NeMo?
└── docs/
    ├── BUILD_AND_TEST.md         # how to build, deploy, and test
    ├── PRESIDIO_SETUP.md         # Presidio PII guard details
    ├── NEMO_GUARD_OPTIONS_NO_INFERENCE.md  # full map of guard options (no inference)
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
# First time: create Kind cluster, build image, deploy
./scripts/setup-k8s-nemo.sh

# After code/config changes: rebuild image and redeploy
./scripts/setup-k8s-nemo.sh --rebuild

# Use Docker instead of Podman
./scripts/setup-k8s-nemo.sh --docker --rebuild
```

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

The NeMo config in `nemo-config/` has **no main LLM** — only rails. All guards run as interceptors before any LLM would be called:

**Input rail order:**
1. `check input rail` — keywords + regex patterns (custom Python)
2. `detect sensitive data on input` — Presidio PII (NeMo built-in, overridden to show our message)

**Output rail order:**
1. `check output rail` — output keyword blocking (custom Python)
2. `detect sensitive data on output` — Presidio PII on responses (NeMo built-in, overridden)
3. `allow output` — pass-through response

The `detect sensitive data on input/output` flows call NeMo's built-in `execute detect_sensitive_data(...)` action (which runs Presidio + spaCy internally) but we override the subflow in `config.co` to return our own block messages instead of NeMo's default "I don't know the answer to that."
