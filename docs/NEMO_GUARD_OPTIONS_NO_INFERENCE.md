# NeMo Guardrails: Advanced Options Without Inference

**Goal (from your manager):** Enhance request/response guards with more advanced capabilities while keeping the NeMo pod **(1) lightweight** and **(2) only guard — no inference** (no main LLM in the guard pod).

This doc is aligned with **official NVIDIA NeMo Guardrails documentation** and separates what works without any LLM from what uses a small/separate model or an LLM.

---

## Presidio PII vs Jailbreak Heuristics — They Do Different Work

**Presidio (PII / sensitive data)** and **jailbreak heuristics** do **not** do the same thing:

| | Presidio PII | Jailbreak heuristics |
|---|--------------|------------------------|
| **Purpose** | **Privacy / data exposure** – Find and optionally mask **personally identifiable information** (names, emails, phone numbers, SSN, credit cards, etc.) so it doesn’t leak in inputs or outputs. | **Safety / adversarial** – Detect **jailbreak attempts**: prompts designed to make an LLM ignore its safety rules (e.g. “ignore previous instructions”, prompt injection, GCG-style attacks). |
| **Question answered** | “Does this text contain sensitive personal data?” | “Does this input look like an attempt to break the model’s guardrails?” |
| **Typical action** | Block if PII present, or **mask** it and continue. | Block the request (reject the jailbreak attempt). |

So: **Presidio = protect user data (PII)**. **Jailbreak = protect the model from being manipulated.** You can use both; they address different risks.

---

## What is Implemented (No Inference)

From `guard-only-config/` (current state):

| Guard | Status | Notes |
|-------|--------|-------|
| **Keyword blocking** | ✅ Done | Block list of harmful phrases on input + output |
| **Pattern / regex** | ✅ Done | SSN, card numbers, "my password is …", API keys |
| **Presidio PII** | ✅ Done | EMAIL, PHONE, CREDIT_CARD, SSN, PERSON on input + output |
| **Jailbreak heuristics** | ✅ Done | gpt2-large baked into image, pod limit 5 Gi. DAN + GCG adversarial detection on input. |
| **Injection detection (YARA)** | ✅ Done | code/SQLi/template/XSS in LLM output. Zero models, yara-python only. |

All of the above: no LLM, no GPU, minimal footprint.

---

## Official NeMo Rail Types (NVIDIA Docs)

From [Guardrail Types](https://docs.nvidia.com/nemo/guardrails/latest/about/rail-types.html):

| Stage    | Rail type    | Typical use |
|----------|-------------|-------------|
| Before LLM | **Input**   | Content safety, jailbreak, topic control, PII |
| RAG      | **Retrieval** | Document/chunk filtering |
| Conversation | **Dialog** | Flow control |
| Tool use | **Execution** | Validate tool calls |
| After LLM | **Output**  | Response filtering, fact check, PII |

For a **guard-only, no-inference** pod we care mainly about **input** and **output** rails, and which of their mechanisms **do not** use the main LLM.

---

## Options by “Does It Need Inference?”

### 1. No inference (rule-based / light ML, single pod)

Suitable for a lightweight guard-only pod — no external service required.

| Option | What it is | NVIDIA doc | Notes |
|--------|------------|------------|--------|
| **Custom actions (keywords, regex)** | Python actions with block lists and patterns. | Custom actions, Colang flows | ✅ Implemented in `01-keywords-patterns/` |
| **Presidio PII (sensitive data)** | NER-based detection (spaCy) + optional masking. **No LLM.** | [Presidio Integration](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/community/presidio.html) | ✅ Implemented in `02-presidio-pii/`. CPU-only, embedded in pod. |
| **Jailbreak heuristics (perplexity)** | gpt2-large perplexity scoring. No LLM chat. | [Jailbreak Detection](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#jailbreak-detection) | ✅ Implemented in `03-jailbreak-heuristics/`. In-process or separate server. |
| **Injection detection (YARA)** | YARA rules on output: code, SQLi, template, XSS. **No LLM.** | [Injection Detection](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#injection-detection) | ✅ Implemented in `04-injection-detection/`. Zero models, rule-based. |

### 1b. Lightweight separate server (no main LLM; tiny dedicated service pod)

These require a **second pod** but that pod is tiny (no GPU, small model). The NeMo guard pod stays unchanged — it just makes HTTP calls. Both have NeMo built-in flows.

| Option | What it is | Replaces / Complements | Pod size |
|--------|------------|------------------------|----------|
| **GLiNER** | NER model — detects **any custom entity label** you define | Alternative/complement to Presidio PII | ~100 MB model |
| **Jailbreak detection model** | Snowflake Arctic Embed + Random Forest (trained on real jailbreak data) | Complement to jailbreak heuristics | ~300 MB embed + tiny RF |

**GLiNER** (`gliner detect pii on input/output`) — see [`02-presidio-pii/README.md`](../guard-only-examples/02-presidio-pii/README.md#alternative-approaches-to-pii-detection) for full config and rationale.
- Detects any label you define: `"passport number"`, `"internal employee id"`, or any domain-specific entity
- Requires a GLiNER server: `python -m nemoguardrails.library.gliner.server --port 1235`

**Jailbreak detection model** (`jailbreak detection model`) — see [`03-jailbreak-heuristics/README.md`](../guard-only-examples/03-jailbreak-heuristics/README.md#alternative-approach-jailbreak-detection-model-snowflake--random-forest) for full config and rationale.
- Uses `Snowflake/snowflake-arctic-embed-m-long` (~300 MB) + NVIDIA RF classifier (`snowflake.pkl`) from [NemoGuard-JailbreakDetect](https://huggingface.co/nvidia/NemoGuard-JailbreakDetect)
- Catches **semantically crafted** jailbreaks (natural language) that don't trigger perplexity anomalies; gpt2 catches GCG adversarial suffixes — use both for maximum coverage
- Requires a jailbreak detection server: `python -m nemoguardrails.library.jailbreak_detection.server --mode=model`

---

### 2. Separate small "guard" model (semantic safety — no main LLM)

These use a **dedicated content-safety model** in a separate pod. The NeMo guard pod calls it via HTTP — no model runs in the NeMo pod itself.

| Option | What it is | NVIDIA doc | Lightweight? |
|--------|------------|------------|--------------|
| **Llama Guard 3 1B** | Meta's content moderation model. Safe/unsafe + categories. | [Llama-Guard Integration](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/community/llama-guard.html) | 1B version: ~700 MB quantized. Runs on CPU in a separate pod via Ollama. |
| **Content safety (ShieldGemma 2B / Llama Guard 3 8B)** | Dedicated content-safety models. | [Content Safety](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#content-safety) | 2B-8B class; ShieldGemma 2B runs on CPU. |

> **Topic Safety** (`topic safety check input`) — ⚠️ **Requires a main LLM** (confirmed from source: calls `llm_call()` internally). It is NOT a guard-only option without configuring a dedicated LLM endpoint. Do not use in a strict no-inference pod.

If you introduce one of these, the **guard pod** calls the safety model via HTTP — it runs no model of its own. The safety model pod is the only thing that needs RAM.

---

### 3. Uses the main LLM (avoid for guard-only pod)

These **require an LLM** to be configured and called by NeMo. Not suitable if the guard pod must stay "no inference".

| Option | Why it needs an LLM |
|--------|----------------------|
| **Self-check input / self-check output** | They **prompt an LLM** ("Is this input/output allowed?"). [Guardrail catalog](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#llm-self-checking). |
| **Self-check facts / hallucination** | Same: LLM is called to verify facts or hallucinations. |
| **Topic Safety** (`topic safety check input`) | Calls `llm_call()` internally — confirmed from source code. **Cannot be used without a configured LLM endpoint.** |
| **Canonical form / next step / generate_bot_message** | Core dialog flow; all use the main LLM. |

So: for a **guard-only, no-inference** design, **do not** use self-check or topic-safety flows. Use only:

- Custom actions (keywords, regex), **and/or**
- Presidio / GLiNER (PII), **and/or**
- Jailbreak heuristics / jailbreak detection model (perplexity / embeddings), **and/or**
- Injection detection (YARA), **and/or**
- A separate small guard model (Llama Guard, etc.) if you want semantic safety without the main app LLM.

---

## Recommended Next Steps (Aligned with NVIDIA Docs)

1. ✅ **Custom actions (keywords, regex)** — Done. See `guard-only-examples/01-keywords-patterns/`.

2. ✅ **Presidio PII** — Done. Detects/blocks EMAIL, PHONE, CREDIT_CARD, SSN, PERSON on input and output.
   See `guard-only-examples/02-presidio-pii/`.
   **Alternative**: GLiNER for custom entity types — see `02-presidio-pii/README.md` for config.

3. ✅ **Jailbreak heuristics** — Done. gpt2-large baked into image, pod limit 5 Gi.
   See `guard-only-examples/03-jailbreak-heuristics/`.
   **Alternative/Complement**: Jailbreak detection model (Snowflake + RF, ~300 MB, requires a server) — see `03-jailbreak-heuristics/README.md` for config.

4. ✅ **Injection detection (YARA)** — Done. YARA rules on LLM output; catches code/SQLi/template/XSS.
   See `guard-only-examples/04-injection-detection/`.

5. **Llama Guard — Semantic content safety (separate guard model pod)**
   - Add `llama guard check input` flow, calling a Llama Guard 1B pod via Ollama.
   - Keeps "no inference" in the main NeMo pod; only the small guard model runs in a second pod.
   - Planned as `guard-only-examples/05-llama-guard/`.
   - Official doc: [Llama Guard](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/community/llama-guard.html)

> ⚠️ **Topic Safety** (`topic safety check input`) — requires a main LLM (`llm_call()` confirmed from source). Skip for a guard-only pod.

## Summary Table (Quick Reference)

| Capability | Inference? | Single pod? | Status | Official doc |
|------------|------------|-------------|--------|--------------|
| Keywords / patterns | No | Yes | ✅ Done | Custom actions |
| Presidio PII | No (NER/spaCy) | Yes (CPU) | ✅ Done | [Presidio](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/community/presidio.html) |
| GLiNER (custom entities) | No (NER model) | No (separate server) | 📖 Documented alt. | [GLiNER](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/community/gliner.html) |
| Jailbreak heuristics | Small model (gpt2, perplexity) | Yes (CPU, ~3 GB) | ✅ Done | [Jailbreak](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#jailbreak-detection) |
| Jailbreak detection model | Small model (Snowflake + RF) | No (separate server) | 📖 Documented alt. | [NemoGuard-JailbreakDetect](https://huggingface.co/nvidia/NemoGuard-JailbreakDetect) |
| Injection detection (YARA) | No (rule-based) | Yes | ✅ Done | [Injection detection](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#injection-detection) |
| Llama Guard 1B | Separate guard model | No (separate pod) | 🔜 Planned | [Llama Guard](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/community/llama-guard.html) |
| Topic Safety | **Uses main LLM** | No (needs LLM) | ⚠️ Requires LLM | [Topic Safety](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#topic-safety) |
| Self-check input/output | **Uses main LLM** | No (needs LLM) | ⚠️ Requires LLM | [Guardrail catalog](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#self-check-input) |

---

## Full List: Everything in the NeMo Guardrail Catalog (Official Docs)

The [Guardrail Catalog](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html) is the single reference for built-in and documented guardrails. Below is the **full list** of options from that catalog, grouped as in the docs. “No inference” means no main LLM; “Small/separate model” means a dedicated guard model (e.g. Llama Guard, perplexity model); “LLM” means uses the main conversational LLM.

### Core catalog (in order as in the doc)

| Category | Option | What it does | Inference? |
|----------|--------|--------------|------------|
| **LLM Self-Checking** | Self-check input | LLM decides if user input is allowed | **LLM** |
| | Self-check output | LLM decides if bot response is allowed | **LLM** |
| | Fact-checking | LLM checks bot response against retrieved chunks | **LLM** |
| | Hallucination detection | LLM detects hallucinated content in bot response | **LLM** |
| **NVIDIA models** | Content safety | Nemotron / Llama Guard 3 / ShieldGemma content moderation | Small/separate model |
| | Topic safety | Topic-control model (on-topic vs off-topic) | Small/separate model |
| **PII detection** | Built-in (Presidio) | Detect/mask PII (Presidio + spaCy NER) | **No inference** |
| | GLiNER | PII via GLiNER server (configurable entities) | External service / small model |
| **Threat detection** | Jailbreak (heuristics) | Perplexity-based jailbreak detection (length/perplexity, prefix/suffix) | Small model (e.g. GPT-2) for perplexity only |
| | Jailbreak (model-based) | Random-forest detector on embeddings (e.g. Snowflake) | Small/separate model |
| | **Injection detection** | YARA rules: code, SQLi, template, XSS injection in **output** | **No inference** (rule-based) |
| **Community** | AlignScore fact-checking | Fact-check bot output against context | Small/separate model |
| | Llama Guard | Content moderation (safe/unsafe + categories) | Small/separate model (7B) |
| | Patronus Lynx | RAG hallucination detection | Small/separate model |
| | Presidio PII | Same as built-in PII (documented again under Community) | **No inference** |

### Third-party APIs (external services; no LLM in your stack)

| Option | What it does |
|--------|--------------|
| ActiveFence | Content moderation API |
| AutoAlign | (Catalog entry) |
| Clavata | (Catalog entry) |
| Cleanlab | (Catalog entry) |
| GCP Text Moderation | Google Cloud moderation API |
| GuardrailsAI | Safety/hallucination API |
| Private AI | PII detection/masking (alternative to Presidio) |
| Fiddler | Safety and hallucination detection API |
| Prompt Security | Prompt / jailbreak protection |
| Pangea AI Guard | Moderation API |
| Trend Micro Vision One | AI application security |
| Cisco AI Defense | (Catalog entry) |

So **yes** — the options summarized earlier (Presidio, jailbreak, Llama Guard, self-check, content safety, topic safety, PII) plus **injection detection** (YARA, no inference) and the **third-party APIs** above are the full set of guard options documented in the NeMo Guardrail Catalog. The only one from the core catalog that was not called out before as “no inference” is **injection detection** (YARA-based; good for agentic/output: code, SQLi, template, XSS).

---

## Links to Official NVIDIA NeMo Docs

- [Guardrail types](https://docs.nvidia.com/nemo/guardrails/latest/about/rail-types.html)
- [Built-in actions](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/actions/built-in-actions.html)
- [Guardrail catalog](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html) (self-check, PII, jailbreak, content safety, topic safety)
- [Presidio (PII)](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/community/presidio.html)
- [Llama Guard](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/community/llama-guard.html)
- [Jailbreak detection](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#jailbreak-detection)

You can use this doc to “learn together” with your manager and to choose the next enhancements that keep the NeMo pod lightweight and guard-only, with no main inference.
