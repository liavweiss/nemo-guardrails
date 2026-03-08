# Example: Presidio PII Detection Only

**Capability:** NER-based PII detection on input and output using Microsoft Presidio + spaCy.  
**Requires:** `nemoguardrails[sdd]` + `python -m spacy download en_core_web_lg` (CPU, no GPU).

## What it detects

Entities configured (in `config.yml`):

| Entity | Example |
|--------|---------|
| `EMAIL_ADDRESS` | john.doe@example.com |
| `PHONE_NUMBER` | 054-788-9588 |
| `CREDIT_CARD` | 2456-4587-0000-6985 |
| `US_SSN` | 123-45-6789 |
| `PERSON` | "My name is John Smith" |

Input: **blocked** with a clear message.  
Output: **blocked** if the LLM reply leaks PII.

## Key insight: subflow override

NeMo's built-in `detect sensitive data on input` calls `bot inform answer unknown` (→ "I don't know the answer to that.").  
We override the subflow in `config.co` to call `bot refuse to respond` instead — same Presidio action, custom message.

## Deploy to K8s (standalone guard pod)

```bash
./scripts/setup-k8s-nemo.sh --rebuild --config-dir guard-only-examples/02-presidio-pii
kubectl port-forward -n nemo-guardrails svc/nemo-guardrails 8000:8000
```

The script auto-detects the `Dockerfile` in this directory (includes spaCy model bake-in).

## Run locally (without K8s)

```bash
pip install nemoguardrails[sdd]
python -m spacy download en_core_web_lg
nemoguardrails server --config . --port 8000
```

```bash
# Should block (email)
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"config_id":"config","messages":[{"role":"user","content":"Contact me at john.doe@example.com"}],"options":{"rails":{"input":true,"output":true,"dialog":false}}}' | jq .

# Should block (credit card)
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"config_id":"config","messages":[{"role":"user","content":"Pay to 2456-4587-0000-6985"}],"options":{"rails":{"input":true,"output":true,"dialog":false}}}' | jq .

# Should allow
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"config_id":"config","messages":[{"role":"user","content":"What is 2+2?"}],"options":{"rails":{"input":true,"output":true,"dialog":false}}}' | jq .
```

## Masking instead of blocking

To mask PII (replace with labels like `[EMAIL]`) instead of blocking, change the flows in `config.yml`:

```yaml
input:
  flows:
    - mask sensitive data on input
output:
  flows:
    - mask sensitive data on output
    - allow output
```

Then the message is allowed through with PII replaced by labels.

---

## Alternative Approaches to PII Detection

### GLiNER (detect any custom entity type)

**What it is:** [GLiNER](https://github.com/urchade/GLiNER) (Generalist Lightweight model for Named Entity Recognition) is a small NER model (~100 MB) that can detect **any entity label you define** — not just the fixed Presidio list. You could detect `"product_code"`, `"internal_id"`, `"passport_number"`, or any domain-specific entity without retraining.

**Key difference from Presidio:**

| | Presidio | GLiNER |
|---|---|---|
| Entity types | Fixed list (EMAIL, PHONE, SSN, etc.) | Any label you define as a string |
| Model | spaCy `en_core_web_lg` (~700 MB) | GLiNER model (~100 MB) |
| Deployment | Embedded in NeMo pod | Requires a **separate GLiNER server pod** |
| Custom entities | Add recognizers in code | Just add a label string in config |

**NeMo built-in flows:**
```colang
gliner detect pii on input
gliner detect pii on output
gliner mask pii on input      # mask instead of block
gliner mask pii on output
```

**Config example** (once a GLiNER server is running):
```yaml
rails:
  config:
    gliner:
      server_endpoint: "http://gliner-service:1235/v1/extract"
      threshold: 0.5
      input:
        entities:
          - "email address"
          - "phone number"
          - "passport number"       # custom — not in Presidio
          - "internal employee id"  # domain-specific
      output:
        entities:
          - "email address"
          - "credit card number"
  input:
    flows:
      - gliner detect pii on input
  output:
    flows:
      - gliner detect pii on output
      - allow output
```

**GLiNER server** (runs as a separate K8s pod, CPU-only):
```bash
pip install gliner-spacy gliner
# NeMo provides a built-in GLiNER server:
python -m nemoguardrails.library.gliner.server --port 1235
```

**When to use GLiNER over Presidio:**
- You need to detect domain-specific entities that Presidio doesn't support
- You want a smaller model footprint (~100 MB vs ~700 MB for spaCy)
- You want easy entity customization without writing custom recognizers

**Architecture:** Two pods — NeMo guard pod (unchanged) + GLiNER server pod. The NeMo pod makes HTTP calls to the GLiNER server, identical in structure to the Llama Guard architecture.

### Private AI (commercial cloud API)

[Private AI](https://www.private-ai.com/) is a commercial PII detection and anonymization API. NeMo has a built-in integration (`detect pii on input`, `mask pii on input`). No local model — pure API call. Suitable if you prefer a managed service over running your own model.
