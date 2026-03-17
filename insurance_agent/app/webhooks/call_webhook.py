"""
POST /webhooks/call-status
Receives Twilio Programmable Voice status callbacks (ICICI Lombard schema).
"""

import logging

from fastapi import APIRouter, BackgroundTasks, Depends, Form, HTTPException, Request
from fastapi.responses import PlainTextResponse
from sqlalchemy.orm import Session
from twilio.request_validator import RequestValidator

from app.config import settings
from app.database import get_db
from app.webhooks._helpers import (
    find_customer_by_phone,
    find_latest_reminder,
    trigger_agent_update,
)

logger = logging.getLogger(__name__)
router = APIRouter()

_twilio_validator = RequestValidator(settings.TWILIO_AUTH_TOKEN)

ANSWERED_STATUSES = {"in-progress", "completed"}
FAILED_STATUSES = {"no-answer", "busy", "failed", "canceled"}

STATUS_MAP = {
    "queued": "SENT",
    "initiated": "SENT",
    "ringing": "SENT",
    "in-progress": "DELIVERED",
    "completed": "DELIVERED",
    "no-answer": "FAILED",
    "busy": "FAILED",
    "failed": "FAILED",
    "canceled": "FAILED",
}


def _validate_twilio_signature(request: Request, raw_body: bytes) -> None:
    signature = request.headers.get("X-Twilio-Signature", "")
    url = str(request.url)
    if not _twilio_validator.validate(url, {}, signature):
        raise HTTPException(status_code=403, detail="Invalid Twilio call webhook signature")


@router.post("/call-status", response_class=PlainTextResponse)
async def call_status_webhook(
    request: Request,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    CallSid: str = Form(...),
    CallStatus: str = Form(...),
    To: str = Form(default=""),
    From: str = Form(default=""),
    Duration: str = Form(default="0"),
    AnsweredBy: str = Form(default=""),
):
    raw_body = await request.body()
    _validate_twilio_signature(request, raw_body)

    log_status = STATUS_MAP.get(CallStatus.lower(), "SENT")
    answered = CallStatus.lower() in ANSWERED_STATUSES

    logger.info(
        "Call status webhook | SID=%s | Status=%s | To=%s | Duration=%ss",
        CallSid, CallStatus, To, Duration,
    )

    customer = find_customer_by_phone(db, To)
    if not customer:
        return PlainTextResponse("", media_type="application/xml")

    reminder = find_latest_reminder(db, customer.id, channel_code="VOICE")
    if reminder:
        reminder.delivery_status = log_status
        if answered:
            reminder.agent_notes = (
                f"Call answered. Duration: {Duration}s. AnsweredBy: {AnsweredBy or 'human'}"
            )
        elif CallStatus.lower() in FAILED_STATUSES:
            reminder.agent_notes = f"Call {CallStatus}: not reached."
        db.commit()

        if reminder.policy_id:
            background_tasks.add_task(trigger_agent_update, customer.id, reminder.policy_id)

    return PlainTextResponse("", media_type="application/xml")
