# guard-only-config: all guards combined — keywords, Presidio PII, jailbreak heuristics, YARA injection.
# Guards only, no LLM, no API key. Single pod, CPU-only, ~5 Gi RAM (gpt2-large + spaCy).
FROM python:3.11-slim

WORKDIR /app

# Build deps for annoy (C++ extension used by nemoguardrails)
RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ \
    gcc \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Install PyTorch CPU-only first (much smaller than the default CUDA build, ~250 MB vs ~2.5 GB).
# Jailbreak heuristics (perplexity via gpt2-large) needs torch; Presidio/NeMo do not need GPU.
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu

# Install remaining deps.
# [sdd]      = presidio-analyzer, presidio-anonymizer, spacy (Presidio PII)
# [jailbreak] = yara-python (YARA injection detection)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# Presidio needs spaCy English model for NER (PII detection)
RUN python -m spacy download en_core_web_lg

# Pre-bake gpt2-large for jailbreak heuristics so the pod works offline in K8s.
# NeMo loads this at module import time on first jailbreak-checked request;
# without baking, Kind pods (no outbound internet) hang and crash.
RUN python -c "\
from transformers import GPT2LMHeadModel, GPT2TokenizerFast; \
GPT2LMHeadModel.from_pretrained('gpt2-large'); \
GPT2TokenizerFast.from_pretrained('gpt2-large'); \
print('gpt2-large cached.')"

# Copy this directory (config files alongside the Dockerfile) into the image.
COPY . /config

EXPOSE 8000

# 0.20.x no longer has --host; server binds to 0.0.0.0 by default in container
CMD ["nemoguardrails", "server", "--config", "/config", "--port", "8000"]
