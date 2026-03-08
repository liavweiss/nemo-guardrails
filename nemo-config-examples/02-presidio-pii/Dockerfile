# Standalone image for 02-presidio-pii: Presidio PII detection (NER via spaCy).
# No torch, no GPU. CPU-only. ~1.5 GB image (spaCy en_core_web_lg model).
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ gcc python3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
# [sdd] = presidio-analyzer + presidio-anonymizer + spacy
RUN pip install --no-cache-dir -r requirements.txt
# Bake spaCy English NER model into image (required by Presidio for entity recognition)
RUN python -m spacy download en_core_web_lg

# Config is in the same directory; build context = this example directory.
COPY . /config

EXPOSE 8000
CMD ["nemoguardrails", "server", "--config", "/config", "--port", "8000"]
