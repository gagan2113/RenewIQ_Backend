"""
POST /webhooks/sms
Receives Twilio inbound SMS webhooks (ICICI Lombard schema).
"""

import logging

from fastapi import APIRouter, BackgroundTasks, Depends, Form, HTTPException, Request
from fastapi.responses import PlainTextResponse
from sqlalchemy.orm import Session
from twilio.request_validator import RequestValidator
from twilio.twiml.messaging_response import MessagingResponse

from app.config import settings
from app.database import get_db
from app.webhooks._helpers import (
    classify_intent,
    find_customer_by_phone,
    find_latest_reminder,
    mark_policy_renewed,
    trigger_agent_update,
    update_reminder_response,
)

logger = logging.getLogger(__name__)
router = APIRouter()

_twilio_validator = RequestValidator(settings.TWILIO_AUTH_TOKEN)


def _validate_twilio_signature(request: Request, body: bytes) -> None:
    signature = request.headers.get("X-Twilio-Signature", "")
    url = str(request.url)
    if not _twilio_validator.validate(url, {}, signature):
        raise HTTPException(status_code=403, detail="Invalid Twilio signature")


@router.post("/sms", response_class=PlainTextResponse)
async def sms_webhook(
    request: Request,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    From: str = Form(...),
    Body: str = Form(...),
    MessageSid: str = Form(default=""),
    NumMedia: str = Form(default="0"),
):
    raw_body = await request.body()
    _validate_twilio_signature(request, raw_body)

    logger.info("SMS webhook | From=%s | MessageSid=%s | Body=%s", From, MessageSid, Body[:120])

    customer = find_customer_by_phone(db, From)
    if not customer:
        logger.warning("SMS webhook: no customer found for %s", From)
        twiml = MessagingResponse()
        return PlainTextResponse(str(twiml), media_type="application/xml")

    intent = classify_intent(Body)
    logger.info("SMS intent for customer %s: %s", customer.id, intent)

    reminder = find_latest_reminder(db, customer.id, channel_code="SMS")
    if reminder:
        update_reminder_response(db, reminder, intent=intent, delivery_status="READ")
        if intent == "RENEWED" and reminder.policy_id:
            mark_policy_renewed(db, reminder.policy_id)
        background_tasks.add_task(trigger_agent_update, customer.id, reminder.policy_id)

    twiml = MessagingResponse()
    if intent == "RENEWED":
        twiml.message("🎉 Great news! Your renewal is confirmed. Thank you for staying covered with us!")
    elif intent == "NEEDS_INFO":
        twiml.message("We're happy to help! Please call our support line or visit our website for more details.")
    elif intent == "NOT_INTERESTED":
        twiml.message("Understood. We're sorry to see you go. Let us know if you change your mind!")

    return PlainTextResponse(str(twiml), media_type="application/xml")
