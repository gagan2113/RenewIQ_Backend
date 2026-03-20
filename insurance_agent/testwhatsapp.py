"""
Integration-style tester for WhatsApp and Email channels with fallback behavior.

Usage examples:
  python testwhatsapp.py --phone +918349101211 --email gaganverma5131@gmail.com --name "Test User"
  python testwhatsapp.py --phone +919893010159 --email vermagagan3347@gmail.com
Notes:
- This script uses real Twilio/SendGrid calls unless simulation flags are used.
- Make sure .env has valid credentials before running real sends.
"""

from __future__ import annotations

import argparse
import json
from typing import Any, Dict

from app.tools.whatsapp_tool import send_whatsapp
from app.tools.email_tool import send_email


def _is_success(result: Dict[str, Any]) -> bool:
    """Normalize success criteria across WhatsApp and Email result shapes."""
    status = str(result.get("status", "")).lower()
    if status in {"sent", "queued", "accepted", "delivered", "initiated"}:
        return True
    if status == "failed":
        return False

    # Defensive fallback for uncommon result payloads
    status_code = result.get("status_code")
    if isinstance(status_code, int) and status_code in {200, 201, 202}:
        return True
    return False


def _send_whatsapp(phone: str, message: str, renewal_link: str, simulate_failure: bool) -> Dict[str, Any]:
    if simulate_failure:
        return {"status": "failed", "message_sid": None, "error": "Simulated WhatsApp failure"}
    return send_whatsapp.invoke(
        {
            "to": phone,
            "message": message,
            "renewal_link": renewal_link,
        }
    )


def _send_email(
    email: str,
    customer_name: str,
    message: str,
    renewal_link: str,
    policy_number: str,
    days_until_expiry: int,
    simulate_failure: bool,
) -> Dict[str, Any]:
    if simulate_failure:
        return {
            "status": "failed",
            "status_code": None,
            "message_id": None,
            "error": "Simulated Email failure",
        }
    return send_email.invoke(
        {
            "to_email": email,
            "customer_name": customer_name,
            "message": message,
            "renewal_link": renewal_link,
            "policy_number": policy_number,
            "days_until_expiry": days_until_expiry,
        }
    )


def attempt_whatsapp_then_email(
    phone: str,
    email: str,
    customer_name: str,
    policy_number: str,
    renewal_link: str,
    days_until_expiry: int,
    simulate_wa_failure: bool,
) -> Dict[str, Any]:
    """Primary WhatsApp path with Email fallback."""
    wa_message = (
        f"Hi {customer_name}, your policy {policy_number} is due for renewal soon. "
        "Please renew to avoid coverage lapse."
    )
    wa_result = _send_whatsapp(phone, wa_message, renewal_link, simulate_failure=simulate_wa_failure)

    if _is_success(wa_result):
        return {
            "flow": "whatsapp->email",
            "final_channel": "whatsapp",
            "fallback_used": False,
            "primary_result": wa_result,
            "fallback_result": None,
        }

    email_message = (
        f"Dear {customer_name},\n\n"
        f"This is a reminder that policy {policy_number} is approaching expiry. "
        "Please renew at the earliest to continue uninterrupted coverage."
    )
    email_result = _send_email(
        email=email,
        customer_name=customer_name,
        message=email_message,
        renewal_link=renewal_link,
        policy_number=policy_number,
        days_until_expiry=days_until_expiry,
        simulate_failure=False,
    )
    return {
        "flow": "whatsapp->email",
        "final_channel": "email" if _is_success(email_result) else "none",
        "fallback_used": True,
        "primary_result": wa_result,
        "fallback_result": email_result,
    }


def attempt_email_then_whatsapp(
    phone: str,
    email: str,
    customer_name: str,
    policy_number: str,
    renewal_link: str,
    days_until_expiry: int,
    simulate_email_failure: bool,
) -> Dict[str, Any]:
    """Primary Email path with WhatsApp fallback."""
    email_message = (
        f"Dear {customer_name},\n\n"
        f"Your policy {policy_number} expires soon. "
        "Kindly renew using the link below."
    )
    email_result = _send_email(
        email=email,
        customer_name=customer_name,
        message=email_message,
        renewal_link=renewal_link,
        policy_number=policy_number,
        days_until_expiry=days_until_expiry,
        simulate_failure=simulate_email_failure,
    )

    if _is_success(email_result):
        return {
            "flow": "email->whatsapp",
            "final_channel": "email",
            "fallback_used": False,
            "primary_result": email_result,
            "fallback_result": None,
        }

    wa_message = (
        f"Hi {customer_name}, reminder: policy {policy_number} is due for renewal. "
        "Renew now to stay protected."
    )
    wa_result = _send_whatsapp(phone, wa_message, renewal_link, simulate_failure=False)
    return {
        "flow": "email->whatsapp",
        "final_channel": "whatsapp" if _is_success(wa_result) else "none",
        "fallback_used": True,
        "primary_result": email_result,
        "fallback_result": wa_result,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Test WhatsApp + Email channels with fallback")
    parser.add_argument("--phone", required=True, help="Recipient phone number in E.164 format")
    parser.add_argument("--email", required=True, help="Recipient email address")
    parser.add_argument("--name", default="Customer", help="Customer name")
    parser.add_argument("--policy-number", default="POL-TEST-001", help="Policy number")
    parser.add_argument("--renewal-link", default="https://renewiq.app/renew/test", help="Renewal URL")
    parser.add_argument("--days-until-expiry", type=int, default=7, help="Days until expiry")
    parser.add_argument(
        "--simulate-wa-failure",
        action="store_true",
        help="Force WhatsApp primary send to fail (to validate Email fallback)",
    )
    parser.add_argument(
        "--simulate-email-failure",
        action="store_true",
        help="Force Email primary send to fail (to validate WhatsApp fallback)",
    )
    args = parser.parse_args()

    result_wa_first = attempt_whatsapp_then_email(
        phone=args.phone,
        email=args.email,
        customer_name=args.name,
        policy_number=args.policy_number,
        renewal_link=args.renewal_link,
        days_until_expiry=args.days_until_expiry,
        simulate_wa_failure=args.simulate_wa_failure,
    )

    result_email_first = attempt_email_then_whatsapp(
        phone=args.phone,
        email=args.email,
        customer_name=args.name,
        policy_number=args.policy_number,
        renewal_link=args.renewal_link,
        days_until_expiry=args.days_until_expiry,
        simulate_email_failure=args.simulate_email_failure,
    )

    summary = {
        "inputs": {
            "phone": args.phone,
            "email": args.email,
            "name": args.name,
            "policy_number": args.policy_number,
            "renewal_link": args.renewal_link,
            "days_until_expiry": args.days_until_expiry,
            "simulate_wa_failure": args.simulate_wa_failure,
            "simulate_email_failure": args.simulate_email_failure,
        },
        "results": [result_wa_first, result_email_first],
    }

    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
