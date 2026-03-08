# Model-Guard Examples

**Requires a separate inference pod alongside the NeMo guard pod.**

Each directory here demonstrates a guard that uses a **small dedicated model** for semantic safety classification. Unlike the guard-only examples, these require a second K8s pod (a model server) that the NeMo pod calls via HTTP.

The NeMo pod itself still contains **no main application LLM** — it only calls the small guard model. This is a different tier from the single-pod guard-only examples, but it is still "no main inference".

For guards that need **no external model at all**, see [`../guard-only-examples/`](../guard-only-examples/).  
For the **production config** (all guard-only guards combined), see [`../guard-only-config/`](../guard-only-config/).

| Example | Capability | Architecture | Model size |
|---------|-----------|--------------|------------|
| [`05-llama-guard/`](05-llama-guard/) | Semantic content safety (safe/unsafe + categories) | NeMo pod + Ollama pod | Llama Guard 3 1B (~700 MB quantized) |

See [`../docs/NEMO_GUARD_OPTIONS_NO_INFERENCE.md`](../docs/NEMO_GUARD_OPTIONS_NO_INFERENCE.md) for the full options map.
