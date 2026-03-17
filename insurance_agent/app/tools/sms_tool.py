"""
SMS sender tool — Twilio REST API
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
def _dispatch_sms(to: str, body: str) -> dict:
    client = Client(settings.TWILIO_ACCOUNT_SID, settings.TWILIO_AUTH_TOKEN)
    msg = client.messages.create(
        body=body,
        from_=settings.TWILIO_PHONE_NUMBER,
        to=to,
    )
    return {"status": msg.status, "message_sid": msg.sid}


# ---------------------------------------------------------------------------
# LangChain tool  (also usable as a plain function)
# ---------------------------------------------------------------------------

@tool
def send_sms(
    to: Annotated[str, "Recipient phone number in E.164 format, e.g. +919876543210"],
    message: Annotated[str, "The body of the SMS message"],
    renewal_link: Annotated[str, "Renewal URL to append when not already present in message"],
) -> dict:
    """
    Send an SMS using the Twilio REST API.

    Returns a dict with keys:
      - status (str): Twilio message status, e.g. 'queued'
      - message_sid (str): Twilio message SID
    """
    # Append renewal link if not already in message
    body = message if renewal_link in message else f"{message}\nRenew now: {renewal_link}"

    try:
        result = _dispatch_sms(to=to, body=body)
        logger.info("SMS sent to %s | SID=%s | status=%s", to, result["message_sid"], result["status"])
        return result
    except Exception as exc:
        logger.error("SMS failed to %s after retries: %s", to, exc)
        return {"status": "failed", "message_sid": None, "error": str(exc)}
