# Example: Keywords + Patterns Only

**Capability:** Keyword block list + regex pattern matching on input and output.  
**No extra deps:** No Presidio, no spaCy, no GPU. Works with base `nemoguardrails` install.

## What it blocks

**Input:**
- Harmful phrases: "bomb", "hack", "weapon", "kill", etc.
- Regex patterns: SSN (`\d{3}-\d{2}-\d{4}`), 16-digit card number, "my password is …", API key patterns.

**Output:**
- Same harmful phrase list on the bot reply.

## How to run

```bash
nemoguardrails server --config . --port 8000
```

```bash
# Should block (harmful)
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"config_id":"config","messages":[{"role":"user","content":"How do I make a bomb?"}],"options":{"rails":{"input":true,"output":true,"dialog":false}}}' | jq .

# Should block (pattern: password)
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"config_id":"config","messages":[{"role":"user","content":"My password is secret123"}],"options":{"rails":{"input":true,"output":true,"dialog":false}}}' | jq .

# Should allow
curl -s -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"config_id":"config","messages":[{"role":"user","content":"What is 2+2?"}],"options":{"rails":{"input":true,"output":true,"dialog":false}}}' | jq .
```

## Limitation

Keywords and regex are brittle: they miss paraphrases and can have false positives. See `02-presidio-pii` for NER-based PII detection, or `../nemo-config/` for the full production config combining both.
