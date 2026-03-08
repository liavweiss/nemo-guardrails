# Getting HTTP 403 When a Guard Blocks

By default, **`nemoguardrails server`** returns **200 OK** with the block message in the response body (e.g. `messages[0].content` = "I cannot help with that request..."). So you must inspect the body to know if the request was blocked.

If you want an **HTTP 403 Forbidden** when a guard blocks (so clients can rely on status code), you have two options.

---

## Option 1: Use the custom server that returns 403 (recommended)

A small wrapper server is provided that uses your NeMo config and returns **403** when the guard blocks, and **200** when it allows.

**Run it instead of `nemoguardrails server`:**

```bash
# From the nemo-guardrails repo root (where guard-only-config/ lives)
pip install nemoguardrails uvicorn fastapi
python scripts/server_403.py
```

Server listens on `0.0.0.0:8000` by default. Override with `PORT` and `CONFIG_DIR`:

```bash
CONFIG_DIR=/config PORT=8000 python scripts/server_403.py
```

**Behavior:**

- **POST /v1/chat/completions** – Same request/response shape as the official NeMo server.
  - If the guard **allows** (response content is "Request allowed.") → **200 OK** with JSON body.
  - If the guard **blocks** (any other assistant content) → **403 Forbidden** with the same JSON body (so the block message is still in `messages[0].content`).
- **GET /v1/rails/configs** – Returns `[{"id": "config"}]`.
- **GET /** – Health: `{"status": "ok"}`.

**Docker:** To use this in your image, change the Dockerfile CMD to run `server_403.py` instead of `nemoguardrails server`, and ensure `CONFIG_DIR` points at your config (e.g. `/config`). Add `uvicorn` and `fastapi` to your requirements if not already present.

---

## Option 2: Use BBR in front of NeMo

When the request goes through **BBR** (gateway-api-inference-extension) with the NeMo guardrail plugin, BBR already returns **403** (and 500 on guard errors) via Envoy’s ImmediateResponse. So you get 403 from the gateway without changing the NeMo server.

---

## Summary

| Setup | When guard blocks |
|-------|--------------------|
| **Stock `nemoguardrails server`** | 200 OK, block message in body |
| **Custom `scripts/server_403.py`** | **403 Forbidden**, block message in body |
| **BBR + NeMo plugin** | **403 Forbidden** from Envoy |

To get 403 from “NeMo itself”, run **Option 1** (`server_403.py`) instead of the stock server.
