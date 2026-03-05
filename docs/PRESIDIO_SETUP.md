# Presidio (PII) setup — step-by-step config

This config adds **Presidio** for PII detection on input and output.

## What was added

1. **config.yml**
   - `rails.config.sensitive_data_detection`: entities to detect (PERSON, EMAIL_ADDRESS, PHONE_NUMBER, CREDIT_CARD, US_SSN) and `score_threshold: 0.5` for input and output.
   - Input flows: `check input rail` (existing) → **`detect sensitive data on input`** (Presidio).
   - Output flows: `check output rail` (existing) → **`detect sensitive data on output`** (Presidio) → `allow output`.

2. **config.co**
   - `define bot refuse to respond` — message shown when Presidio detects PII: *"Please do not share personal or sensitive information (e.g. names, emails, phone numbers, SSN, credit cards) in your message."*

3. **requirements.txt**
   - `nemoguardrails[sdd]` so Presidio and spaCy are installed.

4. **Dockerfile**
   - After `pip install`, runs `python -m spacy download en_core_web_lg` so the image has the spaCy model for Presidio.

5. **Test**
   - `scripts/test-rails-mock.sh` has an extra case: user message containing an email → expect block with “do not share personal or sensitive”.


## Entities (config.yml)

You can change the list of entities. Presidio supports **many more** than the five in the example; the current config uses a small subset. Full reference: [Presidio Supported Entities](https://microsoft.github.io/presidio/supported_entities/).

### Global (language-agnostic)

| Entity | Description |
|--------|-------------|
| `PERSON` | Full person name |
| `EMAIL_ADDRESS` | Email address |
| `PHONE_NUMBER` | Telephone number |
| `CREDIT_CARD` | Credit card number (12–19 digits) |
| `CRYPTO` | Crypto wallet (e.g. Bitcoin address) |
| `DATE_TIME` | Dates, times, periods |
| `IBAN_CODE` | International Bank Account Number |
| `IP_ADDRESS` | IPv4 or IPv6 |
| `MAC_ADDRESS` | Network interface MAC address |
| `MEDICAL_LICENSE` | Medical license numbers |
| `URL` | Web URL |
| `LOCATION` | Cities, countries, regions, etc. |
| `NRP` | Nationality, religious or political group |

### USA

`US_SSN`, `US_BANK_NUMBER`, `US_DRIVER_LICENSE`, `US_ITIN`, `US_MBI`, `US_PASSPORT`

### UK

`UK_NHS`, `UK_NINO`

### Other regions

Spain (`ES_NIF`, `ES_NIE`), Italy (`IT_FISCAL_CODE`, `IT_DRIVER_LICENSE`, …), Poland (`PL_PESEL`), Singapore (`SG_NRIC_FIN`, `SG_UEN`), Australia (`AU_ABN`, `AU_TFN`, `AU_MEDICARE`, …), India (`IN_PAN`, `IN_AADHAAR`, …), Finland, Korea, Thailand.

Add any of these to `entities` in `config.yml` (input and/or output). You can also add **custom recognizers** (see Presidio docs).

Current example set: **input** — PERSON, EMAIL_ADDRESS, PHONE_NUMBER, CREDIT_CARD, US_SSN; **output** — same except US_SSN.

`score_threshold: 0.5` reduces false positives (default in Presidio is 0.2).

## Optional: mask instead of block

To **mask** PII and continue instead of blocking, use:

- `mask sensitive data on input` / `mask sensitive data on output` in the flows instead of `detect sensitive data on input` / `detect sensitive data on output`.

Then Presidio replaces detected PII with labels (e.g. `[EMAIL]`, `[PERSON]`) and the request is not refused.
