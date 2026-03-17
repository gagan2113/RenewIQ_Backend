"""
APScheduler-based daily scheduler for insurance renewal reminders.
Updated for ICICI Lombard schema (policies / reminders tables, UUID PKs).
"""

from __future__ import annotations

import asyncio
import logging
from datetime import date, datetime, timedelta, timezone
from typing import Optional

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from sqlalchemy.orm import Session

from app.database import SessionLocal
from app.models.customer import Customer
from app.models.notification_log import Reminder
from app.models.policy import Policy
from app.models.product import ILProduct

logger = logging.getLogger(__name__)

scheduler = AsyncIOScheduler(timezone="Asia/Kolkata")

NOTIFY_WINDOW_DAYS = 30
RESEND_COOLDOWN_DAYS = 7


# ── Per-policy async task ───────────────────────────────────────────

async def _process_policy(policy: Policy, customer: Customer, product_name: str) -> None:
    db: Session = SessionLocal()
    try:
        latest: Optional[Reminder] = (
            db.query(Reminder)
            .filter(Reminder.policy_id == policy.id)
            .order_by(Reminder.scheduled_at.desc())
            .first()
        )

        now_utc = datetime.now(timezone.utc)

        if latest and latest.sent_at:
            sent_at = latest.sent_at
            if sent_at.tzinfo is None:
                sent_at = sent_at.replace(tzinfo=timezone.utc)
            days_since = (now_utc - sent_at).days
            if days_since < RESEND_COOLDOWN_DAYS:
                logger.debug("Policy %s: last notified %d days ago — skipping.", policy.id, days_since)
                return

        from app.models.channel import Channel
        ch_map = {c.id: c.code.lower() for c in db.query(Channel).all()}
        last_channel = ch_map.get(latest.channel_id, "sms") if latest else "sms"

        days_left = (policy.risk_end_date - date.today()).days
        logger.info("Scheduling | policy=%s | customer=%s | days=%d | ch=%s", policy.id, customer.id, days_left, last_channel)

        initial_state = {
            "customer_id": str(customer.id),
            "policy_id": str(policy.id),
            "customer_name": customer.full_name,
            "policy_type": product_name,
            "expiry_date": str(policy.risk_end_date),
            "renewal_link": f"https://rnwq.in/{str(policy.id)[:8].lower()}",
            "days_until_expiry": days_left,
            "current_channel": last_channel,
            "notification_history": [],
            "is_renewed": False,
            "last_sent_at": "",
            "next_scheduled_channel": last_channel,
            "llm_message": "",
        }

        loop = asyncio.get_event_loop()
        await loop.run_in_executor(None, _invoke_agent, initial_state)

    except Exception as exc:
        logger.error("Error processing policy %s: %s", policy.id, exc)
    finally:
        db.close()


def _invoke_agent(state: dict) -> None:
    from app.agent.renewal_graph import renewal_agent
    renewal_agent.invoke(state)


# ── Main scheduler job ──────────────────────────────────────────────

async def daily_renewal_check() -> None:
    logger.info("=== daily_renewal_check started ===")
    db: Session = SessionLocal()
    try:
        today = date.today()
        cutoff = today + timedelta(days=NOTIFY_WINDOW_DAYS)

        due_policies = (
            db.query(Policy)
            .filter(
                Policy.risk_end_date >= today,
                Policy.risk_end_date <= cutoff,
                Policy.policy_status.in_(["ACTIVE", "EXPIRING"]),
            )
            .all()
        )
        logger.info("Found %d due policies.", len(due_policies))
        if not due_policies:
            return

        prod_map = {p.id: p.product_name for p in db.query(ILProduct).all()}
        tasks = []
        for policy in due_policies:
            customer = db.query(Customer).filter(Customer.id == policy.customer_id).first()
            if customer:
                pname = prod_map.get(policy.product_id, "Insurance Policy")
                tasks.append(_process_policy(policy, customer, pname))
    finally:
        db.close()

    await asyncio.gather(*tasks, return_exceptions=True)
    logger.info("=== daily_renewal_check completed ===")


# ── Lifecycle ───────────────────────────────────────────────────────

def start_scheduler() -> None:
    scheduler.add_job(
        daily_renewal_check,
        trigger=CronTrigger(hour=9, minute=0),
        id="daily_renewal_check",
        replace_existing=True,
        misfire_grace_time=3600,
    )
    scheduler.start()
    logger.info("Scheduler started — daily_renewal_check at 09:00.")


def stop_scheduler() -> None:
    scheduler.shutdown(wait=False)
    logger.info("Scheduler stopped.")
