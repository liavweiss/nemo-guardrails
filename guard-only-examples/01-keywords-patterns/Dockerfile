# Standalone image for 01-keywords-patterns: keyword block list + regex patterns only.
# Lightest possible NeMo guard: no spaCy, no torch, no GPU. Base install only.
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ gcc python3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Config is in the same directory; build context = this example directory.
COPY . /config

EXPOSE 8000
CMD ["nemoguardrails", "server", "--config", "/config", "--port", "8000"]
