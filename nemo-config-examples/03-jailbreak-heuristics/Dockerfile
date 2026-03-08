# Standalone image for 03-jailbreak-heuristics: perplexity-based jailbreak detection.
#
# WARNING: gpt2-large (~800 MB on disk, ~3 GB RAM at runtime) is baked into this image.
# Total image size: ~4 GB. Pod requires at least 4 Gi memory to run.
# NeMo explicitly warns: "NOT RECOMMENDED FOR PRODUCTION" for in-process use.
# For production: deploy a separate jailbreak server and configure server_endpoint.
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ gcc python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Install PyTorch CPU-only (~250 MB, much smaller than CUDA build)
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Pre-bake gpt2-large so the pod works offline in K8s (Kind has no outbound internet).
# NeMo's checks.py loads this at module import time on the first jailbreak-checked request.
RUN python -c "\
from transformers import GPT2LMHeadModel, GPT2TokenizerFast; \
GPT2LMHeadModel.from_pretrained('gpt2-large'); \
GPT2TokenizerFast.from_pretrained('gpt2-large'); \
print('gpt2-large cached.')"

# Config is in the same directory; build context = this example directory.
COPY . /config

EXPOSE 8000
CMD ["nemoguardrails", "server", "--config", "/config", "--port", "8000"]
