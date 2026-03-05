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

## How to run

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
