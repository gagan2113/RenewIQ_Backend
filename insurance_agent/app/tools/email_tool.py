"""Email sender tool using SendGrid Dynamic Template with retries."""

import logging
from datetime import date, timedelta
from typing import Annotated

import sendgrid
from langchain_core.tools import tool
from tenacity import (
  before_sleep_log,
  retry,
  retry_if_exception_type,
  stop_after_attempt,
  wait_exponential,
)

from app.config import settings

logger = logging.getLogger(__name__)


@retry(
  retry=retry_if_exception_type(Exception),
  stop=stop_after_attempt(3),
  wait=wait_exponential(multiplier=1, min=2, max=30),
  before_sleep=before_sleep_log(logger, logging.WARNING),
  reraise=True,
)
def _dispatch_email(to_email: str, template_data: dict) -> dict:
  sg = sendgrid.SendGridAPIClient(api_key=settings.SENDGRID_API_KEY)
  residency = (settings.SENDGRID_DATA_RESIDENCY or "").strip().lower()
  if residency == "eu" and hasattr(sg, "set_sendgrid_data_residency"):
    sg.set_sendgrid_data_residency("eu")

  if not settings.SENDGRID_TEMPLATE_ID:
    raise ValueError("SENDGRID_TEMPLATE_ID is not set")

  payload = {
    "from": {
      "email": settings.SENDGRID_FROM_EMAIL,
      "name": settings.SENDGRID_FROM_NAME,
    },
    "template_id": settings.SENDGRID_TEMPLATE_ID,
    "personalizations": [
      {
        "to": [{"email": to_email}],
        "dynamic_template_data": template_data,
      }
    ],
  }

  response = sg.client.mail.send.post(request_body=payload)
  return {
    "status": "sent" if response.status_code in (200, 202) else "failed",
    "status_code": response.status_code,
    "message_id": response.headers.get("X-Message-Id"),
  }


@tool
def send_email(
  to_email: Annotated[str, "Recipient email address"],
  customer_name: Annotated[str, "Customer's full name for personalisation"],
  message: Annotated[str, "Support/assistance message text"],
  renewal_link: Annotated[str, "Renewal URL shown in template guidance"],
  policy_number: Annotated[str, "Policy number"],
  days_until_expiry: Annotated[int, "Days until policy expiry"] = 30,
) -> dict:
  """Send renewal reminder via SendGrid dynamic template."""
  try:
    expiry_date = (date.today() + timedelta(days=max(0, days_until_expiry))).isoformat()
    template_data = {
      "client_name": customer_name,
      "policy_type": "Insurance Policy",
      "policy_number": policy_number,
      "expiration_date": expiry_date,
      "asset_being_insured": "Policy coverage",
      "example_change": "address or nominee details",
      "instructions_on_how_to_renew": f"click the renewal link and complete payment: {renewal_link}",
      "your_name": settings.SENDGRID_FROM_NAME or "RenewIQ Team",
      "your_title": "Customer Support",
    }
    # Preserve custom message context inside a template-friendly field.
    if message:
      template_data["example_change"] = message

    result = _dispatch_email(to_email=to_email, template_data=template_data)
    logger.info("Email sent to %s | status=%s | msg_id=%s", to_email, result["status"], result.get("message_id"))
    return result
  except Exception as exc:
    logger.error("Email failed to %s after retries: %s", to_email, exc)
    return {"status": "failed", "status_code": None, "message_id": None, "error": str(exc)}

