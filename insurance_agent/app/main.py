"""
RenewIQ — Insurance Agent API
FastAPI application entry point.
"""

from __future__ import annotations

import logging
import logging.handlers
import os
import traceback
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy import text

# --- API routers ---
from app.api.policies import router as policies_router
from app.api.customers import router as customers_router
from app.api.notifications import router as notifications_router
from app.api.agent import router as agent_router

# --- Webhook routers ---
from app.webhooks.sms_webhook import router as sms_router
from app.webhooks.whatsapp_webhook import router as whatsapp_router
from app.webhooks.email_webhook import router as email_router
from app.webhooks.call_webhook import router as call_router

# --- Scheduler ---
from app.scheduler import scheduler, start_scheduler, stop_scheduler
from app.config import settings
from app.database import SessionLocal
from app.api.responses import error_response

# ---------------------------------------------------------------------------
# Logging setup: console + rotating file
# ---------------------------------------------------------------------------

LOG_DIR = os.getenv("LOG_DIR", "logs")
os.makedirs(LOG_DIR, exist_ok=True)

_file_handler = logging.handlers.RotatingFileHandler(
    filename=os.path.join(LOG_DIR, "renewiq.log"),
    maxBytes=10 * 1024 * 1024,   # 10 MB
    backupCount=5,
    encoding="utf-8",
)
_file_handler.setFormatter(
    logging.Formatter("%(asctime)s | %(levelname)-8s | %(name)s | %(message)s")
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
    handlers=[logging.StreamHandler(), _file_handler],
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Lifespan context manager (startup / shutdown)
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("=== RenewIQ Insurance Agent API starting up ===")
    start_scheduler()
    yield
    logger.info("=== RenewIQ Insurance Agent API shutting down ===")
    stop_scheduler()


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(
    title="RenewIQ — Insurance Agent API",
    description=(
        "AI-powered insurance renewal reminder agent with multi-channel outreach "
        "(SMS, WhatsApp, Email, Voice). Powered by LangGraph + GPT-4o-mini."
    ),
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc",
)

# ---------------------------------------------------------------------------
# CORS Middleware
# ---------------------------------------------------------------------------

ALLOWED_ORIGINS = os.getenv(
    "CORS_ALLOWED_ORIGINS",
    "http://localhost:3000,http://localhost:8000",
).split(",")

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# Global exception handler
# ---------------------------------------------------------------------------

@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException) -> JSONResponse:
    detail = exc.detail
    detail_message = detail if isinstance(detail, str) else "Request failed"
    return JSONResponse(
        status_code=exc.status_code,
        content=error_response(
            message=detail_message,
            code=f"HTTP_{exc.status_code}",
            details={"path": str(request.url), "detail": detail},
        ),
    )


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(
        status_code=422,
        content=error_response(
            message="Validation failed",
            code="VALIDATION_ERROR",
            details={"path": str(request.url), "errors": exc.errors()},
        ),
    )


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    tb = traceback.format_exc()
    logger.error(
        "Unhandled exception on %s %s\n%s",
        request.method,
        request.url,
        tb,
    )
    return JSONResponse(
        status_code=500,
        content=error_response(
            message="An unexpected error occurred. Our team has been notified.",
            code="INTERNAL_SERVER_ERROR",
            details={"path": str(request.url)},
        ),
    )


# ---------------------------------------------------------------------------
# Mount API routers
# ---------------------------------------------------------------------------

app.include_router(policies_router)
app.include_router(customers_router)
app.include_router(notifications_router)
app.include_router(agent_router)

# ---------------------------------------------------------------------------
# Mount Webhook routers (under /webhooks prefix)
# ---------------------------------------------------------------------------

app.include_router(sms_router,      prefix="/webhooks", tags=["Webhooks: SMS"])
app.include_router(whatsapp_router, prefix="/webhooks", tags=["Webhooks: WhatsApp"])
app.include_router(email_router,    prefix="/webhooks", tags=["Webhooks: Email"])
app.include_router(call_router,     prefix="/webhooks", tags=["Webhooks: Call"])


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

@app.get("/", tags=["Health"])
def read_root():
    return {
        "success": True,
        "message": "API is running",
        "data": {"status": "ok", "service": "RenewIQ Insurance Agent API"},
        "error": None,
    }


@app.get("/health", tags=["Health"])
async def health_check():
    """
    Returns:
      - db_status: 'ok' | 'error'
      - scheduler_status: 'running' | 'stopped'
      - openai_status: 'reachable' | 'unreachable'
    """
    # --- DB check ---
    db_status = "error"
    db_detail = ""
    try:
        db = SessionLocal()
        db.execute(text("SELECT 1"))
        db.close()
        db_status = "ok"
    except Exception as exc:
        db_detail = str(exc)
        logger.warning("Health check: DB error — %s", exc)

    # --- Scheduler check ---
    scheduler_status = "running" if scheduler.running else "stopped"

    # --- OpenAI reachability check ---
    openai_status = "unreachable"
    openai_detail = ""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get("https://api.openai.com/v1/models",
                                    headers={"Authorization": f"Bearer {settings.OPENAI_API_KEY}"})
            openai_status = "reachable" if resp.status_code in (200, 401) else "unreachable"
            # 401 means the key is syntactically valid but may be expired — API is still reachable
    except Exception as exc:
        openai_detail = str(exc)
        logger.warning("Health check: OpenAI unreachable — %s", exc)

    overall = "ok" if (db_status == "ok" and scheduler_status == "running") else "degraded"

    return {
        "success": overall == "ok",
        "message": "Health check completed" if overall == "ok" else "Service is degraded",
        "data": {
            "status": overall,
            "db": {"status": db_status, **({"detail": db_detail} if db_detail else {})},
            "scheduler": {"status": scheduler_status},
            "openai": {"status": openai_status, **({"detail": openai_detail} if openai_detail else {})},
        },
        "error": None if overall == "ok" else {"code": "SERVICE_DEGRADED", "details": {}},
    }
