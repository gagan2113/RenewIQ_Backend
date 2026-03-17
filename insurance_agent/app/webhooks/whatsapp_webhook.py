"""
POST /webhooks/whatsapp
Receives Twilio inbound WhatsApp webhooks (ICICI Lombard schema).
"""

import logging

from fastapi import APIRouter, BackgroundTasks, Depends, Form, HTTPException, Request
from fastapi.responses import PlainTextResponse
from sqlalchemy.orm import Session
from twilio.request_validator import RequestValidator
from twilio.rest import Client as TwilioClient
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
_twilio_client = TwilioClient(settings.TWILIO_ACCOUNT_SID, settings.TWILIO_AUTH_TOKEN)

WHATSAPP_PREFIX = "whatsapp:"


def _validate_twilio_signature(request: Request, raw_body: bytes) -> None:
    signature = request.headers.get("X-Twilio-Signature", "")
    url = str(request.url)
    if not _twilio_validator.validate(url, {}, signature):
        raise HTTPException(status_code=403, detail="Invalid Twilio WhatsApp signature")


def _send_confirmation_whatsapp(to: str, customer_name: str) -> None:
    try:
        wa_to = to if to.startswith(WHATSAPP_PREFIX) else f"{WHATSAPP_PREFIX}{to}"
        wa_from = f"{WHATSAPP_PREFIX}{settings.TWILIO_PHONE_NUMBER}"
        body = (
            f"✅ Hi {customer_name}, your insurance policy has been successfully renewed! "
            "Thank you for choosing to stay protected. "
            "Your updated policy documents will be sent to you shortly. 🛡️"
        )
        msg = _twilio_client.messages.create(body=body, from_=wa_from, to=wa_to)
        logger.info("Confirmation WhatsApp sent to %s | SID=%s", to, msg.sid)
    except Exception as exc:
        logger.error("Failed to send confirmation WhatsApp to %s: %s", to, exc)


@router.post("/whatsapp", response_class=PlainTextResponse)
async def whatsapp_webhook(
    request: Request,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    From: str = Form(...),
    Body: str = Form(...),
    MessageSid: str = Form(default=""),
    ProfileName: str = Form(default=""),
):
    raw_body = await request.body()
    _validate_twilio_signature(request, raw_body)

    clean_from = From.replace(WHATSAPP_PREFIX, "")
    logger.info("WhatsApp webhook | From=%s | MessageSid=%s | Body=%s", clean_from, MessageSid, Body[:120])

    customer = find_customer_by_phone(db, clean_from)
    if not customer:
        logger.warning("WhatsApp webhook: no customer found for %s", clean_from)
        return PlainTextResponse(str(MessagingResponse()), media_type="application/xml")

    intent = classify_intent(Body)
    logger.info("WhatsApp intent for customer %s: %s", customer.id, intent)

    reminder = find_latest_reminder(db, customer.id, channel_code="WHATSAPP")
    if reminder:
        update_reminder_response(db, reminder, intent=intent, delivery_status="READ")
        if intent == "RENEWED" and reminder.policy_id:
            mark_policy_renewed(db, reminder.policy_id)
            background_tasks.add_task(_send_confirmation_whatsapp, clean_from, customer.full_name)
        background_tasks.add_task(trigger_agent_update, customer.id, reminder.policy_id)

    twiml = MessagingResponse()
    if intent == "NEEDS_INFO":
        twiml.message(
            "We'd love to help! 😊 Please reply with your question or call our support team. "
            "Our agents are available Mon–Sat, 9am–6pm."
        )
    elif intent == "NOT_INTERESTED":
        twiml.message("We're sorry to hear that. Your coverage will remain active until its expiry date.")

    return PlainTextResponse(str(twiml), media_type="application/xml")
