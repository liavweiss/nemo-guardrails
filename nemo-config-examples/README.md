# NeMo Config Examples

Each directory contains a minimal, focused NeMo Guardrails config that demonstrates one guard capability in isolation. These are for **learning and testing** individual capabilities.

For the **production config** (all guards combined), see [`../nemo-config/`](../nemo-config/).

| Example | Capability | Extra deps |
|---------|-----------|------------|
| [`01-keywords-patterns/`](01-keywords-patterns/) | Keyword block list + regex patterns | None (base install) |
| [`02-presidio-pii/`](02-presidio-pii/) | Presidio PII detection (email, phone, card, SSN) | `nemoguardrails[sdd]` + spaCy model |
| [`03-jailbreak-heuristics/`](03-jailbreak-heuristics/) | Perplexity-based jailbreak detection (GPT-2 large) | `transformers` + `torch` (CPU) |
| [`04-injection-detection/`](04-injection-detection/) | YARA-based code/SQLi/template/XSS detection in output | `nemoguardrails[jailbreak]` (yara-python) |

See [`../docs/NEMO_GUARD_OPTIONS_NO_INFERENCE.md`](../docs/NEMO_GUARD_OPTIONS_NO_INFERENCE.md) for the full options map.
