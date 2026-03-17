"""
Email sender tool — SendGrid API with GPT-generated subject line
LangChain @tool + standalone callable, with tenacity retries.
"""

import logging
from typing import Annotated

import sendgrid
from langchain_core.tools import tool
from sendgrid.helpers.mail import Mail, To, Content
from tenacity import (
    retry,
    retry_if_exception_type,
    stop_after_attempt,
    wait_exponential,
    before_sleep_log,
)

from app.config import settings
from app.llm import get_llm

logger = logging.getLogger(__name__)

_llm = get_llm(temperature=0.6)

# ---------------------------------------------------------------------------
# Subject line generator
# ---------------------------------------------------------------------------

def _generate_subject(customer_name: str, policy_number: str, days_until_expiry: int) -> str:
    """Use GPT-4o-mini to create an urgency-calibrated subject line."""
    urgency = (
        "URGENT – " if days_until_expiry <= 3
        else "Important – " if days_until_expiry <= 7
        else ""
    )
    prompt = (
        f"Generate a short, compelling email subject line for an insurance renewal reminder.\n"
        f"Customer: {customer_name}\n"
        f"Policy number: {policy_number}\n"
        f"Days until expiry: {days_until_expiry}\n"
        f"Urgency prefix if needed: '{urgency}'\n"
        f"Rules: max 60 characters, do not use ALL CAPS, keep it professional and friendly.\n"
        f"Return ONLY the subject line text."
    )
    response = _llm.invoke(prompt)
    return response.content.strip()


# ---------------------------------------------------------------------------
# HTML email template
# ---------------------------------------------------------------------------

def _build_html(customer_name: str, message: str, renewal_link: str, policy_number: str) -> str:
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Policy Renewal Reminder</title>
</head>
<body style="margin:0;padding:0;background:#f4f6f9;font-family:'Segoe UI',Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f6f9;padding:40px 0;">
    <tr>
      <td align="center">
        <table width="600" cellpadding="0" cellspacing="0"
               style="background:#ffffff;border-radius:12px;overflow:hidden;
                      box-shadow:0 4px 20px rgba(0,0,0,0.08);">

          <!-- Header -->
          <tr>
            <td style="background:linear-gradient(135deg,#1a73e8,#0d47a1);
                       padding:36px 40px;text-align:center;">
              <h1 style="color:#ffffff;margin:0;font-size:24px;font-weight:700;">
                🛡️ Policy Renewal Reminder
              </h1>
              <p style="color:#c2d7ff;margin:8px 0 0;font-size:14px;">
                Policy #{policy_number}
              </p>
            </td>
          </tr>

          <!-- Body -->
          <tr>
            <td style="padding:40px 40px 24px;">
              <p style="margin:0 0 16px;font-size:16px;color:#202124;">
                Dear <strong>{customer_name}</strong>,
              </p>
              <p style="margin:0 0 24px;font-size:15px;color:#3c4043;
                        line-height:1.7;white-space:pre-line;">
                {message}
              </p>

              <!-- CTA Button -->
              <table cellpadding="0" cellspacing="0" style="margin:0 auto 32px;">
                <tr>
                  <td align="center" style="border-radius:8px;
                             background:linear-gradient(135deg,#1a73e8,#0d47a1);">
                    <a href="{renewal_link}"
                       style="display:inline-block;padding:16px 40px;
                              font-size:16px;font-weight:700;color:#ffffff;
                              text-decoration:none;letter-spacing:0.5px;">
                      Renew My Policy Now →
                    </a>
                  </td>
                </tr>
              </table>

              <p style="margin:0;font-size:13px;color:#80868b;text-align:center;">
                Or copy this link into your browser:<br/>
                <a href="{renewal_link}" style="color:#1a73e8;word-break:break-all;">
                  {renewal_link}
                </a>
              </p>
            </td>
          </tr>

          <!-- Footer -->
          <tr>
            <td style="background:#f8f9fa;padding:24px 40px;border-top:1px solid #e8eaed;">
              <p style="margin:0;font-size:12px;color:#80868b;text-align:center;">
                This is an automated reminder from RenewIQ. If you have already renewed,
                please ignore this email.<br/>
                © 2026 RenewIQ. All rights reserved.
              </p>
            </td>
          </tr>

        </table>
      </td>
    </tr>
  </table>
</body>
</html>"""


# ---------------------------------------------------------------------------
# Internal retry-wrapped SendGrid call
# ---------------------------------------------------------------------------

@retry(
    retry=retry_if_exception_type(Exception),
    stop=stop_after_attempt(3),
    wait=wait_exponential(multiplier=1, min=2, max=30),
    before_sleep=before_sleep_log(logger, logging.WARNING),
    reraise=True,
)
def _dispatch_email(subject: str, to_email: str, html_content: str) -> dict:
    sg = sendgrid.SendGridAPIClient(api_key=settings.SENDGRID_API_KEY)
  residency = (settings.SENDGRID_DATA_RESIDENCY or "").strip().lower()
  if residency == "eu" and hasattr(sg, "set_sendgrid_data_residency"):
    sg.set_sendgrid_data_residency("eu")

    mail = Mail(
    from_email=settings.SENDGRID_FROM_EMAIL,
        subject=subject,
        to_emails=To(to_email),
    )
    mail.content = [Content("text/html", html_content)]
    response = sg.client.mail.send.post(request_body=mail.get())
    return {
        "status": "sent" if response.status_code in (200, 202) else "failed",
        "status_code": response.status_code,
        "message_id": response.headers.get("X-Message-Id"),
    }


# ---------------------------------------------------------------------------
# LangChain tool
# ---------------------------------------------------------------------------

@tool
def send_email(
    to_email: Annotated[str, "Recipient email address"],
    customer_name: Annotated[str, "Customer's full name for personalisation"],
    message: Annotated[str, "Email body text (plain text; will be wrapped in HTML template)"],
    renewal_link: Annotated[str, "Renewal URL embedded in the CTA button"],
    policy_number: Annotated[str, "Policy number shown in header"],
    days_until_expiry: Annotated[int, "Days until policy expiry, used to calibrate subject urgency"] = 30,
) -> dict:
    """
    Send a styled HTML renewal reminder email via SendGrid.
    Subject line is GPT-4o-mini generated based on urgency (days_until_expiry).

    Returns a dict with keys:
      - status (str): 'sent' or 'failed'
      - status_code (int): SendGrid HTTP status code
      - message_id (str | None): SendGrid message ID
    """
    try:
        subject = _generate_subject(customer_name, policy_number, days_until_expiry)
        html_content = _build_html(customer_name, message, renewal_link, policy_number)
        result = _dispatch_email(subject=subject, to_email=to_email, html_content=html_content)
        logger.info("Email sent to %s | status=%s | msg_id=%s", to_email, result["status"], result.get("message_id"))
        return result
    except Exception as exc:
        logger.error("Email failed to %s after retries: %s", to_email, exc)
        return {"status": "failed", "status_code": None, "message_id": None, "error": str(exc)}
