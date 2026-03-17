"""
Minimal SendGrid verification script for RenewIQ.

Usage:
  python verify_sendgrid.py --to you@example.com
  python verify_sendgrid.py --to you@example.com --subject "RenewIQ Test"

Environment variables used:
  SENDGRID_API_KEY
  SENDGRID_FROM_EMAIL
  SENDGRID_FROM_NAME (optional)
  SENDGRID_DATA_RESIDENCY (optional, set to 'eu' for EU-pinned sending)
"""

from __future__ import annotations

import argparse
import json
import traceback

import sendgrid
from sendgrid.helpers.mail import Mail, To

from app.config import settings


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify SendGrid email sending")
    parser.add_argument("--to", required=True, help="Recipient email address")
    parser.add_argument("--subject", default="RenewIQ SendGrid Verification", help="Email subject")
    args = parser.parse_args()

    if not settings.SENDGRID_API_KEY:
        raise SystemExit("SENDGRID_API_KEY is empty in environment/.env")

    if not settings.SENDGRID_FROM_EMAIL:
        raise SystemExit("SENDGRID_FROM_EMAIL is empty in environment/.env")

    sg = sendgrid.SendGridAPIClient(api_key=settings.SENDGRID_API_KEY)

    residency = (settings.SENDGRID_DATA_RESIDENCY or "").strip().lower()
    if residency == "eu" and hasattr(sg, "set_sendgrid_data_residency"):
        sg.set_sendgrid_data_residency("eu")

    sender = settings.SENDGRID_FROM_EMAIL
    if settings.SENDGRID_FROM_NAME:
        sender = (settings.SENDGRID_FROM_EMAIL, settings.SENDGRID_FROM_NAME)

    html = """
    <html>
      <body style=\"font-family:Arial,sans-serif;\">
        <h2>RenewIQ SendGrid Verification</h2>
        <p>If you received this email, your SendGrid setup is working.</p>
      </body>
    </html>
    """

    message = Mail(
        from_email=sender,
        to_emails=To(args.to),
        subject=args.subject,
        html_content=html,
    )

    try:
        response = sg.client.mail.send.post(request_body=message.get())
        result = {
            "status_code": response.status_code,
            "ok": response.status_code in (200, 201, 202),
            "message_id": response.headers.get("X-Message-Id"),
            "headers": dict(response.headers),
            "body": response.body.decode("utf-8", errors="replace") if isinstance(response.body, (bytes, bytearray)) else str(response.body),
        }
        print(json.dumps(result, indent=2))
    except Exception as exc:
        error = {
            "ok": False,
            "error": str(exc),
            "traceback": traceback.format_exc(),
        }
        print(json.dumps(error, indent=2))
        raise


if __name__ == "__main__":
    main()
