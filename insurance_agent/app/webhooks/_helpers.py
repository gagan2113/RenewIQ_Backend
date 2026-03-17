"""
Shared webhook helper utilities (ICICI Lombard schema).
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from typing import Optional
from uuid import UUID

from sqlalchemy.orm import Session

from app.config import settings
from app.llm import get_llm
from app.database import SessionLocal
from app.models.customer import Customer
from app.models.notification_log import Reminder
from app.models.policy import Policy
from app.models.product import ILProduct
from app.models.channel import Channel

logger = logging.getLogger(__name__)

_llm = get_llm(temperature=0.0)


# ── Intent classification ───────────────────────────────────────────

INTENT_PROMPT = """Given this reply from an insurance customer, classify intent as one of:
RENEWED, INTERESTED, NOT_INTERESTED, NEEDS_INFO, UNCLEAR.
Reply with JSON only: {{"intent": "..."}}

Customer reply:
{reply_text}"""


def classify_intent(reply_text: str) -> str:
    try:
        response = _llm.invoke(INTENT_PROMPT.format(reply_text=reply_text))
        data = json.loads(response.content.strip())
        return data.get("intent", "UNCLEAR")
    except Exception as exc:
        logger.error("Intent classification failed: %s", exc)
        return "UNCLEAR"


# ── Customer lookup ─────────────────────────────────────────────────

def find_customer_by_phone(db: Session, phone: str) -> Optional[Customer]:
    clean = phone.replace("whatsapp:", "").strip()
    return db.query(Customer).filter(
        (Customer.phone == clean) | (Customer.whatsapp_number == clean)
    ).first()


def find_customer_by_email(db: Session, email: str) -> Optional[Customer]:
    return db.query(Customer).filter(Customer.email == email).first()


# ── Reminder lookup ─────────────────────────────────────────────────

def find_latest_reminder(db: Session, customer_id: UUID, channel_code: str = None) -> Optional[Reminder]:
    q = db.query(Reminder).filter(Reminder.customer_id == customer_id)
    if channel_code:
        ch = db.query(Channel).filter(Channel.code == channel_code.upper()).first()
        if ch:
            q = q.filter(Reminder.channel_id == ch.id)
    return q.order_by(Reminder.scheduled_at.desc()).first()


# ── Update reminder ─────────────────────────────────────────────────

def update_reminder_response(
    db: Session,
    reminder: Reminder,
    intent: str,
    delivery_status: str = None,
) -> None:
    reminder.agent_notes = f"Intent: {intent}"
    if delivery_status:
        reminder.delivery_status = delivery_status
    db.commit()


# ── Mark policy renewed ────────────────────────────────────────────

def mark_policy_renewed(db: Session, policy_id: UUID) -> None:
    policy = db.query(Policy).filter(Policy.id == policy_id).first()
    if policy:
        policy.policy_status = "RENEWED"
        policy.last_renewed_at = datetime.now(timezone.utc)
        policy.renewal_count = (policy.renewal_count or 0) + 1
        db.commit()
        logger.info("Policy %s marked as RENEWED.", policy_id)


# ── Trigger agent update ───────────────────────────────────────────

def trigger_agent_update(customer_id: UUID, policy_id: UUID) -> None:
    """Run the LangGraph agent for a policy in a background thread."""
    db = SessionLocal()
    try:
        customer = db.query(Customer).filter(Customer.id == customer_id).first()
        policy = db.query(Policy).filter(Policy.id == policy_id).first()
        if not customer or not policy:
            logger.warning("Cannot trigger agent: customer=%s policy=%s", customer_id, policy_id)
            return

        product = db.query(ILProduct).filter(ILProduct.id == policy.product_id).first()
        from datetime import date
        days_left = (policy.risk_end_date - date.today()).days

        initial_state = {
            "customer_id": str(customer.id),
            "policy_id": str(policy.id),
            "customer_name": customer.full_name,
            "policy_type": product.product_name if product else "Insurance Policy",
            "expiry_date": str(policy.risk_end_date),
            "renewal_link": f"https://rnwq.in/{str(policy.id)[:8].lower()}",
            "days_until_expiry": days_left,
            "current_channel": "sms",
            "notification_history": [],
            "is_renewed": policy.policy_status == "RENEWED",
            "last_sent_at": "",
            "next_scheduled_channel": "sms",
            "llm_message": "",
        }

        from app.agent.renewal_graph import renewal_agent
        renewal_agent.invoke(initial_state)
    except Exception as exc:
        logger.error("trigger_agent_update failed: %s", exc)
    finally:
        db.close()
