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

## What the POC Already Has (No Inference)

From your current setup (`nemo-config/`, `guardrails_k8s`):

- **Keyword blocking** – Block list of phrases (e.g. harmful terms) on input and output.
- **Pattern / regex** – SSN-like patterns, card numbers, “my password is …”, API key patterns.
- **Message length** – Reject overly long input.

All of this is **custom actions in Python**: no LLM, no GPU, minimal footprint. This is the baseline.

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

### 1. No inference (rule-based / light ML, CPU-only)

Suitable for a lightweight guard-only pod.

| Option | What it is | NVIDIA doc | Notes |
|--------|------------|------------|--------|
| **Custom actions (keywords, regex)** | What you have: Python actions with block lists and patterns. | Custom actions, Colang flows | Already in your POC. Can extend with more lists/patterns. |
| **Presidio PII (sensitive data)** | NER-based detection (e.g. spaCy) + optional masking. **No LLM.** | [Presidio Integration](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/community/presidio.html) | CPU-only. Detect or mask PERSON, EMAIL, PHONE_NUMBER, SSN, etc. Install: `pip install nemoguardrails[sdd]` + `python -m spacy download en_core_web_lg`. |
| **Jailbreak heuristics (perplexity)** | Length/perplexity and prefix/suffix perplexity. Uses a **small fixed model (e.g. GPT-2)** only to compute perplexity, not to “answer”. | [Jailbreak Detection](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#jailbreak-detection) | Can run in-process (needs `transformers`, `torch`) or via a separate [jailbreak heuristics server](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/jailbreak-detection-heuristics/README.html). Small model (e.g. GPT-2) can run on CPU. |
| **Injection detection** | YARA rules on **output**: code (Python), SQLi, template (Jinja), XSS. Reject or omit. **No LLM.** | [Injection Detection](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#injection-detection) | Rule-based. Good when LLM output is passed to code/DB/HTML. `pip install nemoguardrails[jailbreak]`. |

So today, **without adding any “inference” in the sense of a chat LLM**, you can add:

- **Presidio** – Better, configurable PII (detect/mask) on input and/or output.
- **Jailbreak heuristics** – Perplexity-based jailbreak detection (small model for perplexity only; still “guard only”, no chat).
- **Injection detection** – YARA-based detection of code/SQLi/template/XSS in **output** (no LLM).

---

### 2. Separate small “guard” model (no main LLM; guard pod can stay guard-only)

These use a **dedicated** safety/topic model. That model can be small and run on CPU (e.g. quantized) so the **guard pod still does not run your main inference LLM**.

| Option | What it is | NVIDIA doc | Lightweight? |
|--------|------------|------------|--------------|
| **Llama Guard** | Meta’s 7B content moderation model. Input/output “safe/unsafe” + categories. | [Llama-Guard Integration](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/community/llama-guard.html) | 7B; can be quantized (e.g. GGUF) for CPU. Heavier than rules but still “one small model for guard only”. |
| **Content safety (Nemotron / Llama Guard 3 / ShieldGemma)** | Dedicated content-safety models. | [Content Safety](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#content-safety) | Typically 8B-class; usually need GPU or strong CPU. |
| **Topic control** | Dedicated topic model (e.g. “on-topic” vs “off-topic”). | [Topic Safety](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#topic-safety) | Same idea: separate model, no main inference. |

If you introduce one of these, the **guard pod** would run only that small model (or call an external service), not your main application LLM — so you still keep “no inference” in the sense of “no main inference in the guard pod”.

---

### 3. Uses the main LLM (avoid for guard-only pod)

These **require an LLM** to be configured and called by NeMo (e.g. for prompts). Not suitable if the guard pod must stay “no inference”.

| Option | Why it needs an LLM |
|--------|----------------------|
| **Self-check input / self-check output** | They **prompt an LLM** (“Is this input/output allowed?”). [Guardrail catalog](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#llm-self-checking). |
| **Self-check facts / hallucination** | Same: LLM is called to verify facts or hallucinations. |
| **Canonical form / next step / generate_bot_message** | Core dialog flow; all use the main LLM. |

So: for a **guard-only, no-inference** design, **do not** use self-check flows or other flows that call the main LLM. Use only:

- Custom actions (keywords, regex, length), **and/or**
- Presidio (PII), **and/or**
- Jailbreak heuristics (perplexity), **and/or**
- A separate small guard model (Llama Guard, etc.) if you want to add “smarter” guards without running the main app LLM in the guard pod.

---

## Recommended Next Steps (Aligned with NVIDIA Docs)

1. **Stay rule-based first (no extra deps in guard pod)**  
   - Extend your existing custom actions: more keywords, more regexes, more patterns (e.g. PII-like, secrets).  
   - Still no inference, minimal footprint.

2. **Add Presidio PII (still no LLM)**  
   - Follow [Presidio Integration](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/community/presidio.html).  
   - In `config.yml`: `rails.config.sensitive_data_detection` for input/output; add flows `detect sensitive data on input/output` or `mask sensitive data on input/output`.  
   - Install `nemoguardrails[sdd]` and spaCy model; runs on CPU.

3. **Optionally add jailbreak heuristics**  
   - Add flow `jailbreak detection heuristics` and configure `jailbreak_detection` (e.g. `server_endpoint` or in-process).  
   - Uses a small model (e.g. GPT-2) only for perplexity — guard pod still does not run your main LLM.

4. **If you want “smarter” guards without main inference**  
   - Consider **Llama Guard** (or similar) as a **separate** small model: run it in the guard pod or in a separate microservice, and point NeMo at it.  
   - NeMo docs: add a `llama_guard` (or content_safety) model in `config.yml` and use `llama guard check input` / `llama guard check output` flows.  
   - Keeps “no inference” in the sense of “no main application LLM”; the guard pod only runs the guard model.

---

## Summary Table (Quick Reference)

| Capability           | Inference?              | Lightweight? | Official doc |
|----------------------|-------------------------|-------------|--------------|
| Keywords / patterns  | No                      | Yes         | Custom actions |
| Presidio PII         | No (NER/spaCy)          | Yes (CPU)   | [Presidio](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/community/presidio.html) |
| Jailbreak heuristics | Small model (perplexity only) | Yes (CPU possible) | [Jailbreak](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#jailbreak-detection) |
| Llama Guard          | Separate 7B guard model | Quantized CPU possible | [Llama Guard](https://docs.nvidia.com/nemo/guardrails/latest/user-guides/community/llama-guard.html) |
| Injection detection (YARA) | No (rule-based)     | Yes            | [Injection detection](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#injection-detection) |
| Self-check input/output | **Uses main LLM**   | No (needs LLM) | [Guardrail catalog](https://docs.nvidia.com/nemo/guardrails/latest/configure-rails/guardrail-catalog.html#self-check-input) |

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
