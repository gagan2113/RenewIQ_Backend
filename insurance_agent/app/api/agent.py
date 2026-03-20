"""
LangGraph agent management router (ICICI Lombard schema).
"""

import logging
from datetime import date, datetime
from typing import Any, Dict, Optional
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.api.responses import success_response
from app.database import get_db
from app.models.customer import Customer
from app.models.notification_log import Reminder
from app.models.policy import Policy
from app.models.product import ILProduct
from app.models.channel import Channel

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/agent", tags=["Agent"])


# ── Pydantic schemas ────────────────────────────────────────────────

class TriggerResponse(BaseModel):
    policy_id: UUID
    customer_id: UUID
    status: str
    message: str


class AgentStatusOut(BaseModel):
    policy_id: UUID
    il_policy_number: str
    policy_status: str
    product_line: Optional[str]
    expiry_date: date
    days_until_expiry: int
    customer_id: UUID
    customer_name: str
    total_notifications_sent: int
    last_channel: Optional[str]
    last_sent_at: Optional[datetime]
    last_delivery_status: Optional[str]
    link_clicked: bool
    is_renewed: bool


# ── Background runner ───────────────────────────────────────────────

def _run_agent(initial_state: Dict[str, Any]) -> None:
    try:
        from app.agent.renewal_graph import renewal_agent
        renewal_agent.invoke(initial_state)
        logger.info("Agent run completed for policy %s.", initial_state["policy_id"])
    except Exception as exc:
        logger.error("Agent run failed for policy %s: %s", initial_state["policy_id"], exc)


# ── Routes ──────────────────────────────────────────────────────────

@router.post("/trigger/{policy_id}")
def trigger_agent(
    policy_id: UUID,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    policy = db.query(Policy).filter(Policy.id == policy_id).first()
    if not policy:
        raise HTTPException(status_code=404, detail="Policy not found")

    if policy.policy_status == "RENEWED":
        payload = TriggerResponse(
            policy_id=policy_id,
            customer_id=policy.customer_id,
            status="skipped",
            message="Policy is already renewed.",
        )
        return success_response(data=payload.model_dump(mode="json"), message="Agent skipped")

    customer = db.query(Customer).filter(Customer.id == policy.customer_id).first()
    if not customer:
        raise HTTPException(status_code=404, detail="Customer not found")

    product = db.query(ILProduct).filter(ILProduct.id == policy.product_id).first()
    days_left = (policy.risk_end_date - date.today()).days

    latest = (
        db.query(Reminder)
        .filter(Reminder.policy_id == policy_id)
        .order_by(Reminder.scheduled_at.desc())
        .first()
    )
    ch_map = {c.id: c.code.lower() for c in db.query(Channel).all()}
    start_channel = ch_map.get(latest.channel_id, "sms") if latest else "sms"

    initial_state: Dict[str, Any] = {
        "customer_id": str(customer.id),
        "policy_id": str(policy_id),
        "customer_name": customer.full_name,
        "phone_number": customer.whatsapp_number or customer.phone,
        "email": customer.email,
        "policy_type": product.product_name if product else "Insurance Policy",
        "expiry_date": str(policy.risk_end_date),
        "renewal_link": f"https://rnwq.in/{str(policy_id)[:8].lower()}",
        "days_until_expiry": days_left,
        "current_channel": start_channel,
        "notification_history": [],
        "is_renewed": False,
        "last_sent_at": "",
        "next_scheduled_channel": start_channel,
        "llm_message": "",
    }

    background_tasks.add_task(_run_agent, initial_state)
    payload = TriggerResponse(
        policy_id=policy_id,
        customer_id=customer.id,
        status="triggered",
        message=f"Agent triggered via {start_channel}.",
    )
    return success_response(data=payload.model_dump(mode="json"), message="Agent triggered")


@router.get("/status/{policy_id}")
def agent_status(policy_id: UUID, db: Session = Depends(get_db)):
    policy = db.query(Policy).filter(Policy.id == policy_id).first()
    if not policy:
        raise HTTPException(status_code=404, detail="Policy not found")

    customer = db.query(Customer).filter(Customer.id == policy.customer_id).first()
    if not customer:
        raise HTTPException(status_code=404, detail="Customer not found")

    product = db.query(ILProduct).filter(ILProduct.id == policy.product_id).first()
    ch_map = {c.id: c.code for c in db.query(Channel).all()}

    reminders = (
        db.query(Reminder)
        .filter(Reminder.policy_id == policy_id)
        .order_by(Reminder.scheduled_at.desc())
        .all()
    )
    latest = reminders[0] if reminders else None

    payload = AgentStatusOut(
        policy_id=policy.id,
        il_policy_number=policy.il_policy_number,
        policy_status=policy.policy_status,
        product_line=product.product_line if product else None,
        expiry_date=policy.risk_end_date,
        days_until_expiry=(policy.risk_end_date - date.today()).days,
        customer_id=customer.id,
        customer_name=customer.full_name,
        total_notifications_sent=len(reminders),
        last_channel=ch_map.get(latest.channel_id) if latest else None,
        last_sent_at=latest.sent_at if latest else None,
        last_delivery_status=latest.delivery_status if latest else None,
        link_clicked=latest.link_clicked if latest else False,
        is_renewed=policy.policy_status == "RENEWED",
    )
    return success_response(data=payload.model_dump(mode="json"), message="Agent status fetched")
