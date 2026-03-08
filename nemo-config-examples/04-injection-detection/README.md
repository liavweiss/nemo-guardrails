# 04 — Injection Detection (YARA)

Detects malicious content injected into LLM **output** using YARA rules — zero models, zero GPU, pure rule matching.

## What it detects

| Injection type | What it catches | Risk |
|---|---|---|
| `code` | Python, shell, and other code injection patterns | LLM output passed to a code interpreter |
| `sqli` | SQL injection syntax (`SELECT`, `DROP`, `--` comments, etc.) | LLM output passed to a database |
| `template` | Jinja2 / template injection (`{{ }}`, `{% %}`) | LLM output rendered in a web template |
| `xss` | Cross-site scripting (`<script>`, `onload=`, etc.) | LLM output rendered in a browser / HTML |

## Why this matters at the gateway layer

When NeMo runs as a guard in the [gateway-api-inference-extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension) BBR pipeline, it intercepts LLM responses before they reach downstream consumers. If an attacker can make an LLM produce a SQLi or XSS payload in its response, YARA catches it here — before it reaches a database or browser.

## Dependencies

```bash
pip install nemoguardrails[jailbreak]==0.20.0
# [jailbreak] installs yara-python only — no model downloads, no GPU, ~5 MB
```

## Deploy to K8s (standalone guard pod)

```bash
./scripts/setup-k8s-nemo.sh --rebuild --config-dir nemo-config-examples/04-injection-detection
kubectl port-forward -n nemo-guardrails svc/nemo-guardrails 8000:8000
```

The script auto-detects the `Dockerfile` in this directory. Lightest image after `01-keywords-patterns` (~600 MB, no models).

## Run locally (without K8s)

```bash
pip install nemoguardrails[jailbreak]==0.20.0
nemoguardrails server --config . --port 8000
```

## Test with curl

Injection detection is an **output rail** — it inspects the **assistant message**, not the user message. Include a mock assistant reply with injected content:

```bash
# Should be blocked (SQLi in assistant reply)
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"config_id":"config","messages":[
    {"role":"user","content":"Show me the query"},
    {"role":"assistant","content":"Sure: SELECT * FROM users WHERE id=1; DROP TABLE users;--"}
  ],"options":{"rails":{"input":false,"output":true,"dialog":false}}}' | jq .

# Should be blocked (XSS in assistant reply)
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"config_id":"config","messages":[
    {"role":"user","content":"Give me a greeting"},
    {"role":"assistant","content":"Hello! <script>alert(document.cookie)</script>"}
  ],"options":{"rails":{"input":false,"output":true,"dialog":false}}}' | jq .

# Should be allowed (safe reply)
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"config_id":"config","messages":[
    {"role":"user","content":"What is 2+2?"},
    {"role":"assistant","content":"2+2 equals 4."}
  ],"options":{"rails":{"input":false,"output":true,"dialog":false}}}' | jq .
```

## `action` options

| Value | Behavior |
|---|---|
| `reject` (default) | Block the response with `bot blocked_injection` message |
| `omit` | Strip the injected content and return the sanitized response |
