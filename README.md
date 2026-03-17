# RenewIQ Backend

AI-powered insurance renewal backend built with FastAPI, SQLAlchemy, APScheduler, and LangGraph.
It handles policy lifecycle tracking and multi-channel customer outreach (SMS, WhatsApp, Email, Voice) for renewal workflows.

## Features

- FastAPI backend with OpenAPI docs
- PostgreSQL persistence with SQLAlchemy models
- Renewal workflow orchestration via LangGraph
- Multi-channel messaging integrations:
  - Twilio (SMS, WhatsApp, Call status)
  - SendGrid (Email send + inbound/event webhooks)
  - ElevenLabs (voice tooling)
- Scheduler for periodic renewal processing
- Standardized API response envelope for core APIs:
  - success
  - message
  - data
  - error

## Project Structure

```text
RenewIQ_Backend/
├─ insurance_agent/
│  ├─ app/
│  │  ├─ api/            # Core REST APIs
│  │  ├─ agent/          # LangGraph agent flow
│  │  ├─ models/         # SQLAlchemy models
│  │  ├─ tools/          # Channel integrations
│  │  ├─ webhooks/       # Twilio/SendGrid callback endpoints
│  │  ├─ config.py       # Environment-based settings
│  │  ├─ database.py     # DB session/engine wiring
│  │  └─ main.py         # FastAPI app entrypoint
│  ├─ alembic/           # DB migration scripts
│  ├─ requirements.txt
│  ├─ seed_data.py       # Schema/data bootstrap
│  ├─ verify_sendgrid.py # SendGrid verification utility
│  └─ testwhatsapp.py    # WhatsApp test utility
├─ icici_lombard_schema.sql
└─ backend.md            # API reference guide
```

## Prerequisites

- Python 3.10+
- PostgreSQL 13+
- A virtual environment tool (venv recommended)
- Twilio/SendGrid/OpenAI credentials for channel + AI features

## Quick Start

## 1) Create and activate virtual environment

Windows PowerShell:

```powershell
cd insurance_agent
python -m venv .venv
.\.venv\Scripts\Activate.ps1
```

## 2) Install dependencies

```powershell
pip install -r requirements.txt
```

## 3) Configure environment variables

Create file: `insurance_agent/.env`

Minimum required values:

```env
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/renewiq

# LLM (choose Azure OpenAI or OpenAI fallback)
AZURE_OPENAI_API_KEY=
AZURE_OPENAI_ENDPOINT=
AZURE_OPENAI_API_VERSION=2024-12-01-preview
AZURE_OPENAI_DEPLOYMENT_NAME=gpt-4o
OPENAI_API_KEY=

# Twilio
TWILIO_ACCOUNT_SID=
TWILIO_AUTH_TOKEN=
TWILIO_PHONE_NUMBER=

# SendGrid
SENDGRID_API_KEY=
SENDGRID_FROM_EMAIL=noreply@renewiq.app
SENDGRID_FROM_NAME=RenewIQ
SENDGRID_WEBHOOK_SIGNING_KEY=

# Optional
ELEVENLABS_API_KEY=
CORS_ALLOWED_ORIGINS=http://localhost:3000,http://localhost:8000
LOG_DIR=logs
MEDIA_BASE_URL=https://media.renewiq.app/calls
```

## 4) Prepare database

Option A: bootstrap schema + sample data:

```powershell
python seed_data.py
```

Option B: schema only:

```powershell
python seed_data.py --schema-only
```

Option C: use Alembic migrations:

```powershell
alembic upgrade head
```

## 5) Run API server

From `insurance_agent` directory:

```powershell
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

## 6) Verify service

- API root: http://localhost:8000/
- Health: http://localhost:8000/health
- Swagger: http://localhost:8000/docs
- ReDoc: http://localhost:8000/redoc

## API Overview

Core routes:

- Health: `/`, `/health`
- Customers: `/customers/*`
- Policies: `/policies/*`
- Notifications: `/notifications/*`
- Agent: `/agent/*`
- Webhooks: `/webhooks/*`

Detailed route-by-route documentation lives in `backend.md` at the repository root.

## Response Format (Core APIs)

Success example:

```json
{
  "success": true,
  "message": "Customer created",
  "data": {},
  "error": null
}
```

Error example:

```json
{
  "success": false,
  "message": "Validation failed",
  "data": null,
  "error": {
    "code": "VALIDATION_ERROR",
    "details": {}
  }
}
```

Note: Twilio-compatible webhook success responses may be XML/plain text by design.

## Useful Scripts

Run SendGrid verification test:

```powershell
python verify_sendgrid.py --to your_email@example.com
```

Run WhatsApp test script:

```powershell
python testwhatsapp.py
```

## Troubleshooting

## Database connection fails

- Ensure PostgreSQL is running.
- Verify `DATABASE_URL` is not placeholder text.
- Confirm database/user/password are valid.

## 422 validation errors

- Check request body/path/query types in Swagger (`/docs`).
- Ensure UUID/date formats are valid.

## Twilio webhook signature errors (403)

- Verify `TWILIO_AUTH_TOKEN`.
- Ensure webhook URL in Twilio exactly matches deployed endpoint.

## SendGrid event signature errors (403)

- Verify `SENDGRID_WEBHOOK_SIGNING_KEY` and webhook endpoint configuration.

## Health endpoint reports degraded

- Review `db`, `scheduler`, and `openai` fields in `/health` response.
- Check runtime logs under `insurance_agent/logs`.

## Security Notes

- Never commit `.env`, credentials, API keys, or private cert files.
- Keep `.gitignore` rules in sync with local environment artifacts.
- Use environment-specific secrets management in production.

## Production Recommendations

- Run with a production ASGI server config (workers, timeouts).
- Put API behind a reverse proxy and TLS.
- Restrict CORS origins to trusted frontend domains.
- Add authentication/authorization for non-webhook routes.
- Add monitoring and alerting for webhook failures.

## License

Internal project. Add your preferred license if this becomes public.
