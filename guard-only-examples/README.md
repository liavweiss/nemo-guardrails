# Guard-Only Examples

**No inference. No external model service. Single pod.**

Each directory is a minimal, self-contained NeMo Guardrails config demonstrating one guard capability in isolation. Every example runs as a **single pod** with no GPU and no external dependencies — pure rule-based or lightweight CPU-only ML baked into the image.

For the **production config** (all guards combined, still guard-only), see [`../guard-only-config/`](../guard-only-config/).  
For guards that require a **separate inference pod** (e.g. Llama Guard), see [`../model-guard-examples/`](../model-guard-examples/).

| Example | Capability | Single pod? | Extra deps |
|---------|-----------|-------------|------------|
| [`01-keywords-patterns/`](01-keywords-patterns/) | Keyword block list + regex patterns | ✅ Yes | None (base install) |
| [`02-presidio-pii/`](02-presidio-pii/) | Presidio PII detection (email, phone, card, SSN) | ✅ Yes | `nemoguardrails[sdd]` + spaCy model |
| [`03-jailbreak-heuristics/`](03-jailbreak-heuristics/) | Perplexity-based jailbreak detection (gpt2-large) | ✅ Yes | `transformers` + `torch` (CPU) |
| [`04-injection-detection/`](04-injection-detection/) | YARA-based code/SQLi/template/XSS detection in output | ✅ Yes | `nemoguardrails[jailbreak]` (yara-python) |

See [`../docs/NEMO_GUARD_OPTIONS_NO_INFERENCE.md`](../docs/NEMO_GUARD_OPTIONS_NO_INFERENCE.md) for the full options map.
