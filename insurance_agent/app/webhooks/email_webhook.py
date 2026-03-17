"""
POST /webhooks/email       — SendGrid Inbound Parse
POST /webhooks/email/event — SendGrid Event Webhook
(ICICI Lombard schema)
"""

import hashlib
import json
import logging
import os
from typing import Optional

from fastapi import APIRouter, BackgroundTasks, Depends, Form, Header, HTTPException, Request
from sqlalchemy.orm import Session

from app.config import settings
from app.database import get_db
from app.webhooks._helpers import (
    classify_intent,
    find_customer_by_email,
    find_latest_reminder,
    mark_policy_renewed,
    trigger_agent_update,
    update_reminder_response,
)

logger = logging.getLogger(__name__)
router = APIRouter()

SENDGRID_SIGNING_KEY = settings.SENDGRID_WEBHOOK_SIGNING_KEY


def _verify_sendgrid_signature(payload: bytes, timestamp: str, signature: str) -> bool:
    if not SENDGRID_SIGNING_KEY:
        logger.warning("SENDGRID_WEBHOOK_SIGNING_KEY not set — skipping verification.")
        return True
    try:
        from ecdsa import VerifyingKey, NIST256p
        import base64
        vk = VerifyingKey.from_pem(SENDGRID_SIGNING_KEY, hashfunc=hashlib.sha256)
        signed_payload = timestamp.encode() + payload
        decoded_sig = base64.b64decode(signature)
        vk.verify(decoded_sig, signed_payload, sigdecode=lambda sig, order: (
            int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big")
        ))
        return True
    except Exception as exc:
        logger.warning("SendGrid signature verification failed: %s", exc)
        return False


@router.post("/email")
async def email_inbound_webhook(
    request: Request,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    from_: Optional[str] = Form(default=None, alias="from"),
    subject: Optional[str] = Form(default=""),
    text: Optional[str] = Form(default=""),
    html: Optional[str] = Form(default=""),
    envelope: Optional[str] = Form(default="{}"),
):
    logger.info("Inbound email webhook | from=%s | subject=%s", from_, subject)

    sender_email = ""
    if from_:
        import re
        match = re.search(r"<(.+?)>", from_)
        sender_email = match.group(1).strip() if match else from_.strip()

    if not sender_email:
        return {"status": "ignored", "reason": "no sender email"}

    body_text = text.strip() if text else ""

    customer = find_customer_by_email(db, sender_email)
    if not customer:
        return {"status": "ignored", "reason": "customer not found"}

    intent = classify_intent(f"Subject: {subject}\n\n{body_text}")
    logger.info("Email intent for customer %s: %s", customer.id, intent)

    reminder = find_latest_reminder(db, customer.id, channel_code="EMAIL")
    if reminder:
        update_reminder_response(db, reminder, intent=intent, delivery_status="READ")
        if intent == "RENEWED" and reminder.policy_id:
            mark_policy_renewed(db, reminder.policy_id)
        background_tasks.add_task(trigger_agent_update, customer.id, reminder.policy_id)

    return {"status": "ok", "intent": intent}


@router.post("/email/event")
async def email_event_webhook(
    request: Request,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    x_twilio_email_event_webhook_signature: Optional[str] = Header(default=None),
    x_twilio_email_event_webhook_timestamp: Optional[str] = Header(default=None),
):
    raw_body = await request.body()

    sig = x_twilio_email_event_webhook_signature or ""
    ts = x_twilio_email_event_webhook_timestamp or ""
    if SENDGRID_SIGNING_KEY and not _verify_sendgrid_signature(raw_body, ts, sig):
        raise HTTPException(status_code=403, detail="Invalid SendGrid event webhook signature")

    try:
        events = json.loads(raw_body)
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON payload")

    for event in events:
        event_type = event.get("event", "").lower()
        email_addr = event.get("email", "")
        url_clicked = event.get("url", "")

        customer = find_customer_by_email(db, email_addr)
        if not customer:
            continue

        reminder = find_latest_reminder(db, customer.id, channel_code="EMAIL")
        if not reminder:
            continue

        if event_type == "delivered":
            reminder.delivery_status = "DELIVERED"
            db.commit()
        elif event_type in ("open", "opened"):
            reminder.delivery_status = "DELIVERED"
            db.commit()
        elif event_type == "click":
            reminder.delivery_status = "READ"
            reminder.link_clicked = True
            reminder.agent_notes = f"Clicked: {url_clicked}"
            db.commit()
            if reminder.policy_id:
                background_tasks.add_task(trigger_agent_update, customer.id, reminder.policy_id)
        elif event_type in ("bounce", "dropped", "spamreport", "unsubscribe"):
            reminder.delivery_status = "FAILED"
            db.commit()

    return {"status": "ok", "events_processed": len(events)}
