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

# Install deps (no GPU). [sdd] = Presidio PII (presidio-analyzer, presidio-anonymizer, spacy)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# Presidio needs spaCy English model for NER (PII detection)
RUN python -m spacy download en_core_web_lg

# NeMo config directory (override with: docker build --build-arg CONFIG_DIR=nemo-config-examples/02-presidio-pii)
ARG CONFIG_DIR=nemo-config
COPY ${CONFIG_DIR} /config

EXPOSE 8000

# 0.20.x no longer has --host; server binds to 0.0.0.0 by default in container
CMD ["nemoguardrails", "server", "--config", "/config", "--port", "8000"]
