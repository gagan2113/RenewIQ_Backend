"""
WhatsApp sender tool — Twilio WhatsApp sandbox API
LangChain @tool + standalone callable, with tenacity retries.
"""

import logging
from typing import Annotated

from langchain_core.tools import tool
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
    before_sleep_log,
)
from twilio.base.exceptions import TwilioRestException
from twilio.rest import Client

from app.config import settings

logger = logging.getLogger(__name__)

WHATSAPP_PREFIX = "whatsapp:"

# ---------------------------------------------------------------------------
# Template message builder
# ---------------------------------------------------------------------------

def _build_template_body(message: str, renewal_link: str) -> str:
    """
    Construct a WhatsApp-friendly message body.
    Injects the renewal_link if not already embedded.
    """
    if renewal_link in message:
        return message
    return (
        f"{message}\n\n"
        f"🔗 *Renew your policy instantly here:*\n{renewal_link}\n\n"
        "_Reply STOP to opt out._"
    )


# ---------------------------------------------------------------------------
# Internal retry-wrapped Twilio call
# ---------------------------------------------------------------------------

@retry(
    retry=retry_if_exception_type((TwilioRestException, Exception)),
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=2, max=30),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
def _dispatch_whatsapp(to: str, body: str) -> dict:
    client = Client(settings.TWILIO_ACCOUNT_SID, settings.TWILIO_AUTH_TOKEN)
    # Twilio requires the whatsapp: prefix for both from_ and to
    msg = client.messages.create(
        body=body,
        from_=f"{WHATSAPP_PREFIX}{settings.TWILIO_PHONE_NUMBER}",
        to=f"{WHATSAPP_PREFIX}{to}" if not to.startswith(WHATSAPP_PREFIX) else to,
    )
    return {"status": msg.status, "message_sid": msg.sid}


# ---------------------------------------------------------------------------
# LangChain tool
# ---------------------------------------------------------------------------

@tool
def send_whatsapp(
    to: Annotated[str, "Recipient phone in E.164 format, e.g. +919876543210"],
    message: Annotated[str, "The WhatsApp message body"],
    renewal_link: Annotated[str, "Renewal URL embedded as a template variable"],
) -> dict:
    """
    Send a WhatsApp message using the Twilio WhatsApp sandbox API.
    Supports template-style messages with renewal_link as a variable.

    Returns a dict with keys:
      - status (str): Twilio message status
      - message_sid (str): Twilio message SID
    """
    body = _build_template_body(message=message, renewal_link=renewal_link)

    try:
        result = _dispatch_whatsapp(to=to, body=body)
        logger.info("WhatsApp sent to %s | SID=%s | status=%s", to, result["message_sid"], result["status"])
        return result
    except Exception as exc:
        logger.error("WhatsApp failed to %s after retries: %s", to, exc)
        return {"status": "failed", "message_sid": None, "error": str(exc)}
