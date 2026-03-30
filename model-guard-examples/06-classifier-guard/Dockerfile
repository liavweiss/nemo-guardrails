# classifier-guard: NeMo Guardrails + L0 Bouncer (22M DeBERTa) in a single container.
# No vLLM sidecar needed — the classifier runs in-process on CPU.
# Expected image size: ~1.5 GB (torch-cpu + transformers + nemoguardrails + model).
# Expected latency: ~5-10ms per request.
FROM python:3.11-slim

WORKDIR /app

# Build deps for annoy (C++ extension used by nemoguardrails)
RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ \
    gcc \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Install PyTorch CPU-only first (~250 MB vs ~2.5 GB for CUDA build).
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-bake the L0 Bouncer model so the container works offline in K8s.
RUN python -c "\
from transformers import AutoModelForSequenceClassification, AutoTokenizer; \
AutoTokenizer.from_pretrained('vincentoh/deberta-v3-xsmall-l0-bouncer'); \
AutoModelForSequenceClassification.from_pretrained('vincentoh/deberta-v3-xsmall-l0-bouncer'); \
print('L0 Bouncer model cached.')"

# NeMo server scans --config for subdirectories, each becomes a config_id.
# /configs/config/ → config_id = "config"
# --default-config-id makes it the default so requests don't need to specify config_id.
COPY config.yml config.co actions.py /configs/config/

EXPOSE 8000

CMD ["nemoguardrails", "server", "--config", "/configs", "--default-config-id", "config", "--port", "8000"]
