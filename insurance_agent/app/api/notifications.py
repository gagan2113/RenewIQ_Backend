"""
Notification / Reminder query router (ICICI Lombard schema).
Uses the `reminders` table instead of the old `notification_logs`.
"""

import logging
from datetime import date, datetime, timedelta
from typing import List, Optional
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.api.responses import success_response
from app.database import get_db
from app.models.customer import Customer
from app.models.notification_log import Reminder
from app.models.policy import Policy
from app.models.channel import Channel

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/notifications", tags=["Notifications"])


# ── Pydantic schemas ────────────────────────────────────────────────

class ReminderOut(BaseModel):
    id: UUID
    policy_id: UUID
    customer_id: UUID
    channel_code: Optional[str] = None
    reminder_window: Optional[str]
    attempt_number: int
    is_fallback: bool
    scheduled_at: Optional[datetime]
    sent_at: Optional[datetime]
    delivery_status: str
    link_clicked: bool
    renewed_after_click: bool
    agent_notes: Optional[str]

    model_config = {"from_attributes": True}


class PendingCustomerOut(BaseModel):
    customer_id: UUID
    customer_name: str
    email: Optional[str]
    phone: str
    policy_id: UUID
    il_policy_number: str
    product_line: Optional[str]
    expiry_date: date
    days_until_expiry: int
    total_premium: Optional[float]
    last_channel: Optional[str]
    last_notified_at: Optional[datetime]
    notification_count: int


# ── Routes ──────────────────────────────────────────────────────────

@router.get("/history/{customer_id}")
def notification_history(
    customer_id: UUID,
    limit: int = Query(default=50, le=200),
    db: Session = Depends(get_db),
):
    reminders = (
        db.query(Reminder)
        .filter(Reminder.customer_id == customer_id)
        .order_by(Reminder.scheduled_at.desc())
        .limit(limit)
        .all()
    )
    # Build channel code map
    ch_map = {c.id: c.code for c in db.query(Channel).all()}
    results = []
    for r in reminders:
        d = {col.name: getattr(r, col.name) for col in r.__table__.columns}
        d["channel_code"] = ch_map.get(r.channel_id)
        results.append(d)
    return success_response(data=results, message="Notification history fetched")


@router.get("/pending")
def pending_renewals(
    within_days: int = Query(default=30, ge=1, le=90),
    product_line: Optional[str] = Query(default=None),
    db: Session = Depends(get_db),
):
    today = date.today()
    cutoff = today + timedelta(days=within_days)

    q = db.query(Policy).filter(
        Policy.risk_end_date >= today,
        Policy.risk_end_date <= cutoff,
        Policy.policy_status.in_(["ACTIVE", "EXPIRING"]),
    )
    due_policies = q.order_by(Policy.risk_end_date.asc()).all()

    ch_map = {c.id: c.code for c in db.query(Channel).all()}

    # Optional product_line filter
    from app.models.product import ILProduct
    prod_map = {p.id: p.product_line for p in db.query(ILProduct).all()}

    results: List[PendingCustomerOut] = []
    for policy in due_policies:
        pl = prod_map.get(policy.product_id)
        if product_line and pl != product_line:
            continue

        customer = db.query(Customer).filter(Customer.id == policy.customer_id).first()
        if not customer:
            continue

        reminders = (
            db.query(Reminder)
            .filter(Reminder.policy_id == policy.id)
            .order_by(Reminder.scheduled_at.desc())
            .all()
        )
        latest = reminders[0] if reminders else None

        results.append(PendingCustomerOut(
            customer_id=customer.id,
            customer_name=customer.full_name,
            email=customer.email,
            phone=customer.phone,
            policy_id=policy.id,
            il_policy_number=policy.il_policy_number,
            product_line=pl,
            expiry_date=policy.risk_end_date,
            days_until_expiry=(policy.risk_end_date - today).days,
            total_premium=float(policy.total_premium) if policy.total_premium else None,
            last_channel=ch_map.get(latest.channel_id) if latest else None,
            last_notified_at=latest.sent_at if latest else None,
            notification_count=len(reminders),
        ))
    return success_response(
        data=[item.model_dump(mode="json") for item in results],
        message="Pending renewals fetched",
    )
