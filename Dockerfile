# NeMo Guardrails server for K8s — guards only, no LLM, no API key.
# Base image from Docker Hub; if you get "i/o timeout", check network or use a registry mirror.
FROM python:3.11-slim

WORKDIR /app

# Build deps for annoy (C++ extension used by nemoguardrails)
RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ \
    gcc \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Install remaining deps. [sdd] = Presidio PII (presidio-analyzer, presidio-anonymizer, spacy)
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

# NeMo config directory (override with: docker build --build-arg CONFIG_DIR=nemo-config-examples/02-presidio-pii)
ARG CONFIG_DIR=nemo-config
COPY ${CONFIG_DIR} /config

EXPOSE 8000

# 0.20.x no longer has --host; server binds to 0.0.0.0 by default in container
CMD ["nemoguardrails", "server", "--config", "/config", "--port", "8000"]
