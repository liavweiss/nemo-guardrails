# 05-llama-guard NeMo pod — lightweight, no models baked in.
# This pod just runs the NeMo Guardrails server and calls Ollama via HTTP.
# All inference is done by the separate Ollama pod.
# Image size: ~600 MB (no torch, no spaCy, no gpt2, no YARA).
FROM python:3.11-slim

WORKDIR /app

# Build deps for annoy (C++ extension used by nemoguardrails)
RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ \
    gcc \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy config (config.yml, config.co, prompts.yml are in the same directory as this Dockerfile).
COPY . /config

EXPOSE 8000
CMD ["nemoguardrails", "server", "--config", "/config", "--port", "8000"]
