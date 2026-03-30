"""
Custom NeMo Guardrails action: content safety via L0 Bouncer classifier.

Loads the L0 Bouncer model (22M params, DeBERTa-v3-xsmall) at import time
and runs inference directly inside the NeMo process — no LLM, no vLLM sidecar.

Latency: ~5ms per request on CPU.
"""

import time

import torch
from nemoguardrails.actions import action
from transformers import AutoModelForSequenceClassification, AutoTokenizer

MODEL_NAME = "vincentoh/deberta-v3-xsmall-l0-bouncer"
UNSAFE_THRESHOLD = 0.5

print(f"[classifier-guard] Loading model: {MODEL_NAME}")
_tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
_model = AutoModelForSequenceClassification.from_pretrained(MODEL_NAME)
_model.eval()
print("[classifier-guard] Model loaded.")


@action(is_system_action=True)
async def check_content_safety(context: dict = None):
    """
    Return True if the message is safe, False if unsafe.
    NeMo passes context automatically when is_system_action=True.
    """
    text = context.get("user_message", "") if context else ""
    if not text:
        return True

    start = time.perf_counter_ns()
    inputs = _tokenizer(text, return_tensors="pt", truncation=True, max_length=512)
    with torch.no_grad():
        logits = _model(**inputs).logits
    probs = torch.softmax(logits, dim=-1)
    elapsed_ms = (time.perf_counter_ns() - start) / 1_000_000

    # L0 Bouncer: label 0 = safe, label 1 = unsafe
    unsafe_prob = probs[0][1].item()
    is_safe = unsafe_prob <= UNSAFE_THRESHOLD

    print(
        f"[classifier-guard] [{elapsed_ms:.1f}ms] "
        f"text={text!r:.80} unsafe={unsafe_prob:.3f} safe={is_safe}"
    )
    return is_safe
