# Standalone image for 04-injection-detection: YARA-based code/SQLi/template/XSS detection.
# Lightest detection guard after keywords: zero models, pure rule-based, ~600 MB image.
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    g++ gcc python3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
# [jailbreak] = yara-python only; no models, no GPU, no heavy downloads
RUN pip install --no-cache-dir -r requirements.txt

# Config is in the same directory; build context = this example directory.
COPY . /config

EXPOSE 8000
CMD ["nemoguardrails", "server", "--config", "/config", "--port", "8000"]
