# Model-Guard Examples

**Requires a separate inference pod alongside the NeMo guard pod.**

Each directory here demonstrates a guard that uses a **small dedicated model** for semantic safety classification. Unlike the guard-only examples, these require a second K8s pod (a model server) that the NeMo pod calls via HTTP.

The NeMo pod itself still contains **no main application LLM** — it only calls the small guard model. This is a different tier from the single-pod guard-only examples, but it is still "no main inference".

For guards that need **no external model at all**, see [`../guard-only-examples/`](../guard-only-examples/).  
For the **production config** (all guard-only guards combined), see [`../guard-only-config/`](../guard-only-config/).

| Example | Capability | Architecture | Model size | Latency (CPU) | Categories |
|---------|-----------|--------------|------------|---------------|------------|
| [`05-llama-guard/`](05-llama-guard/) | Semantic content safety (safe/unsafe + 13 categories) | Single pod, 2 containers (NeMo + vLLM) | Llama Guard 3 1B (~700 MB) | ~2-3 min | S1–S13: violence, hate, CSAM, CBRN, self-harm, elections, … |
| [`06-classifier-guard/`](06-classifier-guard/) | Binary content safety (safe/unsafe) | Single pod, 1 container (NeMo + in-process classifier) | L0 Bouncer DeBERTa-v3-xsmall (22M params) | ~5-10ms | Binary safe/unsafe (93% F1, 99% Recall) |

See [`../docs/NEMO_GUARD_OPTIONS_NO_INFERENCE.md`](../docs/NEMO_GUARD_OPTIONS_NO_INFERENCE.md) for the full options map.
